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
    var cost: Double { credits / 100.0 }
}

struct DailyRow: Identifiable {
    let id = UUID()
    let day: String
    let model: String
    let calls: Int
    let credits: Double
}

struct SessionRow: Identifiable {
    let id = UUID()
    let sessionId: String
    let model: String
    let startedAt: Int64
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
        case .last30: return "Last 30 Days"
        case .thisYear: return "This Year"
        case .allTime: return "All Time"
        case .custom: return "Custom…"
        }
    }

    /// Title for the budget bar, matching the selected span.
    var budgetTitle: String {
        switch self {
        case .today: return "Today's budget"
        case .last7: return "Last 7 days' budget"
        case .thisMonth: return "This month's budget"
        case .last30: return "Last 30 days' budget"
        case .thisYear: return "This year's budget"
        case .allTime: return "All-time budget"
        case .custom: return "Selected range budget"
        }
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
