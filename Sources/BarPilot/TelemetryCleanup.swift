import Foundation

// ---------------------------------------------------------------------------
// TelemetryCleanup — undoes the macOS login-session telemetry setup that older
// BarPilot versions installed for the Copilot Mac app. Only artefacts that
// carry BarPilot's ownership marker, and matching session variables for its
// file exporter, are removed. VS Code settings and existing trace files are
// deliberately left alone.
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
    /// Runs `/bin/launchctl` and returns its exit status and output.
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
            ("OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT", "true"),
            exporterPath,
        ]
    }
    private var exporterPath: (name: String, value: String) {
        ("COPILOT_OTEL_FILE_EXPORTER_PATH",
         home + "/Library/Application Support/com.github.githubapp/agent-traces.jsonl")
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
            // Strip the newline printed by getenv, preserving characters in
            // the value itself, including whitespace in a custom path.
            let value = arguments.first == "getenv" && data.last == 10
                ? data.dropLast() : data[...]
            let output = String(decoding: value, as: UTF8.self)
            return (process.terminationStatus, output)
        }
    )

    private var ownsHelperScript: Bool {
        guard let script = try? String(contentsOfFile: helperScriptPath, encoding: .utf8) else {
            return false
        }
        return Self.ownershipMarkers.contains { script.contains($0) }
    }

    private var ownsLaunchAgentFile: Bool {
        guard let data = FileManager.default.contents(atPath: launchAgentPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any] else { return false }
        return plist["Label"] as? String == Self.launchAgentLabel
            && plist["Program"] as? String == helperScriptPath
    }

    private enum RegisteredAgent {
        case absent, owned, foreign, unknown
    }

    private var launchAgentTarget: String {
        "gui/\(getuid())/\(Self.launchAgentLabel)"
    }

    private func registeredAgent() -> RegisteredAgent {
        let state = launchctl(["print", launchAgentTarget])
        let lines = state.output.split(whereSeparator: \.isNewline)
        guard state.status == 0 else {
            let missing = "Could not find service \"\(Self.launchAgentLabel)\" in domain for user gui: \(getuid())"
            return lines.contains(Substring(missing)) ? .absent : .unknown
        }

        // These are top-level fields in the registered service, independent
        // of what now lives at the plist path on disk.
        func field(_ name: String) -> Substring? {
            let prefix = "\t\(name) = "
            let matches = lines.filter { $0.hasPrefix(prefix) }
            guard matches.count == 1, let line = matches.first else { return nil }
            let value = line.dropFirst(prefix.count)
            return value.isEmpty ? nil : value
        }
        guard lines.first == "\(launchAgentTarget) = {",
              let path = field("path"), let program = field("program"),
              let type = field("type") else { return .unknown }
        return path == launchAgentPath && program == helperScriptPath && type == "LaunchAgent"
            ? .owned : .foreign
    }

    /// Must run off the main thread: it waits on `launchctl` subprocesses.
    func run() -> Outcome {
        precondition(!Thread.isMainThread, "telemetry cleanup waits on subprocesses")
        guard ownsHelperScript else { return .nothingToClean }
        let fileManager = FileManager.default
        let ownsAgentFile = ownsLaunchAgentFile
        guard ownsAgentFile || !fileManager.fileExists(atPath: launchAgentPath)
        else { return .nothingToClean }

        // Remove the agent first so nothing re-exports the variables.
        switch registeredAgent() {
        case .absent:
            break
        case .owned:
            let result = launchctl(["bootout", launchAgentTarget])
            switch registeredAgent() {
            case .absent:
                break
            case .unknown:
                return .failed("unable to verify telemetry login agent was unloaded")
            case .owned, .foreign:
                return .failed(result.status == 0
                    ? "telemetry login agent is still loaded"
                    : "unable to unload telemetry login agent")
            }
        case .foreign:
            return .nothingToClean
        case .unknown:
            return .failed("unable to verify telemetry login agent ownership")
        }
        if let failure = clearOwnedEnvironment() {
            return .failed(failure)
        }
        // Files go last so a failed run is retried on the next launch.
        do {
            if ownsAgentFile { try fileManager.removeItem(atPath: launchAgentPath) }
            try fileManager.removeItem(atPath: helperScriptPath)
        } catch {
            return .failed("unable to remove telemetry helper files")
        }
        return .cleaned
    }

    private func clearOwnedEnvironment() -> String? {
        let path = exporterPath
        let configuredPath = launchctl(["getenv", path.name])
        guard configuredPath.status == 0 else { return "unable to inspect \(path.name)" }
        // The other values are generic. Only the exact trace path identifies
        // the session configuration that the old BarPilot helper installed.
        guard configuredPath.output == path.value else { return nil }
        let exporter = launchctl(["getenv", "COPILOT_OTEL_EXPORTER_TYPE"])
        guard exporter.status == 0 else { return "unable to inspect COPILOT_OTEL_EXPORTER_TYPE" }
        // An empty type may be left by an earlier, partial cleanup. A different
        // exporter type belongs to the current configuration, even with a stale path.
        guard exporter.output.isEmpty || exporter.output == "file" else { return nil }

        // Clear the path last. If another unset fails, the next launch can
        // still recognise its own remaining variables by this path.
        for variable in expectedEnvironment {
            let current = launchctl(["getenv", variable.name])
            guard current.status == 0 else { return "unable to inspect \(variable.name)" }
            guard current.output == variable.value else { continue }

            _ = launchctl(["unsetenv", variable.name])
            let verified = launchctl(["getenv", variable.name])
            guard verified.status == 0 else { return "unable to verify \(variable.name)" }
            if verified.output == variable.value { return "unable to clear \(variable.name)" }
        }
        return nil
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
        private let failPrintCall: Int?
        private var getenvCalls = 0
        private var printCalls = 0
        private var agentOutput: String?
        private let failBootout: Bool

        init(
            environment: [String: String],
            failUnset: Bool = false, failBootout: Bool = false,
            failGetenvCall: Int? = nil, failPrintCall: Int? = nil
        ) {
            self.environment = environment
            self.failUnset = failUnset
            self.failBootout = failBootout
            self.failGetenvCall = failGetenvCall
            self.failPrintCall = failPrintCall
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
                agentOutput = nil
                return (0, "")
            case "print":
                printCalls += 1
                if printCalls == failPrintCall {
                    return (113, "Could not find service \"test.other-agent\" in domain for user gui: \(getuid())")
                }
                if let agentOutput { return (0, agentOutput) }
                return (113, """
                    Bad request.
                    Could not find service "\(launchAgentLabel)" in domain for user gui: \(getuid())
                    """)
            default: return (1, "unsupported command")
            }
        }

        func setEnvironment(_ values: [String: String]) {
            lock.lock(); defer { lock.unlock() }
            environment = values
        }

        func setAgentOutput(_ value: String?) {
            lock.lock(); defer { lock.unlock() }
            agentOutput = value
        }

        var snapshot: (environment: [String: String], calls: [[String]], agentLoaded: Bool) {
            lock.lock(); defer { lock.unlock() }
            return (environment, calls, agentOutput != nil)
        }
    }

    private enum AgentProgram { case expected, foreign }
    private enum TestAgentRegistration { case absent, owned, foreignProgram, foreignOrigin, missingProgram }

    private static func verifyFixtures() {
        let fileManager = FileManager.default

        func fixture(
            script: String?, agentProgram: AgentProgram?,
            registration: TestAgentRegistration = .absent,
            environment: (TelemetryCleanup) -> [String: String],
            failUnset: Bool = false, failBootout: Bool = false,
            failGetenvCall: Int? = nil, failPrintCall: Int? = nil,
            check: (TelemetryCleanup, FakeLaunchctl) -> Void
        ) {
            let home = NSTemporaryDirectory() + "barpilot-cleanup-\(UUID().uuidString)"
            defer { try? fileManager.removeItem(atPath: home) }
            let fake = FakeLaunchctl(
                environment: [:],
                failUnset: failUnset, failBootout: failBootout,
                failGetenvCall: failGetenvCall, failPrintCall: failPrintCall
            )
            let cleanup = TelemetryCleanup(home: home, launchctl: { fake.run($0) })
            fake.setEnvironment(environment(cleanup))
            if registration != .absent {
                let path = registration == .foreignOrigin
                    ? home + "/Library/AnotherApp/telemetry.plist" : cleanup.launchAgentPath
                let program = registration == .foreignProgram
                    ? "/usr/local/bin/other" : cleanup.helperScriptPath
                let programField = registration == .missingProgram ? "" : "\tprogram = \(program)\n"
                fake.setAgentOutput("""
                    \(cleanup.launchAgentTarget) = {
                    \tactive count = 0
                    \tpath = \(path)
                    \ttype = LaunchAgent
                    \(programField)\targuments = {
                    \t\t\(program)
                    \t}
                    }
                    """)
            }
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
            script: ownedScript, agentProgram: .expected, registration: .owned,
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
            precondition(Array(state.calls.prefix(3)) == [
                ["print", cleanup.launchAgentTarget],
                ["bootout", cleanup.launchAgentTarget],
                ["print", cleanup.launchAgentTarget],
            ], "agent ownership and unloading must be verified before clearing the environment")
            precondition(!fileManager.fileExists(atPath: cleanup.helperScriptPath))
            precondition(!fileManager.fileExists(atPath: cleanup.launchAgentPath))
            precondition(!state.agentLoaded)
            precondition(cleanup.run() == .nothingToClean, "cleanup must be idempotent")
        }

        // Deleting the plist does not unload a previously registered BarPilot agent.
        fixture(
            script: ownedScript, agentProgram: nil, registration: .owned,
            environment: { Dictionary(uniqueKeysWithValues: $0.expectedEnvironment) }
        ) { cleanup, fake in
            precondition(cleanup.run() == .cleaned)
            precondition(fake.snapshot.calls.contains(["bootout", cleanup.launchAgentTarget]))
            precondition(!fake.snapshot.agentLoaded && fake.snapshot.environment.isEmpty)
            precondition(!fileManager.fileExists(atPath: cleanup.helperScriptPath))
        }

        // The plist on disk cannot authorize unloading a different registered job.
        for registration in [TestAgentRegistration.foreignProgram, .foreignOrigin] {
            fixture(
                script: ownedScript, agentProgram: .expected, registration: registration,
                environment: { Dictionary(uniqueKeysWithValues: $0.expectedEnvironment) }
            ) { cleanup, fake in
                let previous = fake.snapshot.environment
                precondition(cleanup.run() == .nothingToClean)
                precondition(fake.snapshot.calls == [["print", cleanup.launchAgentTarget]])
                precondition(fake.snapshot.agentLoaded && fake.snapshot.environment == previous)
                precondition(fileManager.fileExists(atPath: cleanup.helperScriptPath))
                precondition(fileManager.fileExists(atPath: cleanup.launchAgentPath))
            }
        }

        // A successful print without a top-level program cannot prove ownership.
        fixture(
            script: ownedScript, agentProgram: .expected, registration: .missingProgram,
            environment: { Dictionary(uniqueKeysWithValues: $0.expectedEnvironment) }
        ) { cleanup, fake in
            let previous = fake.snapshot.environment
            precondition(cleanup.run() == .failed("unable to verify telemetry login agent ownership"))
            precondition(fake.snapshot.calls == [["print", cleanup.launchAgentTarget]])
            precondition(fake.snapshot.agentLoaded && fake.snapshot.environment == previous)
            precondition(fileManager.fileExists(atPath: cleanup.helperScriptPath))
            precondition(fileManager.fileExists(atPath: cleanup.launchAgentPath))
        }

        // A failed launchctl lookup, either before or after bootout, keeps the
        // files and environment available for a later verified cleanup.
        for failedLookup in [1, 2] {
            fixture(
                script: ownedScript, agentProgram: .expected, registration: .owned,
                environment: { Dictionary(uniqueKeysWithValues: $0.expectedEnvironment) },
                failPrintCall: failedLookup
            ) { cleanup, fake in
                let previous = fake.snapshot.environment
                let message = failedLookup == 1
                    ? "unable to verify telemetry login agent ownership"
                    : "unable to verify telemetry login agent was unloaded"
                precondition(cleanup.run() == .failed(message))
                precondition(fake.snapshot.agentLoaded == (failedLookup == 1))
                precondition(fake.snapshot.environment == previous)
                precondition(fileManager.fileExists(atPath: cleanup.helperScriptPath))
                precondition(fileManager.fileExists(atPath: cleanup.launchAgentPath))
                precondition(cleanup.run() == .cleaned)
                precondition(!fake.snapshot.agentLoaded && fake.snapshot.environment.isEmpty)
            }
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
            script: "#!/bin/sh\n# managed elsewhere\n", agentProgram: .expected,
            registration: .owned,
            environment: { _ in ["OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT": "true"] }
        ) { cleanup, fake in
            precondition(cleanup.run() == .nothingToClean)
            precondition(fake.snapshot.calls.isEmpty, "foreign setups must not be modified")
            precondition(fileManager.fileExists(atPath: cleanup.helperScriptPath))
            precondition(fileManager.fileExists(atPath: cleanup.launchAgentPath))
        }

        // A BarPilot helper does not authorize removal or disruption of a different agent.
        fixture(
            script: ownedScript, agentProgram: .foreign, registration: .foreignProgram,
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

        // Another file exporter can use the same general flags with its own path.
        fixture(
            script: ownedScript, agentProgram: .expected, registration: .owned,
            environment: { cleanup in [
                "COPILOT_OTEL_EXPORTER_TYPE": "file",
                "COPILOT_OTEL_FILE_EXPORTER_PATH": cleanup.exporterPath.value + " ",
                "OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT": "true",
            ] }
        ) { cleanup, fake in
            let previous = fake.snapshot.environment
            precondition(cleanup.run() == .cleaned)
            precondition(fake.snapshot.environment == previous)
            precondition(!fake.snapshot.calls.contains { $0.first == "unsetenv" })
            precondition(!fileManager.fileExists(atPath: cleanup.helperScriptPath))
            precondition(!fileManager.fileExists(atPath: cleanup.launchAgentPath))
        }

        // A different exporter can coexist with a leftover file path.
        fixture(
            script: ownedScript, agentProgram: nil,
            environment: { cleanup in [
                "COPILOT_OTEL_EXPORTER_TYPE": "otlp-http",
                "COPILOT_OTEL_FILE_EXPORTER_PATH": cleanup.exporterPath.value,
                "OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT": "true",
            ] }
        ) { cleanup, fake in
            let previous = fake.snapshot.environment
            precondition(cleanup.run() == .cleaned)
            precondition(fake.snapshot.environment == previous)
        }

        // A failed unload preserves its files and variables so the next launch retries.
        fixture(
            script: ownedScript, agentProgram: .expected, registration: .owned,
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
            environment: { cleanup in
                Dictionary(uniqueKeysWithValues: cleanup.expectedEnvironment)
            }, failUnset: true
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
            precondition(cleanup.run() == .failed("unable to inspect \(cleanup.exporterPath.name)"))
            precondition(fake.snapshot.environment["COPILOT_OTEL_EXPORTER_TYPE"] == "file")
            precondition(fileManager.fileExists(atPath: cleanup.helperScriptPath))
        }

        // Failed verification after unsetting also preserves the helper for retry.
        fixture(
            script: ownedScript, agentProgram: nil,
            environment: { cleanup in
                Dictionary(uniqueKeysWithValues: cleanup.expectedEnvironment)
            },
            failGetenvCall: 4
        ) { cleanup, fake in
            precondition(cleanup.run() == .failed("unable to verify COPILOT_OTEL_EXPORTER_TYPE"))
            precondition(fake.snapshot.environment["COPILOT_OTEL_EXPORTER_TYPE"] == nil)
            precondition(fake.snapshot.environment[cleanup.exporterPath.name] == cleanup.exporterPath.value)
            precondition(fileManager.fileExists(atPath: cleanup.helperScriptPath))
            precondition(cleanup.run() == .cleaned)
            precondition(fake.snapshot.environment.isEmpty)
            precondition(!fileManager.fileExists(atPath: cleanup.helperScriptPath))
        }

        // A BarPilot helper can be removed when its agent is already unloaded.
        fixture(
            script: ownedScript, agentProgram: .expected,
            environment: { _ in [:] }
        ) { cleanup, fake in
            precondition(cleanup.run() == .cleaned)
            precondition(!fake.snapshot.calls.contains { $0.first == "bootout" })
            precondition(!fileManager.fileExists(atPath: cleanup.helperScriptPath))
            precondition(!fileManager.fileExists(atPath: cleanup.launchAgentPath))
        }
    }
}
