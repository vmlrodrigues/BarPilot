import Foundation

// Diagnostics intentionally contain no credentials, account identifiers,
// usage amounts, prompts or source-file contents.
enum Diagnose {
    static func run() { print(report()) }

    static func report() -> String {
        var out: [String] = []
        func line(_ value: String = "") { out.append(value) }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        line("BarPilot diagnose")
        line("=================")
        line("version: \(version)\(Updater.isDevBuild ? " (dev build)" : " (Developer ID)")")
        line("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        line()
        line("GitHub credit history")
        line("  enabled: \(UserDefaults.standard.bool(forKey: "serverCreditUsageEnabled"))")
        let attributes = try? FileManager.default.attributesOfItem(atPath: CreditSampleStore.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        line("  database: \(DiagLog.tildify(CreditSampleStore.path))")
        line("  size: \(DiagLog.humanBytes(size))")
        let start = Date()
        line("  saved samples: \(CreditSampleStore.count())")
        line("  read time: \(Int(Date().timeIntervalSince(start) * 1_000)) ms")
        if let sample = CreditSampleStore.latest() {
            line("  latest sample: \(ISO8601DateFormatter().string(from: sample.capturedAt))")
            line("  cycle reset: \(ISO8601DateFormatter().string(from: sample.resetAt))")
        }
        line()
        line("sync")
        let syncEnabled = UserDefaults.standard.bool(forKey: "multiMachineSyncEnabled")
        line("  enabled: \(syncEnabled)")
        if syncEnabled {
            let machines = RemoteStore.machines()
            line("  remote machines cached: \(machines.count)")
            for machine in machines { line("    updated \(machine.updatedAt)") }
        }
        line()
        let tail = DiagLog.tail(25)
        line("recent reloads (\(DiagLog.tildify(DiagLog.path)), last \(tail.count) lines)")
        if tail.isEmpty {
            line("  (none yet)")
        } else {
            for entry in tail { line("  \(entry)") }
        }
        return out.joined(separator: "\n") + "\n"
    }
}
