import Foundation

// ---------------------------------------------------------------------------
// TelemetryCleanup — undoes the macOS login-session telemetry setup that older
// BarPilot versions installed for the Copilot Mac app. Only artefacts that
// carry BarPilot's ownership marker, and session variables that still hold the
// exact values BarPilot set, are removed. VS Code settings and existing trace
// files are deliberately left alone.
// ---------------------------------------------------------------------------

struct TelemetryCleanup: Sendable {
    /// Header lines written by BarPilot's setup, including its pre-rename name.
    static let ownershipMarkers = [
        "GitHub Copilot OTel env — managed by BarPilot",
        "GitHub Copilot OTel env — managed by copilot-usage setup",
    ]
    static let launchAgentLabel = "com.github.githubapp.otel-env"

    enum Outcome: Equatable, Sendable {
        case nothingToClean
        case cleaned
        case failed(String)
    }

    let home: String
    /// Runs `/bin/launchctl` and returns its exit status and trimmed output.
    let launchctl: @Sendable ([String]) -> (status: Int32, output: String)

    var helperScriptPath: String {
        home + "/Library/Application Support/com.github.githubapp/copilot-otel-env"
    }
    var launchAgentPath: String {
        home + "/Library/LaunchAgents/\(Self.launchAgentLabel).plist"
    }
    var expectedEnvironment: [(name: String, value: String)] {
        [
            ("COPILOT_OTEL_EXPORTER_TYPE", "file"),
            ("COPILOT_OTEL_FILE_EXPORTER_PATH",
             home + "/Library/Application Support/com.github.githubapp/agent-traces.jsonl"),
            ("OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT", "true"),
        ]
    }

    static let live = TelemetryCleanup(
        home: FileManager.default.homeDirectoryForCurrentUser.path,
        launchctl: { arguments in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do { try process.run() } catch { return (-1, "") }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (process.terminationStatus, output)
        }
    )

    private var ownsHelperScript: Bool {
        guard let script = try? String(contentsOfFile: helperScriptPath, encoding: .utf8) else {
            return false
        }
        return Self.ownershipMarkers.contains { script.contains($0) }
    }

    private var ownsLaunchAgent: Bool {
        guard ownsHelperScript else { return false }
        guard let data = FileManager.default.contents(atPath: launchAgentPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any] else { return false }
        return plist["Label"] as? String == Self.launchAgentLabel
            && plist["Program"] as? String == helperScriptPath
    }

    private var hasLaunchAgentFile: Bool {
        FileManager.default.fileExists(atPath: launchAgentPath)
    }

    /// Must run off the main thread: it waits on `launchctl` subprocesses.
    func run() -> Outcome {
        precondition(!Thread.isMainThread, "telemetry cleanup waits on subprocesses")
        let ownsAgent = ownsLaunchAgent
        let ownsScript = ownsHelperScript
        guard ownsScript, !hasLaunchAgentFile || ownsAgent else {
            return .nothingToClean
        }

        // Remove the agent first so nothing re-exports the variables.
        if ownsAgent {
            let target = "gui/\(getuid())/\(Self.launchAgentLabel)"
            let result = launchctl(["bootout", target])
            let state = launchctl(["print", target])
            if state.status == 0
                || !state.output.contains("Could not find service") {
                return .failed(
                    result.status == 0
                        ? "telemetry login agent is still loaded"
                        : "unable to unload telemetry login agent"
                )
            }
        }
        for variable in expectedEnvironment {
            let current = launchctl(["getenv", variable.name])
            guard current.status == 0 else {
                return .failed("unable to inspect \(variable.name)")
            }
            guard current.output == variable.value else { continue }

            _ = launchctl(["unsetenv", variable.name])
            let verified = launchctl(["getenv", variable.name])
            guard verified.status == 0 else {
                return .failed("unable to verify \(variable.name)")
            }
            if verified.output == variable.value {
                return .failed("unable to clear \(variable.name)")
            }
        }
        // Files go last so a failed run is retried on the next launch.
        let fileManager = FileManager.default
        do {
            if ownsAgent { try fileManager.removeItem(atPath: launchAgentPath) }
            if ownsScript { try fileManager.removeItem(atPath: helperScriptPath) }
        } catch {
            return .failed("unable to remove telemetry helper files")
        }
        return .cleaned
    }

    // MARK: Verification

