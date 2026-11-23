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
        Self.checkNow(afterSeconds: 20)
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

        let installed = installation.withInstallLock {
            func relaunch(_ app: URL, newInstance: Bool) -> Bool {
                // Start the replacement, rather than activating the helper.
                // On failure, let LaunchServices reuse an already open app.
                let arguments = newInstance ? ["-n", app.path] : [app.path]
                return runTool("/usr/bin/open", arguments).status == 0
            }
            // The helper may be invoked directly, and another helper may have
            // installed a newer build. Read and verify again under the lock.
            switch installation.candidateState(expectedIdentifier: expectedIdentifier) {
            case .ready:
                runTool("/usr/bin/xattr", ["-dr", "com.apple.quarantine", installation.staged.path])
                return installation.install(relaunch: relaunch)
            case .stale:
                installation.discardStaging()
                return true
            case .invalid:
                installation.discardStaging()
                _ = relaunch(installation.installed, newInstance: false)
                return false
            }
        }
        if let installed { return installed }
        installation.discardStaging()
        NSLog("BarPilot: unable to acquire the update installation lock")
        return false
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

        func install(relaunch: (URL, Bool) -> Bool) -> Bool {
            guard exchangeBundles() else {
                NSLog("BarPilot: could not replace the installed app")
                discardStaging()
                _ = relaunch(installed, false)
                return false
            }
            if relaunch(installed, true) {
                discardStaging()
                return true
            }
            guard exchangeBundles() else {
                // Leave the original app in staging if rollback itself fails.
                NSLog("BarPilot: could not restore the original app after a failed relaunch")
                return false
            }
            discardStaging()
            _ = relaunch(installed, false)
            return false
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

    private static func verifyInstallation() throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent("barpilot-update-verify-\(UUID())")
        try fm.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: fixture) }
        let installed = fixture.appendingPathComponent("BarPilot's $ test.app", isDirectory: true)
        let installation = UpdateInstallation(installed: installed, id: UUID())
        let competingInstallation = UpdateInstallation(installed: installed, id: UUID())

        func createBundle(at url: URL, content: String) throws {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try content.write(to: url.appendingPathComponent("fixture"), atomically: true, encoding: .utf8)
        }
        func content(at url: URL) -> String? {
            try? String(contentsOf: url.appendingPathComponent("fixture"), encoding: .utf8)
        }

        try createBundle(at: installed, content: "original")
        try createBundle(at: installation.staged, content: "update")
        let installedUpdate = installation.install { app, newInstance in
            newInstance && content(at: app) == "update"
        }
        precondition(installedUpdate && content(at: installed) == "update")
        precondition(!fm.fileExists(atPath: installation.stagingDirectory.path))

        try createBundle(at: installation.staged, content: "bad relaunch")
        var relaunches: [String] = []
        let installedBrokenUpdate = installation.install { app, newInstance in
            guard let current = content(at: app) else { return false }
            relaunches.append(current)
            precondition(newInstance == (current == "bad relaunch"))
            return current == "update"
        }
        precondition(!installedBrokenUpdate && relaunches == ["bad relaunch", "update"])
        precondition(content(at: installed) == "update")
        precondition(!fm.fileExists(atPath: installation.stagingDirectory.path))

        let installedMissingUpdate = installation.install { app, newInstance in
            !newInstance && content(at: app) == "update"
        }
        precondition(!installedMissingUpdate && content(at: installed) == "update")

        let excludedContender = installation.withInstallLock(timeout: 0) {
            competingInstallation.withInstallLock(timeout: 0) { true } == nil
        }
        precondition(excludedContender == true)
        precondition(competingInstallation.withInstallLock(timeout: 0) { true } == true)

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
        try writeMetadata(at: competingInstallation.staged, version: "1.5.0")
        let staleCandidate = competingInstallation.withInstallLock(timeout: 0) {
            competingInstallation.candidateState(expectedIdentifier: identifier)
        }
        precondition(staleCandidate == .stale)
    }
}
