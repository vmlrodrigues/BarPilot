import Foundation

// ---------------------------------------------------------------------------
// Diagnose — the `--diagnose` support report.
//
// One command a user can run and paste back:
//   /Applications/BarPilot.app/Contents/MacOS/BarPilot --diagnose
//
// Prints current state plus a TIMED load (the number that matters for CPU
// complaints) and the tail of the rotating log, so both "now" and "recently"
// are covered. Counts, sizes and durations only — no usage content — and paths
// are home-relative so it's safe to paste into a public issue.
// ---------------------------------------------------------------------------

enum Diagnose {
    static func run() {
        func line(_ s: String = "") { print(s) }
        let fm = FileManager.default
        func fileInfo(_ path: String) -> String {
            guard let attrs = try? fm.attributesOfItem(atPath: path) else { return "absent" }
            let size = (attrs[.size] as? Int64) ?? 0
            let mtime = (attrs[.modificationDate] as? Date).map {
                ISO8601DateFormatter().string(from: $0)
            } ?? "?"
            return "\(DiagLog.humanBytes(size)) · modified \(mtime)"
        }

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        line("BarPilot diagnose")
        line("=================")
        line("version:      \(version)\(Updater.isDevBuild ? " (dev build)" : " (Developer ID)")")
        line("macOS:        \(ProcessInfo.processInfo.operatingSystemVersionString)")
        line("")

        let vsPath = DataSources.vscodeDBPath()
        let jsPath = DataSources.macAppJSONLPath()
        line("sources")
        line("  VS Code DB:   \(DiagLog.tildify(vsPath))")
        line("                \(fileInfo(vsPath))")
        line("                telemetry configured: \(DataSources.isVSCodeTelemetryConfigured())")
        line("  Mac App JSONL:\(DiagLog.tildify(jsPath))")
        line("                \(fileInfo(jsPath))")
        line("                telemetry configured: \(DataSources.isMacAppTelemetryConfigured())")
        line("")

        let storedOffset = Int64(SpanCache.getMeta(DataSources.jsonlOffsetKey) ?? "") ?? 0
        line("incremental read state")
        line("  stored JSONL offset: \(storedOffset) (\(DiagLog.humanBytes(storedOffset)))")

        // The money number: how long a reload actually costs right now.
        let t0 = Date()
        let (records, status) = DataSources.loadAll()
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        line("  bytes scanned this load: \(DiagLog.humanBytes(status.jsonlBytesScanned))")
        line("  new records this load:   \(status.newRecords)")
        line("  LOAD TIME:               \(ms) ms")
        line("")

        line("cache")
        line("  db:      \(DiagLog.tildify(SpanCache.path)) · \(DiagLog.humanBytes(SpanCache.fileSize()))")
        line("  records: \(records.count) total")
        for (src, n) in SpanCache.countsBySource().sorted(by: { $0.key < $1.key }) {
            line("           \(n)\t\(src)")
        }
        line("")

        line("sync")
        let syncOn = UserDefaults.standard.bool(forKey: "multiMachineSyncEnabled")
        line("  enabled: \(syncOn)")
        if syncOn {
            line("  remote machines cached: \(RemoteStore.machines().count)")
            for m in RemoteStore.machines() {
                line("    updated \(m.updatedAt)")
            }
        }
        line("")

        let tail = DiagLog.tail(25)
        line("recent reloads (\(DiagLog.tildify(DiagLog.path)), last \(tail.count) lines)")
        if tail.isEmpty {
            line("  (none yet — the log fills as the app runs)")
        } else {
            for l in tail { line("  \(l)") }
        }
    }
}