    static func verify() {
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            verifyFixtures()
            done.signal()
        }
        done.wait()
        print("telemetry cleanup verification passed")
    }

    private final class FakeLaunchctl: @unchecked Sendable {
        private let lock = NSLock()
        private var environment: [String: String]
        private var calls: [[String]] = []
        private let failUnset: Bool
        private let failGetenvCall: Int?
        private var getenvCalls = 0
        private var agentLoaded: Bool
        private var failBootout: Bool

        init(
            environment: [String: String], agentLoaded: Bool = false,
            failUnset: Bool = false, failBootout: Bool = false,
            failGetenvCall: Int? = nil
        ) {
            self.environment = environment
            self.agentLoaded = agentLoaded
            self.failUnset = failUnset
            self.failBootout = failBootout
            self.failGetenvCall = failGetenvCall
        }

        func run(_ arguments: [String]) -> (status: Int32, output: String) {
            lock.lock(); defer { lock.unlock() }
            calls.append(arguments)
            switch arguments.first {
            case "getenv":
                getenvCalls += 1
                if getenvCalls == failGetenvCall { return (1, "") }
                return (0, environment[arguments[1]] ?? "")
            case "unsetenv":
                if !failUnset { environment[arguments[1]] = nil }
                return (0, "")
            case "bootout":
                guard !failBootout else { return (1, "failed to boot out") }
                agentLoaded = false
                return (0, "")
            case "print":
                return agentLoaded
                    ? (0, "service is loaded")
                    : (113, "Could not find service")
            default: return (1, "unsupported command")
            }
        }

        func setEnvironment(_ values: [String: String]) {
            lock.lock(); defer { lock.unlock() }
            environment = values
        }

        func setBootoutFailure(_ value: Bool) {
            lock.lock(); defer { lock.unlock() }
            failBootout = value
        }

        var snapshot: (environment: [String: String], calls: [[String]], agentLoaded: Bool) {
            lock.lock(); defer { lock.unlock() }
            return (environment, calls, agentLoaded)
        }
    }

    private enum AgentProgram { case owned, matchingForeign, foreign }

    private static func verifyFixtures() {
        let fileManager = FileManager.default

        func fixture(
            script: String?, agentProgram: AgentProgram?,
            environment: (TelemetryCleanup) -> [String: String],
            failUnset: Bool = false, failBootout: Bool = false,
            failGetenvCall: Int? = nil,
            check: (TelemetryCleanup, FakeLaunchctl) -> Void
        ) {
            let home = NSTemporaryDirectory() + "barpilot-cleanup-\(UUID().uuidString)"
            defer { try? fileManager.removeItem(atPath: home) }
            let fake = FakeLaunchctl(
                environment: [:], agentLoaded: agentProgram != nil,
                failUnset: failUnset, failBootout: failBootout,
                failGetenvCall: failGetenvCall
            )
            let cleanup = TelemetryCleanup(home: home, launchctl: { fake.run($0) })
            fake.setEnvironment(environment(cleanup))
            let scriptDirectory = (cleanup.helperScriptPath as NSString).deletingLastPathComponent
            let agentDirectory = (cleanup.launchAgentPath as NSString).deletingLastPathComponent
            try! fileManager.createDirectory(atPath: scriptDirectory, withIntermediateDirectories: true)
            try! fileManager.createDirectory(atPath: agentDirectory, withIntermediateDirectories: true)
            // A trace file in the same folder must never be touched.
            let tracePath = scriptDirectory + "/agent-traces.jsonl"
            precondition(fileManager.createFile(atPath: tracePath, contents: Data("trace".utf8)))
            if let script {
                try! script.write(toFile: cleanup.helperScriptPath, atomically: true, encoding: .utf8)
            }
            if let agentProgram {
                let plist: [String: Any] = [
                    "Label": launchAgentLabel, "RunAtLoad": true,
                    "Program": agentProgram == .foreign
                        ? "/usr/local/bin/other" : cleanup.helperScriptPath,
                ]
                let data = try! PropertyListSerialization.data(
                    fromPropertyList: plist, format: .xml, options: 0
                )
                precondition(fileManager.createFile(atPath: cleanup.launchAgentPath, contents: data))
            }
            check(cleanup, fake)
            precondition(fileManager.fileExists(atPath: tracePath), "trace files must be kept")
        }

        let ownedScript = "#!/bin/sh\n# \(ownershipMarkers[0])\n"

        // Owned agent, script and matching variables are all removed, once.
        fixture(
            script: ownedScript, agentProgram: .owned,
            environment: { cleanup in
                var values = Dictionary(uniqueKeysWithValues:
                    cleanup.expectedEnvironment.map { ($0.name, $0.value) })
                values["OTHER"] = "1"
                return values
            }
        ) { cleanup, fake in
            precondition(cleanup.run() == .cleaned)
            let state = fake.snapshot
            precondition(state.environment == ["OTHER": "1"], "only BarPilot's variables are cleared")
            precondition(state.calls.first?.first == "bootout", "agent must be unloaded first")
            precondition(!fileManager.fileExists(atPath: cleanup.helperScriptPath))
            precondition(!fileManager.fileExists(atPath: cleanup.launchAgentPath))
            precondition(!state.agentLoaded)
            precondition(cleanup.run() == .nothingToClean, "cleanup must be idempotent")
        }

        // Helpers written before the rename are recognised too.
        fixture(
            script: "#!/bin/sh\n# \(ownershipMarkers[1])\n", agentProgram: nil,
            environment: { _ in [:] }
        ) { cleanup, _ in
            precondition(cleanup.run() == .cleaned)
            precondition(!fileManager.fileExists(atPath: cleanup.helperScriptPath))
        }

        // A matching plist does not confer ownership when another tool owns the script.
        fixture(
            script: "#!/bin/sh\n# managed elsewhere\n", agentProgram: .matchingForeign,
            environment: { _ in ["OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT": "true"] }
        ) { cleanup, fake in
            precondition(cleanup.run() == .nothingToClean)
            precondition(fake.snapshot.calls.isEmpty, "foreign setups must not be modified")
            precondition(fileManager.fileExists(atPath: cleanup.helperScriptPath))
            precondition(fileManager.fileExists(atPath: cleanup.launchAgentPath))
        }

        // A BarPilot helper does not authorize removal or disruption of a different agent.
        fixture(
            script: ownedScript, agentProgram: .foreign,
            environment: { _ in ["COPILOT_OTEL_EXPORTER_TYPE": "file"] }
        ) { cleanup, fake in
            precondition(cleanup.run() == .nothingToClean)
            precondition(fake.snapshot.calls.isEmpty, "a foreign agent is not modified")
            precondition(fake.snapshot.environment["COPILOT_OTEL_EXPORTER_TYPE"] == "file")
            precondition(fileManager.fileExists(atPath: cleanup.helperScriptPath))
            precondition(fileManager.fileExists(atPath: cleanup.launchAgentPath))
        }

        // Variables changed by someone else are kept; owned files still go.
        fixture(
            script: ownedScript, agentProgram: nil,
            environment: { _ in [
                "COPILOT_OTEL_EXPORTER_TYPE": "otlp-http",
                "OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT": "false",
            ] }
        ) { cleanup, fake in
            precondition(cleanup.run() == .cleaned)
            let state = fake.snapshot
            precondition(state.environment["COPILOT_OTEL_EXPORTER_TYPE"] == "otlp-http")
            precondition(state.environment["OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT"] == "false")
            precondition(!state.calls.contains { $0.first == "unsetenv" || $0.first == "bootout" })
            precondition(!fileManager.fileExists(atPath: cleanup.helperScriptPath))
        }

        // A failed unload preserves its files and variables so the next launch retries.
        fixture(
            script: ownedScript, agentProgram: .owned,
            environment: { _ in ["COPILOT_OTEL_EXPORTER_TYPE": "file"] },
            failBootout: true
        ) { cleanup, fake in
            precondition(cleanup.run() == .failed("unable to unload telemetry login agent"))
            precondition(fileManager.fileExists(atPath: cleanup.helperScriptPath))
            precondition(fileManager.fileExists(atPath: cleanup.launchAgentPath))
            precondition(fake.snapshot.environment["COPILOT_OTEL_EXPORTER_TYPE"] == "file")
        }

        // A failed unset keeps the files so the next launch retries.
        fixture(
            script: ownedScript, agentProgram: nil,
            environment: { _ in ["COPILOT_OTEL_EXPORTER_TYPE": "file"] }, failUnset: true
        ) { cleanup, _ in
            precondition(cleanup.run() == .failed("unable to clear COPILOT_OTEL_EXPORTER_TYPE"))
            precondition(fileManager.fileExists(atPath: cleanup.helperScriptPath))
        }

        // Failed inspection must preserve the helper so cleanup can retry.
        fixture(
            script: ownedScript, agentProgram: nil,
            environment: { _ in ["COPILOT_OTEL_EXPORTER_TYPE": "file"] },
            failGetenvCall: 1
        ) { cleanup, fake in
            precondition(cleanup.run() == .failed("unable to inspect COPILOT_OTEL_EXPORTER_TYPE"))
            precondition(fake.snapshot.environment["COPILOT_OTEL_EXPORTER_TYPE"] == "file")
            precondition(fileManager.fileExists(atPath: cleanup.helperScriptPath))
        }

        // Failed verification after unsetting also preserves the helper for retry.
        fixture(
            script: ownedScript, agentProgram: nil,
            environment: { _ in ["COPILOT_OTEL_EXPORTER_TYPE": "file"] },
            failGetenvCall: 2
        ) { cleanup, fake in
            precondition(cleanup.run() == .failed("unable to verify COPILOT_OTEL_EXPORTER_TYPE"))
            precondition(fake.snapshot.environment["COPILOT_OTEL_EXPORTER_TYPE"] == nil)
            precondition(fileManager.fileExists(atPath: cleanup.helperScriptPath))
        }

        // A BarPilot helper can be removed when its agent is already unloaded.
        fixture(
            script: ownedScript, agentProgram: nil,
            environment: { _ in [:] }
        ) { cleanup, _ in
            precondition(cleanup.run() == .cleaned)
            precondition(!fileManager.fileExists(atPath: cleanup.helperScriptPath))
        }
    }
}
