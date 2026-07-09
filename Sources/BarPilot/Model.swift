import Foundation

// ---------------------------------------------------------------------------
// Core types
//
// A single normalised `UsageRecord` represents one billed LLM call,
// regardless of whether it came from the VS Code SQLite DB or the GitHub
// Copilot Mac App JSONL trace file. All views are derived from these records.
// ---------------------------------------------------------------------------

enum SourceKind: String {
    case vscode = "VS Code Copilot Chat"
    case macApp = "GitHub Copilot Mac App"
    /// One-time historical backfill from VS Code chat session files (recorded
    /// credits only, ≥ 2026-06-01). Tagged so it stays reversible. See ChatBackfill.
    case chatBackfill = "VS Code Chat (backfill)"
}

/// One billed LLM call (one OTel span carrying a `*_aiu` usage attribute).
struct UsageRecord {
    let source: SourceKind
    let spanId: String
    /// Raw model string as recorded by the source (may differ in punctuation,
    /// e.g. "claude-sonnet-4-6" vs "claude-sonnet-4.6"). `nil` only for VS Code
    /// spans with no response_model — surfaced as "unknown".
    let model: String?
    let startMs: Int64
    /// AIU credits (nano-AIU / 1e9).
    let credits: Double
    let inputTokens: Int
    let outputTokens: Int
    let conversationId: String?
    let chatSessionId: String?
    let operationName: String
    /// Reasoning-effort level the call ran at, as recorded by the source
    /// ("low"…"max"); `nil` for models/calls that don't set one. Raw value —
    /// harmonised for display in `Aggregator.normaliseLevel`.
    let reasoningLevel: String?
}

// ---------------------------------------------------------------------------
// Per-view aggregated rows
// ---------------------------------------------------------------------------

struct SummaryRow: Identifiable {
    let id = UUID()
    let model: String
    let calls: Int
    let credits: Double
    var cost: Double { credits / 100.0 }
}

struct ModelRow: Identifiable {
    let id = UUID()
    let model: String
    let calls: Int
    let credits: Double
    let inputTokens: Int
    let outputTokens: Int
    /// Effective per-token rates (AIU credits per token) from a least-squares
    /// fit of `credits = inRate·input + outRate·output` over this model's spans.
    /// `.nan` when the fit is degenerate (too few/collinear calls).
    let inRate: Double
    let outRate: Double
    /// Goodness-of-fit (uncentered R², 0…1); `.nan` when unsolvable.
    let fit: Double
    /// Per-reasoning-level breakdown of this model's spans, sorted by ascending
    /// effort. Always ≥ 1 element (one `nil`-level bucket for non-reasoning use);
    /// > 1 means the model was run at multiple levels and the UI groups them.
    let levels: [ModelLevelRow]
    var cost: Double { credits / 100.0 }
}

/// One reasoning-level slice within a model (a child row in the Models tab).
/// `level` is the normalised effort ("low"…"max"); `nil` = calls with no level.
struct ModelLevelRow: Identifiable {
    let id = UUID()
    let level: String?
    let calls: Int
    let credits: Double
    let inputTokens: Int
    let outputTokens: Int
    let inRate: Double
    let outRate: Double
    let fit: Double
    var cost: Double { credits / 100.0 }
}

struct DailyRow: Identifiable {
    let id = UUID()
    let day: String
    let model: String
    let calls: Int
    let credits: Double
    var cost: Double { credits / 100.0 }
}

struct SessionRow: Identifiable {
    let id = UUID()
    let sessionId: String
    let model: String
    let startedAt: Int64
    let lastActiveAt: Int64
    let calls: Int
    let credits: Double
    let inputTokens: Int
    let outputTokens: Int
    var cost: Double { credits / 100.0 }
}

struct TopRow: Identifiable {
    let id = UUID()
    let rank: Int
    let spanId: String
    let model: String
    let startedAt: Int64
    let operationName: String
    let credits: Double
    let inputTokens: Int
    let outputTokens: Int
    var cost: Double { credits / 100.0 }
}

/// One bar in the daily mini-chart (a single day's total across all models).
struct DayTotal: Identifiable {
    let id = UUID()
    let day: String
    let credits: Double
}

// ---------------------------------------------------------------------------
// The full report for a selected period
// ---------------------------------------------------------------------------

struct Report {
    var fromStr: String
    var toStr: String
    /// Inclusive number of calendar days in [fromStr, toStr].
    var daysInRange: Int
    var summary: [SummaryRow]
    var models: [ModelRow]
    var daily: [DailyRow]
    var dailyTotals: [DayTotal]
    var sessions: [SessionRow]
    var top: [TopRow]
    var totalCredits: Double
    /// Today's spend, evaluated with the same UTC-day bounds used elsewhere.
    var todayCredits: Double

