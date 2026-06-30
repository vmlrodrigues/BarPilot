import Foundation
import AppKit

// ---------------------------------------------------------------------------
// Updater — silent, built-in auto-update against GitHub Releases.
//
// Shortly after launch and every few hours it asks the GitHub Releases API for
// the latest version. If that's newer than the running build it downloads the
// release DMG, verifies the download is signed by our Developer ID team and
// accepted by Gatekeeper, then swaps the app bundle in place and relaunches —
// no UI, no extra dependencies.
//
// Gated to Developer ID-signed builds (real releases); ad-hoc/dev builds are
// skipped, so development is never disrupted.
// ---------------------------------------------------------------------------

final class Updater {
    private static let repo = "vmlrodrigues/BarPilot"
    private static let teamID = "9N354A3UZK"
    private let interval: TimeInterval = 6 * 60 * 60   // re-check every 6 hours
    private var timer: Timer?

    // MARK: Lifecycle

    @MainActor
    func start() {
        guard !Self.isDevBuild else {
            NSLog("BarPilot: auto-update disabled (not a Developer ID build)")
            return
        }
        Self.checkNow(afterSeconds: 20)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Updater.checkNow()
        }
    }

    static func checkNow(afterSeconds delay: TimeInterval = 0) {
        Task.detached(priority: .background) {
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            await performCheck()
        }
    }

    // MARK: Check → download → verify → install

    private static func performCheck() async {
        guard let latest = await Self.latestRelease(),
              Self.isNewer(latest.version, than: Self.currentVersion()) else { return }
        NSLog("BarPilot: update available \(Self.currentVersion()) -> \(latest.version)")

        guard let dmg = await Self.download(latest.dmgURL) else { return }
        defer { try? FileManager.default.removeItem(at: dmg) }

        guard let staged = Self.mountExtractAndVerify(dmg: dmg) else { return }
        await MainActor.run { Self.installAndRelaunch(staged: staged) }
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

    /// Mounts the DMG, copies BarPilot.app out, detaches, and verifies the copy
    /// is signed by our Developer ID team and notarised. Returns staged app or nil.
    private static func mountExtractAndVerify(dmg: URL) -> URL? {
        guard let mount = hdiutilAttach(dmg) else { return nil }
        defer { _ = runTool("/usr/bin/hdiutil", ["detach", mount, "-force"]) }

        let appInDMG = URL(fileURLWithPath: mount).appendingPathComponent("BarPilot.app")
        guard FileManager.default.fileExists(atPath: appInDMG.path) else { return nil }

        let stageDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BarPilot-stage-\(UUID().uuidString)")
        let staged = stageDir.appendingPathComponent("BarPilot.app")
        try? FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)

        guard runTool("/usr/bin/ditto", [appInDMG.path, staged.path]).status == 0 else {
            try? FileManager.default.removeItem(at: stageDir); return nil
        }
        guard verify(app: staged) else {
            NSLog("BarPilot: update rejected — signature/team/Gatekeeper check failed")
            try? FileManager.default.removeItem(at: stageDir); return nil
        }
        return staged
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
    private static func installAndRelaunch(staged: URL) {
        let dest = Bundle.main.bundleURL
        let pid = ProcessInfo.processInfo.processIdentifier

        // Detached helper: wait for us to quit, swap the bundle, relaunch, clean up.
        let script = """
        #!/bin/sh
        while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.3; done
        /usr/bin/ditto "\(staged.path)" "\(dest.path).new" || exit 1
        /bin/rm -rf "\(dest.path)"
        /bin/mv "\(dest.path).new" "\(dest.path)"
        /usr/bin/xattr -dr com.apple.quarantine "\(dest.path)" 2>/dev/null
        /bin/rm -rf "\(staged.deletingLastPathComponent().path)"
        /usr/bin/open "\(dest.path)"
        """
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("barpilot-update-\(UUID().uuidString).sh")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        } catch {
            try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()); return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "nohup \"\(scriptURL.path)\" >/dev/null 2>&1 &"]
        do { try task.run(); task.waitUntilExit() } catch {
            try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()); return
        }
        NSLog("BarPilot: installing update and relaunching")
        NSApp.terminate(nil)
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
    static func isDeveloperIDSigned() -> Bool {
        let out = runTool("/usr/bin/codesign", ["-dvv", Bundle.main.bundlePath]).output
        return out.contains("TeamIdentifier=\(teamID)") && out.contains("Authority=Developer ID Application")
    }

    /// Cached once: true for ad-hoc / local (`build-app.sh`) builds that are NOT
    /// Developer ID-signed. Drives the in-app "DEV" markers so a local build is
    /// always identifiable. Computed lazily on first access (one `codesign` call).
    static let isDevBuild: Bool = !isDeveloperIDSigned()
}
