import Foundation

// ---------------------------------------------------------------------------
// TelemetrySetup — natively enables GitHub Copilot OTel tracing. Everything is
// written under the user's own ~/Library (no admin / sudo). Only ever invoked
// on explicit user confirmation.
// ---------------------------------------------------------------------------

enum TelemetrySetup {
    struct Result {
        var changes: [String]
        var errors: [String]
        var ok: Bool { errors.isEmpty }
    }

    private static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }
    private static var vscodeSettingsPath: String { home + "/Library/Application Support/Code/User/settings.json" }
    private static var helperScriptPath: String { home + "/Library/Application Support/com.github.githubapp/copilot-otel-env" }
    private static var launchAgentPath: String { home + "/Library/LaunchAgents/com.github.githubapp.otel-env.plist" }
    private static var jsonlPath: String { home + "/Library/Application Support/com.github.githubapp/agent-traces.jsonl" }
    private static let launchAgentLabel = "com.github.githubapp.otel-env"

    private static let vscodeKeys = [
        "github.copilot.chat.otel.enabled",
        "github.copilot.chat.otel.dbSpanExporter.enabled",
        "github.copilot.chat.otel.captureContent",
    ]

    /// Human-readable list of what enabling would change (for the confirm dialog).
    static func plannedChanges() -> [String] {
        var c: [String] = []
        if !DataSources.isVSCodeTelemetryConfigured() {
            c.append("Add 3 OTel keys to VS Code settings.json")
        }
        if !DataSources.isMacAppTelemetryConfigured() {
            c.append("Install a Copilot OTel LaunchAgent + helper script in ~/Library")
        }
        return c
    }

    static func enableAll() -> Result {
        var changes: [String] = []
        var errors: [String] = []

        if !DataSources.isVSCodeTelemetryConfigured() {
            do { try enableVSCode(); changes.append("VS Code settings.json updated") }
            catch { errors.append("VS Code: \(error.localizedDescription)") }
        }
        if !DataSources.isMacAppTelemetryConfigured() {
            do { try enableMacApp(); changes.append("Mac App LaunchAgent installed & loaded") }
            catch { errors.append("Mac App: \(error.localizedDescription)") }
        }
        return Result(changes: changes, errors: errors)
    }

    // MARK: VS Code

    private static func enableVSCode() throws {
        let path = vscodeSettingsPath
        var content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { content = "{\n}" }

        for key in vscodeKeys {
            let escaped = NSRegularExpression.escapedPattern(for: key)
            if content.range(of: "\"\(escaped)\"\\s*:\\s*true", options: .regularExpression) != nil {
                continue   // already correct
            }
            if let r = content.range(of: "(\"\(escaped)\"\\s*:\\s*)(true|false)", options: .regularExpression) {
                content.replaceSubrange(r, with: "\"\(key)\": true")
            } else {
                content = insertKey(content, key: key)
            }
        }

        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Insert `"key": true` before the final `}` of a JSON(C) object.
    private static func insertKey(_ content: String, key: String) -> String {
        guard let brace = content.range(of: "}", options: .backwards) else {
            return "{\n    \"\(key)\": true\n}"
        }
        var before = String(content[..<brace.lowerBound])
        while let last = before.last, last == " " || last == "\n" || last == "\t" || last == "\r" {
            before.removeLast()
        }
        let needsComma = !before.isEmpty && !before.hasSuffix("{") && !before.hasSuffix(",")
        let after = String(content[brace.lowerBound...])
        return before + (needsComma ? "," : "") + "\n    \"\(key)\": true\n" + after
    }

    // MARK: Mac App

    private static func enableMacApp() throws {
        let fm = FileManager.default

        let script = """
        #!/bin/sh
        # GitHub Copilot OTel env — managed by BarPilot
        /bin/launchctl setenv COPILOT_OTEL_EXPORTER_TYPE file
        /bin/launchctl setenv COPILOT_OTEL_FILE_EXPORTER_PATH "\(jsonlPath)"
        /bin/launchctl setenv OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT true

        """
        try fm.createDirectory(atPath: (helperScriptPath as NSString).deletingLastPathComponent,
                               withIntermediateDirectories: true)
        try script.write(toFile: helperScriptPath, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperScriptPath)

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>\(launchAgentLabel)</string>
          <key>Program</key>
          <string>\(xmlEscape(helperScriptPath))</string>
          <key>RunAtLoad</key>
          <true/>
        </dict>
        </plist>

        """
        try fm.createDirectory(atPath: (launchAgentPath as NSString).deletingLastPathComponent,
                               withIntermediateDirectories: true)
        _ = runLaunchctl(["unload", launchAgentPath])   // clear any stale agent
        try plist.write(toFile: launchAgentPath, atomically: true, encoding: .utf8)
        _ = runLaunchctl(["load", launchAgentPath])
        _ = runLaunchctl(["start", launchAgentLabel])
    }

    @discardableResult
    private static func runLaunchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardError = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
    }

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
