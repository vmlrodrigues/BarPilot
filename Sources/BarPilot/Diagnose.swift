import Foundation
import AppKit

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
    /// CLI path: print the report.
    static func run() { print(report()) }

    /// Build the report as text (shared by `--diagnose` and "Save Diagnostics…").
    ///
    /// SAFETY: counts, sizes, durations and configuration booleans only. Never
    /// usage content, never the sync account name, never a token, never process
    /// environment contents (#30) — users hand this file to other people and
    /// paste it into a PUBLIC repo. Paths are home-relative. (#31)
    static func report() -> String {
        var out: [String] = []
        func line(_ s: String = "") { out.append(s) }
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

        // Staleness — the quickest read on "has a source stopped exporting?" (#27)
        line("source activity")
        func lastSeen(_ name: String, _ ms: Int64?, _ days: Int?) {
            guard let ms, ms > 0 else { line("  \(name): no usage ever recorded"); return }
            let d = Date(timeIntervalSince1970: Double(ms) / 1000)
            let flag = (days ?? 0) >= 7 ? "   <-- STALE" : ""
            line("  \(name): last usage \(ISO8601DateFormatter().string(from: d))\(days.map { " (\($0)d ago)" } ?? "")\(flag)")
        }
        lastSeen("VS Code ", status.vscodeNewestMs, status.vscodeStaleDays())
        lastSeen("Mac App ", status.macAppNewestMs, status.macAppStaleDays())

        // Exporter watchdog — the decisive signal for "is telemetry recording
        // right now", independent of whether anyone is using Copilot. (#27)
        let copilot = NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == ExporterHealth.copilotBundleId }
        let verdict = ExporterHealth.evaluate(
            appRunning: copilot != nil,
            appUptime: copilot?.launchDate.map { Date().timeIntervalSince($0) },
            secondsSinceGrowth: status.macAppSecondsSinceGrowth,
            gapSinceLastCheck: status.gapSinceLastCheck)
        line("  Copilot app running: \(copilot != nil)")
        if let s = status.macAppSecondsSinceGrowth {
            line("  telemetry file last grew: \(Int(s))s ago (heartbeat is ~10s)")
        }
        line("  exporter verdict: \(verdict)\(verdict.isWarning ? "   <-- NOT RECORDING" : "")")
        if verdict.isWarning && !ExporterHealth.warningsEnabled {
            line("  (user-facing warning suppressed — detection unreliable since Copilot 1.1.4, see #32)")
        }
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
        return out.joined(separator: "\n") + "\n"
    }
}