    var totalCost: Double { totalCredits / 100.0 }
    var todayCost: Double { todayCredits / 100.0 }

    static let empty = Report(
        fromStr: "", toStr: "", daysInRange: 1,
        summary: [], models: [], daily: [], dailyTotals: [],
        sessions: [], top: [],
        totalCredits: 0, todayCredits: 0
    )
}

/// Which data sources were found, how many records each contributed, and
/// whether each source's OTel telemetry appears to be configured.
struct SourcesStatus {
    var vscodeFound = false
    var vscodeCount = 0
    var macAppFound = false
    var macAppCount = 0
    /// VS Code settings.json has all required `github.copilot.chat.otel.*` keys.
    var vscodeConfigured = false
    /// The Mac App OTel LaunchAgent + helper script are installed.
    var macAppConfigured = false

    var allConfigured: Bool { vscodeConfigured && macAppConfigured }
}

// ---------------------------------------------------------------------------
// Period selection
// ---------------------------------------------------------------------------

enum PeriodKind: String, CaseIterable, Identifiable {
    case today
    case last7
    case thisMonth
    case previousMonth
    case last30
    case thisYear
    case allTime
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .today: return "Today"
        case .last7: return "Last 7 Days"
        case .thisMonth: return "This Month"
        case .previousMonth: return "Previous Month"
        case .last30: return "Last 30 Days"
        case .thisYear: return "This Year"
        case .allTime: return "All Time"
        case .custom: return "Custom…"
        }
    }

    /// Heading for the budget-bar section — labels the SPEND figure it sits over
    /// (the budget is shown separately, on the right). See #17.
    var spendTitle: String {
        switch self {
        case .today: return "Today's spend"
        case .last7: return "Last 7 days' spend"
        case .thisMonth: return "This month's spend"
        case .previousMonth: return "Previous month's spend"
        case .last30: return "Last 30 days' spend"
        case .thisYear: return "This year's spend"
        case .allTime: return "All-time spend"
        case .custom: return "Selected range spend"
        }
    }
}

// ---------------------------------------------------------------------------
// Spend projection (#18) — run-rate estimate of full-month spend, shown on the
// budget bar. Pure + derived from the current report; no aggregation impact.
// ---------------------------------------------------------------------------

struct SpendProjection {
    let projectedCredits: Double
    let budgetCredits: Double
    let daysElapsed: Int
    let daysInPeriod: Int
    let endLabel: String            // "Jul 31"

    var hasBudget: Bool  { budgetCredits > 0 }
    var overBudget: Bool { hasBudget && projectedCredits > budgetCredits }
    var pctOfBudget: Double { hasBudget ? projectedCredits / budgetCredits * 100 : 0 }

