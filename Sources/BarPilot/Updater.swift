import Foundation
import AppKit
import Darwin
import Security

// ---------------------------------------------------------------------------
// Updater — silent, built-in auto-update against GitHub Releases.
//
// Shortly after launch and every few hours it asks the GitHub Releases API for
// the latest version. If that's newer than the running build it downloads the
// release DMG, verifies the download is signed by our Developer ID team and
// accepted by Gatekeeper, then swaps the app bundle in place and relaunches —
// no UI, no extra dependencies.
//
// Gated to release-channel, Developer ID-signed builds. Local bundles also use
// a stable Developer ID signature for Keychain continuity, but remain explicitly
// marked as development builds so development is never disrupted.
// ---------------------------------------------------------------------------

final class Updater {
    private static let repo = "vmlrodrigues/BarPilot"
    private static let teamID = "9N354A3UZK"
    static let installArgument = "--apply-staged-update"
    private static let startupArgument = "--confirm-staged-update"
    private static let recoveryArgument = "--recovered-staged-update"
    @MainActor private static var isChecking = false
    @MainActor private static var installer: Process?
    private let interval: TimeInterval = 6 * 60 * 60   // re-check every 6 hours
    private var timer: Timer?

    // MARK: Lifecycle

    @MainActor
    func start() {
        guard !Self.isDevBuild else {
            NSLog("BarPilot: auto-update disabled (development build)")
            return
        }
        // A failed release may still be GitHub's latest. Give the restored app
        // its normal periodic and manual checks without immediately retrying it.
        if !CommandLine.arguments.contains(Self.recoveryArgument) {
            Self.checkNow(afterSeconds: 20)
        }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Updater.checkNow()
        }
    }

    static func checkNow(afterSeconds delay: TimeInterval = 0) {
        guard !isDevBuild else {
            NSLog("BarPilot: update check skipped (development build)")
            return
        }
        Task { @MainActor in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !isChecking, installer?.isRunning != true else { return }
            isChecking = true
            defer { isChecking = false }
            await Task.detached(priority: .background) {
                await performCheck()
            }.value
        }
    }

    // MARK: Check → download → verify → install

    private static func performCheck() async {
        guard let latest = await Self.latestRelease(),
              Self.isNewer(latest.version, than: Self.currentVersion()) else { return }
        NSLog("BarPilot: update available \(Self.currentVersion()) -> \(latest.version)")

        guard let dmg = await Self.download(latest.dmgURL) else { return }
        defer { try? FileManager.default.removeItem(at: dmg) }

        guard let installation = Self.mountExtractAndVerify(dmg: dmg) else { return }
        await MainActor.run { Self.installAndRelaunch(installation) }
    }

    // MARK: GitHub API

    private struct Release { let version: String; let dmgURL: URL }

    private static func latestRelease() async -> Release? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("BarPilot", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { return nil }

        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let assets = json["assets"] as? [[String: Any]] ?? []
        guard let asset = assets.first(where: { ($0["name"] as? String)?.lowercased().hasSuffix(".dmg") == true }),
              let urlStr = asset["browser_download_url"] as? String,
              let dmgURL = URL(string: urlStr) else { return nil }

        return Release(version: version, dmgURL: dmgURL)
    }

    private static func download(_ url: URL) async -> URL? {
        guard let (tmp, resp) = try? await URLSession.shared.download(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("BarPilot-update-\(UUID().uuidString).dmg")
        do { try FileManager.default.moveItem(at: tmp, to: dest); return dest } catch { return nil }
    }

    // MARK: Mount + verify (synchronous; runs off the main thread)

    /// Stage beside the installed bundle so the final exchange uses one filesystem.
    /// An unwritable installation is detected before the running app quits.
    private static func mountExtractAndVerify(dmg: URL) -> UpdateInstallation? {
        guard let mount = hdiutilAttach(dmg) else { return nil }
        defer { _ = runTool("/usr/bin/hdiutil", ["detach", mount, "-force"]) }

        let appInDMG = URL(fileURLWithPath: mount).appendingPathComponent("BarPilot.app")
        guard FileManager.default.fileExists(atPath: appInDMG.path) else { return nil }

        let installation = UpdateInstallation(
            installed: Bundle.main.bundleURL.resolvingSymlinksInPath(), id: UUID()
        )
        do {
            try FileManager.default.createDirectory(
                at: installation.stagingDirectory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            NSLog("BarPilot: cannot stage an update beside the installed app")
            return nil
        }
        guard runTool("/usr/bin/ditto", [appInDMG.path, installation.staged.path]).status == 0,
              installation.candidateState(expectedIdentifier: Bundle.main.bundleIdentifier) == .ready else {
            installation.discardStaging()
            return nil
        }
        return installation
    }

    private static func verify(app: URL) -> Bool {
        guard runTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]).status == 0 else {
            NSLog("BarPilot: update verify failed — codesign --verify (corrupt/invalid download)")
            return false
        }
        let info = runTool("/usr/bin/codesign", ["-dvv", app.path]).output
        guard info.contains("TeamIdentifier=\(teamID)") else {
            NSLog("BarPilot: update verify failed — TeamIdentifier mismatch")
            return false
        }
        guard runTool("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path]).status == 0 else {
            NSLog("BarPilot: update verify failed — spctl/Gatekeeper assessment (notarization not verifiable; e.g. app not stapled + Apple unreachable)")
            return false
        }
        return true
    }

    private static func hdiutilAttach(_ dmg: URL) -> String? {
        let r = runTool("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-plist", dmg.path])
        guard r.status == 0, let data = r.output.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else { return nil }
        return entities.compactMap { $0["mount-point"] as? String }.first
    }

    // MARK: Install + relaunch

    @MainActor
    private static func installAndRelaunch(_ installation: UpdateInstallation) {
        guard let executable = Bundle.main.executableURL else {
            installation.discardStaging()
            return
        }
        // Start the current executable in helper mode. It performs the swap
        // after this application exits and takes every argument literally.
        let helper = Process()
        helper.executableURL = executable
        helper.arguments = [
            installArgument, installation.id.uuidString,
            String(ProcessInfo.processInfo.processIdentifier),
        ]
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        do {
            try helper.run()
        } catch {
            installation.discardStaging()
            NSLog("BarPilot: could not start the update helper")
            return
        }
        installer = helper
        NSLog("BarPilot: installing update and relaunching")
        NSApp.terminate(nil)
    }

    @MainActor
    static func applyStagedUpdate(_ arguments: ArraySlice<String>) -> Bool {
        guard !isDevBuild, arguments.count == 2,
              let id = UUID(uuidString: arguments[arguments.startIndex]),
              let parent = Int32(arguments[arguments.startIndex + 1]), parent > 1,
              getppid() == parent || getppid() == 1
        else { return false }
        let installation = UpdateInstallation(
            installed: Bundle.main.bundleURL.resolvingSymlinksInPath(), id: id
        )
        let expectedIdentifier = Bundle.main.bundleIdentifier
        let deadline = ProcessInfo.processInfo.systemUptime + 120
        // An exited parent can still have a PID until launchd reaps it. The
        // helper has already been reparented when the old app's exit is final.
        while getppid() == parent {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                installation.discardStaging()
                NSLog("BarPilot: timed out waiting for the app to quit before updating")
                return false
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        return installation.apply(
            expectedIdentifier: expectedIdentifier,
            launch: launchReplacement,
            reopen: reopenInstalled,
            waitForStartup: { waitOnMain(for: 15, until: $0) }
        )
    }

    /// Called from the first main-queue turn after the delegate has finished launch.
    @MainActor
    static func completeStartup(
        statusItemReady: Bool, runMaintenance: @escaping @Sendable (Bool) -> Void
    ) {
        let arguments = CommandLine.arguments.dropFirst()
        let release = isReleaseBuild
        if !arguments.contains(startupArgument) {
            // A recovery launch can occur while a different helper still has
            // a provisional bundle installed. It has no matching commit.
            let shouldRetire = release && !arguments.contains(recoveryArgument)
            Task.detached(priority: .background) { runMaintenance(shouldRetire) }
            return
        }
        guard statusItemReady, release,
              arguments.count == 2, arguments.first == startupArgument,
              let id = arguments.last.flatMap(UUID.init(uuidString:)) else { return }
        let installation = UpdateInstallation(
            installed: Bundle.main.bundleURL.resolvingSymlinksInPath(), id: id
        )
        let pid = ProcessInfo.processInfo.processIdentifier
        guard installation.acknowledgeStartup(pid: pid) else { return }
        Task.detached(priority: .background) {
            // Startup acknowledgment alone does not commit the exchange. Wait
            // for the helper before retiring data the original app still uses.
            let deadline = ProcessInfo.processInfo.systemUptime + 20
            while FileManager.default.fileExists(atPath: installation.stagingDirectory.path) {
                if installation.finishStartupIfCommitted(pid: pid) {
                    runMaintenance(true)
                    return
                }
                guard ProcessInfo.processInfo.systemUptime < deadline else { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private enum WorkspaceLaunch {
        case launched(NSRunningApplication)
        case rejected
        case unresolved
    }

    private enum ReplacementLaunch {
        case started(pid: pid_t, isRunning: () -> Bool, stop: () -> Bool)
        case rejected
        case unresolved
    }

    @MainActor
    private static func openApp(_ url: URL, arguments: [String], newInstance: Bool) -> WorkspaceLaunch {
        @MainActor final class LaunchProbe {
            var result: WorkspaceLaunch?
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments
        configuration.createsNewApplicationInstance = newInstance
        configuration.promptsUserIfNeeded = false
        configuration.addsToRecentItems = false
        let probe = LaunchProbe()
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { application, _ in
            DispatchQueue.main.async {
                probe.result = application.map(WorkspaceLaunch.launched) ?? .rejected
            }
        }
        _ = waitOnMain(for: 10) { probe.result != nil }
        return probe.result ?? .unresolved
    }

    @MainActor
    private static func launchReplacement(at url: URL, arguments: [String]) -> ReplacementLaunch {
        let otherPIDs = Set(NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? ""
        ).map(\.processIdentifier))
        switch openApp(url, arguments: arguments, newInstance: true) {
        case .rejected: return .rejected
        case .unresolved: return .unresolved
        case .launched(let application):
            if application.isTerminated { return .rejected }
            let pid = application.processIdentifier
            guard pid > 1, pid != getpid(), !otherPIDs.contains(pid),
                  application.bundleURL?.resolvingSymlinksInPath().path == url.path else {
                return .unresolved
            }
            return .started(pid: pid, isRunning: { !application.isTerminated }) {
                if application.isTerminated { return true }
                _ = application.terminate()
                if waitOnMain(for: 2, until: { application.isTerminated }) { return true }
                _ = application.forceTerminate()
                return waitOnMain(for: 3, until: { application.isTerminated })
            }
        }
    }

    @MainActor
    private static func reopenInstalled(_ url: URL) -> Bool {
        let arguments = [recoveryArgument]
        switch openApp(url, arguments: arguments, newInstance: false) {
        case .rejected, .unresolved:
            return false
        case .launched(let application):
            if application.processIdentifier != getpid(),
               application.bundleURL?.resolvingSymlinksInPath().path == url.path {
                return true
            }
            // The helper was launched from the installed bundle and may still
            // have the same LaunchServices identity as the app we need to start.
            if case .launched = openApp(url, arguments: arguments, newInstance: true) { return true }
            return false
        }
    }

    @MainActor
    private static func waitOnMain(for timeout: TimeInterval, until predicate: () -> Bool) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !predicate() {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(min(remaining, 0.05)))
        }
        return true
    }

    private struct UpdateInstallation: Sendable {
        let installed: URL
        let id: UUID

        var stagingDirectory: URL {
            installed.deletingLastPathComponent()
                .appendingPathComponent(".BarPilot-update-\(id.uuidString)", isDirectory: true)
        }

        var staged: URL {
            stagingDirectory.appendingPathComponent(installed.lastPathComponent, isDirectory: true)
        }

        func discardStaging() {
            try? FileManager.default.removeItem(at: stagingDirectory)
        }

        func acknowledgeStartup(pid: pid_t) -> Bool {
            FileManager.default.fileExists(atPath: staged.path)
                && writeCheckpoint("startup-acknowledgment", pid: pid)
        }

        func finishStartupIfCommitted(pid: pid_t) -> Bool {
            guard matchesCheckpoint("startup-commit", pid: pid) else { return false }
            discardStaging()
            return true
        }

        private func writeCheckpoint(_ name: String, pid: pid_t) -> Bool {
            do {
                try checkpoint(pid: pid).write(to: stagingDirectory.appendingPathComponent(name), options: .atomic)
                return true
            } catch {
                NSLog("BarPilot: unable to write update checkpoint \(name)")
                return false
            }
        }

        private func matchesCheckpoint(_ name: String, pid: pid_t) -> Bool {
            let data = try? Data(contentsOf: stagingDirectory.appendingPathComponent(name))
            return data == checkpoint(pid: pid)
        }

        private func checkpoint(pid: pid_t) -> Data {
            Data("\(id.uuidString)\n\(pid)\n".utf8)
        }

        func withInstallLock<T>(timeout: TimeInterval = 30, _ work: () -> T) -> T? {
            // Use a directory descriptor so the lock has a stable inode across
            // exchanges and leaves no lock file. Close releases the lock.
            let parent = installed.deletingLastPathComponent()
            let descriptor = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard descriptor >= 0 else { return nil }
            defer { _ = Darwin.close(descriptor) }
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                guard errno == EWOULDBLOCK, ProcessInfo.processInfo.systemUptime < deadline else {
                    return nil
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            return work()
        }

        enum CandidateState: Equatable { case ready, stale, invalid }

        func candidateState(expectedIdentifier: String?) -> CandidateState {
            // Bundle.main may have cached metadata before a competing updater
            // exchanged the files. Read the installed version from disk.
            func info(_ app: URL) -> [String: Any]? {
                let plist = app.appendingPathComponent("Contents/Info.plist")
                guard let data = try? Data(contentsOf: plist) else { return nil }
                return (try? PropertyListSerialization.propertyList(from: data, format: nil))
                    as? [String: Any]
            }
            guard let identifier = expectedIdentifier,
                  let current = info(installed), let candidate = info(staged),
                  current["CFBundleIdentifier"] as? String == identifier,
                  candidate["CFBundleIdentifier"] as? String == identifier,
                  let currentVersion = current["CFBundleShortVersionString"] as? String,
                  let candidateVersion = candidate["CFBundleShortVersionString"] as? String else {
                NSLog("BarPilot: update rejected — unexpected bundle identity or version")
                return .invalid
            }
            guard Updater.isNewer(candidateVersion, than: currentVersion) else { return .stale }
            return Updater.verify(app: staged) ? .ready : .invalid
        }

        @MainActor
        func apply(
            expectedIdentifier: String?, lockTimeout: TimeInterval = 30,
            launch: (URL, [String]) -> ReplacementLaunch, reopen: (URL) -> Bool,
            waitForStartup: (() -> Bool) -> Bool
        ) -> Bool {
            let outcome = withInstallLock(timeout: lockTimeout) {
                // Another helper may have installed a newer bundle while we waited.
                switch candidateState(expectedIdentifier: expectedIdentifier) {
                case .ready:
                    runTool("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
                    return install(launch: launch, reopen: reopen, waitForStartup: waitForStartup)
                case .stale:
                    discardStaging()
                    return reopen(installed)
                case .invalid:
                    discardStaging()
                    _ = reopen(installed)
                    return false
                }
            }
            if let outcome { return outcome }
            discardStaging()
            NSLog("BarPilot: unable to acquire the update installation lock")
            _ = reopen(installed)
            return false
        }

        @MainActor
        func install(
            launch: (URL, [String]) -> ReplacementLaunch, reopen: (URL) -> Bool,
            waitForStartup: (() -> Bool) -> Bool
        ) -> Bool {
            guard let original = BundleIdentity(installed), let candidate = BundleIdentity(staged),
                  exchangeBundles() else {
                NSLog("BarPilot: could not replace the installed app")
                discardStaging()
                _ = reopen(installed)
                return false
            }

            func exchangeIsUnchanged() -> Bool {
                BundleIdentity(installed) == candidate && BundleIdentity(staged) == original
            }
            switch launch(installed, [Updater.startupArgument, id.uuidString]) {
            case .started(let pid, let isRunning, let stop):
                func acknowledged() -> Bool { matchesCheckpoint("startup-acknowledgment", pid: pid) }
                if waitForStartup({ !isRunning() || acknowledged() }),
                   isRunning(), acknowledged(), exchangeIsUnchanged(),
                   writeCheckpoint("startup-commit", pid: pid) {
                    // The confirmed replacement removes the backup after reading this commit.
                    return true
                }
                guard exchangeIsUnchanged() else {
                    NSLog("BarPilot: installed bundle changed during update. Original app kept in staging.")
                    return false
                }
                guard stop() else {
                    NSLog("BarPilot: could not stop the unconfirmed update. Original app kept in staging.")
                    return false
                }
            case .rejected:
                break
            case .unresolved:
                // LaunchServices may still start the app. Leave the original
                // intact when we cannot safely identify and stop that process.
                NSLog("BarPilot: replacement launch outcome unknown. Original app kept in staging.")
                return false
            }
            guard exchangeIsUnchanged(), exchangeBundles() else {
                NSLog("BarPilot: could not restore the original app after a failed relaunch")
                return false
            }
            discardStaging()
            _ = reopen(installed)
            return false
        }

        private struct BundleIdentity: Equatable {
            let device: dev_t
            let inode: ino_t
            let info: Data?

            init?(_ url: URL) {
                var metadata = stat()
                guard lstat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR else { return nil }
                device = metadata.st_dev
                inode = metadata.st_ino
                info = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
            }
        }

        private func exchangeBundles() -> Bool {
            installed.withUnsafeFileSystemRepresentation { installedPath in
                staged.withUnsafeFileSystemRepresentation { stagedPath in
                    guard let installedPath, let stagedPath else { return false }
                    return renameatx_np(
                        AT_FDCWD, installedPath, AT_FDCWD, stagedPath, UInt32(RENAME_SWAP)
                    ) == 0
                }
            }
        }
    }

    // MARK: Helpers

    @discardableResult
    private static func runTool(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    static func currentVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// True if `a` is a strictly higher dotted version than `b`.
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0) ?? 0 } }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let xi = i < x.count ? x[i] : 0
            let yi = i < y.count ? y[i] : 0
            if xi != yi { return xi > yi }
        }
        return false
    }

    /// Only Developer ID-signed builds self-update (so dev builds don't).
    static func isDeveloperIDSigned(at url: URL = Bundle.main.bundleURL) -> Bool {
        var code: SecStaticCode?
        let codeStatus = SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code)
        guard codeStatus == errSecSuccess, let code else {
            NSLog("BarPilot: unable to inspect code signature (%d); auto-update disabled", codeStatus)
            return false
        }

        var signingInformation: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            code, SecCSFlags(rawValue: kSecCSSigningInformation), &signingInformation
        )
        guard infoStatus == errSecSuccess,
              let info = signingInformation as? [String: Any] else {
            NSLog("BarPilot: unable to read code signing information (%d); auto-update disabled", infoStatus)
            return false
        }
        let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []
        let subjects = certificates.compactMap { SecCertificateCopySubjectSummary($0) as String? }
        return matchesDeveloperID(
            teamIdentifier: info[kSecCodeInfoTeamIdentifier as String] as? String,
            certificateSubjects: subjects
        )
    }

    private static func matchesDeveloperID(teamIdentifier: String?, certificateSubjects: [String]) -> Bool {
        teamIdentifier == teamID && certificateSubjects.contains {
            $0.hasPrefix("Developer ID Application")
        }
    }

    /// Cached once. New bundles carry an explicit channel because signature type
    /// cannot distinguish a release from a stable-signed local build. The signing
    /// check remains as a safe fallback for older bundles and `swift run`. It
    /// must not spin the main run loop while this static value is initialising.
    static let isDevBuild: Bool = {
        if let channel = Bundle.main.infoDictionary?["BarPilotBuildChannel"] as? String {
            guard channel == "release" else { return true }
            return !isDeveloperIDSigned()
        }
        return !isDeveloperIDSigned()
    }()

    static var isReleaseBuild: Bool {
        Bundle.main.object(forInfoDictionaryKey: "BarPilotBuildChannel") as? String == "release"
            && !isDevBuild
    }

    @MainActor
    static func verifyStartup() {
        @MainActor final class Probe {
            var checkingIdentity = true
            var callbackRan = false
            var reentered = false
        }
        let probe = Probe()
        DispatchQueue.main.async {
            probe.reentered = probe.checkingIdentity
            probe.callbackRan = true
        }
        let development = isDevBuild
        probe.checkingIdentity = false

        let deadline = Date().addingTimeInterval(2)
        while !probe.callbackRan && Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: deadline)
        }
        guard probe.callbackRan else {
            fputs("FAIL: startup verification could not service the main queue\n", stderr)
            exit(1)
        }
        guard !probe.reentered else {
            fputs("FAIL: startup build identity check reentered the main queue\n", stderr)
            exit(1)
        }
        precondition(matchesDeveloperID(
            teamIdentifier: teamID, certificateSubjects: ["Developer ID Application: Example"]
        ))
        precondition(!matchesDeveloperID(
            teamIdentifier: "OTHERTEAM", certificateSubjects: ["Developer ID Application: Example"]
        ))
        precondition(!matchesDeveloperID(
            teamIdentifier: teamID, certificateSubjects: ["Apple Development: Example"]
        ))
        precondition(!isDeveloperIDSigned(at: URL(fileURLWithPath: "/usr/bin/codesign")))
        do {
            try verifyInstallation()
        } catch {
            fputs("FAIL: could not prepare the update verification fixture\n", stderr)
            exit(1)
        }
        print("Startup identity verification passed (\(development ? "development" : "release")).")
        print("Atomic update verification passed.")
    }

    @MainActor
    private static func verifyInstallation() throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent("barpilot-update-verify-\(UUID())")
        try fm.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: fixture) }
        let installed = fixture.appendingPathComponent("BarPilot's $ test.app", isDirectory: true)
        let installation = UpdateInstallation(installed: installed, id: UUID())
        let pid: pid_t = 42

        func createBundle(at url: URL, content: String) throws {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try content.write(to: url.appendingPathComponent("fixture"), atomically: true, encoding: .utf8)
        }
        func content(at url: URL) -> String? {
            try? String(contentsOf: url.appendingPathComponent("fixture"), encoding: .utf8)
        }
        func checkImmediately(_ predicate: () -> Bool) -> Bool { predicate() }

        try createBundle(at: installed, content: "original")
        try createBundle(at: installation.staged, content: "update")
        let installedUpdate = installation.install(launch: { app, arguments in
            precondition(arguments == [startupArgument, installation.id.uuidString])
            precondition(content(at: app) == "update" && content(at: installation.staged) == "original")
            precondition(installation.acknowledgeStartup(pid: pid))
            precondition(!installation.finishStartupIfCommitted(pid: pid), "acknowledgment alone is provisional")
            return .started(pid: pid, isRunning: { true }, stop: { preconditionFailure("healthy replacement") })
        }, reopen: { _ in preconditionFailure("healthy replacement") }, waitForStartup: checkImmediately)
        precondition(installedUpdate && content(at: installed) == "update")
        precondition(content(at: installation.staged) == "original", "the replacement still has to read the commit")
        precondition(!installation.finishStartupIfCommitted(pid: pid + 1))
        precondition(installation.finishStartupIfCommitted(pid: pid))
        precondition(!fm.fileExists(atPath: installation.stagingDirectory.path))

        for incorrectAcknowledgment in [false, true] {
            let attempt = UpdateInstallation(installed: installed, id: UUID())
            try createBundle(at: attempt.staged, content: "bad startup")
            var steps: [String] = []
            let installedBrokenUpdate = attempt.install(launch: { app, _ in
                steps.append("launch accepted")
                precondition(content(at: app) == "bad startup" && content(at: attempt.staged) == "update")
                if incorrectAcknowledgment { precondition(attempt.acknowledgeStartup(pid: pid + 1)) }
                return .started(pid: pid, isRunning: { true }, stop: {
                    steps.append("stop failed replacement")
                    return true
                })
            }, reopen: { app in
                steps.append("reopen original")
                return content(at: app) == "update"
            }, waitForStartup: { predicate in
                steps.append("wait for startup")
                precondition(!predicate())
                return false
            })
            precondition(!installedBrokenUpdate)
            precondition(steps == ["launch accepted", "wait for startup", "stop failed replacement", "reopen original"])
            precondition(content(at: installed) == "update")
            precondition(!fm.fileExists(atPath: attempt.stagingDirectory.path))
        }

        let rejected = UpdateInstallation(installed: installed, id: UUID())
        try createBundle(at: rejected.staged, content: "rejected update")
        var reopened = false
        func reopenOriginal(_ app: URL) -> Bool {
            reopened = content(at: app) == "update"
            return reopened
        }
        let rejectedUpdate = rejected.install(launch: { _, _ in .rejected },
                                              reopen: reopenOriginal, waitForStartup: checkImmediately)
        precondition(!rejectedUpdate && reopened)
        precondition(!fm.fileExists(atPath: rejected.stagingDirectory.path))

        reopened = false
        let installedMissingUpdate = rejected.install(launch: { _, _ in preconditionFailure("no replacement") },
                                                      reopen: reopenOriginal, waitForStartup: checkImmediately)
        precondition(!installedMissingUpdate && reopened)

        for launch in [ReplacementLaunch.unresolved, .started(pid: pid, isRunning: { true }, stop: { false })] {
            let attempt = UpdateInstallation(installed: installed, id: UUID())
            try createBundle(at: attempt.staged, content: "undetermined update")
            let installedUnresolved = attempt.install(launch: { _, _ in launch },
                reopen: { _ in preconditionFailure("replacement may still be running") },
                waitForStartup: checkImmediately)
            precondition(!installedUnresolved && content(at: installed) == "undetermined update")
            precondition(content(at: attempt.staged) == "update", "keep the original when rollback is unsafe")
            try fm.removeItem(at: installed)
            try fm.moveItem(at: attempt.staged, to: installed)
            attempt.discardStaging()
        }

        let identifier = "org.example.barpilot.update-fixture"
        func writeMetadata(at app: URL, version: String) throws {
            let directory = app.appendingPathComponent("Contents", isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let plist = try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version],
                format: .xml, options: 0
            )
            try plist.write(to: directory.appendingPathComponent("Info.plist"))
        }
        try writeMetadata(at: installed, version: "2.0.0")
        let superseded = UpdateInstallation(installed: installed, id: UUID())
        try createBundle(at: superseded.staged, content: "candidate update")
        try writeMetadata(at: superseded.staged, version: "3.0.0")
        let supersededUpdate = superseded.install(launch: { app, _ in
            precondition(superseded.acknowledgeStartup(pid: pid))
            try! writeMetadata(at: app, version: "4.0.0")
            return .started(pid: pid, isRunning: { true }, stop: { preconditionFailure("bundle changed during launch") })
        }, reopen: { _ in preconditionFailure("newer update must remain installed") }, waitForStartup: checkImmediately)
        precondition(!supersededUpdate && content(at: superseded.staged) == "update")
        precondition(content(at: installed) == "candidate update")
        precondition(!superseded.finishStartupIfCommitted(pid: pid))

        let competingInstallation = UpdateInstallation(installed: installed, id: UUID())
        try writeMetadata(at: competingInstallation.staged, version: "1.5.0")
        reopened = false
        let staleCandidate = competingInstallation.apply(expectedIdentifier: identifier, lockTimeout: 0,
            launch: { _, _ in preconditionFailure("stale replacement") }, reopen: { app in
                reopened = app == installed
                return reopened
            }, waitForStartup: checkImmediately)
        precondition(staleCandidate && reopened)
        precondition(!fm.fileExists(atPath: competingInstallation.stagingDirectory.path))

        try writeMetadata(at: competingInstallation.staged, version: "5.0.0")
        reopened = false
        let excludedContender = installation.withInstallLock(timeout: 0) {
            !competingInstallation.apply(expectedIdentifier: identifier, lockTimeout: 0,
                launch: { _, _ in preconditionFailure("lock is held") }, reopen: { app in
                    reopened = app == installed
                    return reopened
                }, waitForStartup: checkImmediately)
        }
        precondition(excludedContender == true && reopened)
        precondition(!fm.fileExists(atPath: competingInstallation.stagingDirectory.path))
        precondition(competingInstallation.withInstallLock(timeout: 0) { true } == true)
    }
}
