import Foundation

// ---------------------------------------------------------------------------
// ExporterHealth — is the Copilot app actually recording telemetry right now?
//
// The failure this catches: the app runs normally but its OTel exporter is dead
// (launched before the env vars existed, exporter wedged, writing elsewhere).
// Usage silently stops being recorded and the menu-bar total freezes at a stale
// number — indistinguishable from a healthy app, which is how a real user lost
// five days of data before noticing. (#27)
//
// Absence of USAGE can't detect this: a quiet source is indistinguishable from a
// user who isn't working. But the Copilot app writes a ~10-second HEARTBEAT to
// its JSONL whether or not anyone is using it (verified: ~1.5 KB/10s while idle
// and backgrounded). So we watch the producer instead of the data:
//
//     app running + file not growing  =  exporter is dead
//
// No guessing about user activity, no multi-day wait — it resolves in minutes.
// ---------------------------------------------------------------------------

enum ExporterHealth {
    /// The GitHub Copilot Mac app — watched to tell "exporter dead" from "idle".
    static let copilotBundleId = "com.github.githubapp"

    /// 10 minutes against a ~10s heartbeat: a 60x margin, so scheduling jitter,
    /// a slow flush or a brief stall can never trip it.
    static let quietThreshold: TimeInterval = 600
    /// Give a freshly launched app time to start its exporter.
    static let warmupGrace: TimeInterval = 120
    /// A gap longer than this means we weren't watching (sleep, BarPilot not
    /// running) — that silence can't be attributed to the exporter.
    static let maxObservationGap: TimeInterval = 300

    enum Verdict: Equatable {
        case healthy
        case appNotRunning
        case warmingUp
        case unattributable      // slept / wasn't observing — clock restarts
        case silent(minutes: Int)

        /// Only this state is surfaced to the user.
        var isWarning: Bool { if case .silent = self { return true }; return false }
    }

    /// Pure decision, so the rule is testable without a running Copilot app.
    static func evaluate(appRunning: Bool,
                         appUptime: TimeInterval?,
                         secondsSinceGrowth: TimeInterval?,
                         gapSinceLastCheck: TimeInterval?) -> Verdict {
        guard appRunning else { return .appNotRunning }
        if let up = appUptime, up < warmupGrace { return .warmingUp }
        if let gap = gapSinceLastCheck, gap > maxObservationGap { return .unattributable }
        guard let quiet = secondsSinceGrowth else { return .healthy }   // no baseline yet
        if quiet > quietThreshold { return .silent(minutes: Int(quiet / 60)) }
        return .healthy
    }

    static let warningText = "Copilot is running but isn’t recording telemetry — quit and reopen it."

    // -----------------------------------------------------------------------
    // Headless check (--verify-watchdog).
    // -----------------------------------------------------------------------
    static func verify() {
        let err = FileHandle.standardError
        var pass = 0, fail = 0
        func check(_ name: String, _ ok: Bool) {
            if ok { pass += 1 } else { fail += 1 }
            err.write(Data("  [\(ok ? "OK" : "XX")] \(name)\n".utf8))
        }
        func v(_ running: Bool, _ up: TimeInterval?, _ quiet: TimeInterval?, _ gap: TimeInterval?) -> Verdict {
            evaluate(appRunning: running, appUptime: up, secondsSinceGrowth: quiet, gapSinceLastCheck: gap)
        }
        let hour: TimeInterval = 3600

        check("heartbeating while idle -> healthy",            v(true, hour, 15, 60) == .healthy)
        check("app not running -> no warning",                 v(false, nil, hour, 60) == .appNotRunning)
        check("just launched, no data yet -> no warning",      v(true, 30, hour, 60) == .warmingUp)
        check("after a 30-min sleep gap -> no warning",        v(true, hour, hour, 1800) == .unattributable)
        check("no baseline yet -> healthy",                    v(true, hour, nil, 60) == .healthy)
        check("silent 9 min while running -> no warning yet",  v(true, hour, 540, 60) == .healthy)
        check("silent 15 min while running -> WARNS",          v(true, hour, 900, 60).isWarning)
        check("warning reports elapsed minutes",               v(true, hour, 900, 60) == .silent(minutes: 15))
        check("recovery clears the warning",                   !v(true, hour, 5, 60).isWarning)

        err.write(Data("verify-watchdog: \(fail == 0 ? "PASS" : "FAIL") — \(pass) ok, \(fail) failed\n".utf8))
    }
}