    private static let endFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f
    }()

    /// Only projects an in-progress calendar month that has usage; nil otherwise.
    static func compute(periodKind: PeriodKind, report: Report,
                        monthlyBudgetUSD: Double, now: Date,
                        calendar: Calendar = .current) -> SpendProjection? {
        guard periodKind == .thisMonth,
              let dayRange = calendar.range(of: .day, in: .month, for: now),
              let month = calendar.dateInterval(of: .month, for: now) else { return nil }
        let daysInPeriod = dayRange.count
        let elapsed = max(report.daysInRange, 1)
        guard report.totalCredits > 0, elapsed < daysInPeriod else { return nil }
        let projected = report.totalCredits / Double(elapsed) * Double(daysInPeriod)
        let endDate = calendar.date(byAdding: .day, value: -1, to: month.end) ?? month.end
        return SpendProjection(
            projectedCredits: projected,
            budgetCredits: monthlyBudgetUSD * 100,
            daysElapsed: elapsed, daysInPeriod: daysInPeriod,
            endLabel: endFormatter.string(from: endDate))
    }

    // Headless regression check (--verify-projection): asserts compute() on
    // synthetic reports with a fixed clock, so the run-rate math + guards can't
    // silently drift. Mirrors the project's --dump / --verify-sync safety nets.
    static func verify() {
        let err = FileHandle.standardError
        var pass = 0, fail = 0
        func check(_ name: String, _ ok: Bool) {
            if ok { pass += 1 } else { fail += 1 }
            err.write(Data("  [\(ok ? "OK" : "XX")] \(name)\n".utf8))
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? cal.timeZone
        let now = cal.date(from: DateComponents(year: 2025, month: 7, day: 15))!   // mid-July (31 days)
        func report(days: Int, credits: Double) -> Report {
            var r = Report.empty; r.daysInRange = days; r.totalCredits = credits; return r
        }

        // Under budget: 300cr over 10 days -> 300/10*31 = 930cr; budget $150 = 15000cr.
        if let p = compute(periodKind: .thisMonth, report: report(days: 10, credits: 300), monthlyBudgetUSD: 150, now: now, calendar: cal) {
            check("run-rate projected (930cr)", abs(p.projectedCredits - 930) < 1e-6)
            check("days elapsed/period = 10/31", p.daysElapsed == 10 && p.daysInPeriod == 31)
            check("under budget, budget = 15000cr", !p.overBudget && p.budgetCredits == 15000)
        } else { check("mid-month returns a projection", false) }

        // Over budget: 6000cr over 10 days -> 18600cr > 15000cr.
        if let p = compute(periodKind: .thisMonth, report: report(days: 10, credits: 6000), monthlyBudgetUSD: 150, now: now, calendar: cal) {
            check("over budget flagged", p.overBudget && p.projectedCredits > p.budgetCredits)
        } else { check("over-budget returns a projection", false) }

        // No budget set: still projects the amount; no over/percent.
        if let p = compute(periodKind: .thisMonth, report: report(days: 10, credits: 300), monthlyBudgetUSD: 0, now: now, calendar: cal) {
            check("no budget -> not over, pct 0", !p.hasBudget && !p.overBudget && p.pctOfBudget == 0)
        } else { check("no-budget still projects", false) }

        check("no usage -> nil", compute(periodKind: .thisMonth, report: report(days: 10, credits: 0), monthlyBudgetUSD: 150, now: now, calendar: cal) == nil)
        check("last day of month -> nil", compute(periodKind: .thisMonth, report: report(days: 31, credits: 300), monthlyBudgetUSD: 150, now: now, calendar: cal) == nil)
        check("non-thisMonth period -> nil", compute(periodKind: .previousMonth, report: report(days: 10, credits: 300), monthlyBudgetUSD: 150, now: now, calendar: cal) == nil)

        err.write(Data("verify-projection: \(fail == 0 ? "PASS" : "FAIL") — \(pass) ok, \(fail) failed\n".utf8))
    }
}

// ---------------------------------------------------------------------------
// Formatting helpers
// ---------------------------------------------------------------------------

enum Fmt {
    /// 2 decimal places, e.g. "1094.16".
    static func credits(_ n: Double) -> String {
        String(format: "%.2f", n)
    }

    /// 4 decimal places — used only by the `--dump` output.
    static func credits4(_ n: Double) -> String {
        String(format: "%.4f", n)
    }

    /// USD from credits (100 credits = $1.00), e.g. "$10.94".
    static func cost(_ credits: Double) -> String {
        String(format: "$%.2f", credits / 100.0)
    }

    /// USD from a dollar amount directly, e.g. "$5.00".
    static func dollars(_ usd: Double) -> String {
        String(format: "$%.2f", usd)
    }

    /// USD without trailing ".00" for whole amounts, e.g. "$150" or "$99.50".
    static func money(_ usd: Double) -> String {
        usd == usd.rounded() ? String(format: "$%.0f", usd) : String(format: "$%.2f", usd)
    }

    private static let grouping: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    /// Thousands-separated integer, e.g. "14,641,544".
    static func int(_ n: Int) -> String {
        grouping.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// Abbreviated token count: 1,397 → "1.4K", 86,264,060 → "86.3M",
    /// 2,100,000,000 → "2.1B". One decimal below 100, none at/above.
    static func tokens(_ n: Int) -> String {
        func scaled(_ v: Double, _ suffix: String) -> String {
            String(format: v >= 100 ? "%.0f" : "%.1f", v) + suffix
        }
        let a = abs(n)
        if a >= 1_000_000_000 { return scaled(Double(n) / 1_000_000_000, "B") }
        if a >= 1_000_000     { return scaled(Double(n) / 1_000_000, "M") }
        if a >= 1_000         { return scaled(Double(n) / 1_000, "K") }
        return "\(n)"
    }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "MM/dd/yyyy, HH:mm"
        return f
    }()

    /// "06/03/2026, 14:05" — local time, 24-hour.
    static func dateTime(_ ms: Int64) -> String {
        dateFmt.string(from: Date(timeIntervalSince1970: Double(ms) / 1000.0))
    }

    /// Truncate long ids to "prefix…suffix" (16 visible chars).
    static func shortId(_ id: String) -> String {
        guard id.count > 16 else { return id }
        return "\(id.prefix(8))…\(id.suffix(8))"
    }
}
