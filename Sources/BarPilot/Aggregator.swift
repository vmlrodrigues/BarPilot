import Foundation

// ---------------------------------------------------------------------------
// Aggregation — turns raw UsageRecords into the per-view rows shown in the UI.
//
// The date math is exact and load-bearing:
//   • Range bounds are UTC: from = 00:00:00.000Z of the from-date,
//     to = 23:59:59.999Z of the to-date.
//   • Daily buckets use the LOCAL calendar date (not the UTC range bounds).
//   • Model names are normalised so "claude-sonnet-4-6" (VS Code) and
//     "claude-sonnet-4.6" (Mac App) merge — only a single trailing "-<digit>"
//     becomes ".<digit>" (so "...-2024-07-18" is untouched).
// ---------------------------------------------------------------------------

enum Aggregator {

    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// "YYYY-MM-DD" → UTC midnight, in epoch ms.
    static func utcMidnightMs(_ dateStr: String) -> Int64 {
        let parts = dateStr.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              let date = utcCalendar.date(from: DateComponents(year: y, month: m, day: d))
        else { return 0 }
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    /// Local calendar date string "YYYY-MM-DD" for an epoch-ms instant.
    static func localDayStr(_ ms: Int64) -> String {
        let d = Date(timeIntervalSince1970: Double(ms) / 1000.0)
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Replace a single trailing "-<digit>" with ".<digit>".
    static func normaliseModel(_ m: String) -> String {
        m.replacingOccurrences(of: "-(\\d)$", with: ".$1", options: .regularExpression)
    }

    private static func displayModel(_ raw: String?) -> String {
        normaliseModel(raw ?? "unknown")
    }

    // -----------------------------------------------------------------------
    // Build the full report for a [fromStr, toStr] window (inclusive).
    // -----------------------------------------------------------------------
    static func build(records: [UsageRecord], fromStr: String, toStr: String, todayStr: String) -> Report {
        let fromMs = utcMidnightMs(fromStr)
        let toMs = utcMidnightMs(toStr) + 86_399_999   // end of day .999

        let inRange = records.filter { $0.startMs >= fromMs && $0.startMs <= toMs }

        let days = Int((utcMidnightMs(toStr) - fromMs) / 86_400_000) + 1

        return Report(
            fromStr: fromStr,
            toStr: toStr,
            daysInRange: max(days, 1),
            summary: buildSummary(inRange),
            models: buildModels(inRange),
            daily: buildDaily(inRange),
            dailyTotals: buildDailyTotals(inRange),
            sessions: buildSessions(inRange),
            top: buildTop(inRange, n: 20),
            totalCredits: inRange.reduce(0) { $0 + $1.credits },
            todayCredits: todayCredits(records, todayStr: todayStr)
        )
    }

    private static func todayCredits(_ records: [UsageRecord], todayStr: String) -> Double {
        let from = utcMidnightMs(todayStr)
        let to = from + 86_399_999
        return records.filter { $0.startMs >= from && $0.startMs <= to }
            .reduce(0) { $0 + $1.credits }
    }

    // -----------------------------------------------------------------------
    // Summary — credits by model
    // -----------------------------------------------------------------------
    private static func buildSummary(_ recs: [UsageRecord]) -> [SummaryRow] {
        var calls: [String: Int] = [:]
        var credits: [String: Double] = [:]
        for r in recs {
            let m = displayModel(r.model)
            calls[m, default: 0] += 1
            credits[m, default: 0] += r.credits
        }
        return credits.keys
            .map { SummaryRow(model: $0, calls: calls[$0] ?? 0, credits: credits[$0] ?? 0) }
            .sorted { $0.credits > $1.credits }
    }

    // -----------------------------------------------------------------------
    // Models — credits + token breakdown by model
    // -----------------------------------------------------------------------
    private static func buildModels(_ recs: [UsageRecord]) -> [ModelRow] {
        struct Acc { var calls = 0; var credits = 0.0; var inTok = 0; var outTok = 0 }
        var acc: [String: Acc] = [:]
        for r in recs {
            let m = displayModel(r.model)
            acc[m, default: Acc()].calls += 1
            acc[m, default: Acc()].credits += r.credits
            acc[m, default: Acc()].inTok += r.inputTokens
            acc[m, default: Acc()].outTok += r.outputTokens
        }
        return acc.map {
            ModelRow(model: $0.key, calls: $0.value.calls, credits: $0.value.credits,
                     inputTokens: $0.value.inTok, outputTokens: $0.value.outTok)
        }
        .sorted { $0.credits > $1.credits }
    }

    // -----------------------------------------------------------------------
    // Daily — credits per local day per model
    // -----------------------------------------------------------------------
    private static func buildDaily(_ recs: [UsageRecord]) -> [DailyRow] {
        struct Acc { var calls = 0; var credits = 0.0 }
        var acc: [String: Acc] = [:]   // key = "day|model"
        var dayOf: [String: String] = [:]
        var modelOf: [String: String] = [:]
        for r in recs {
            let day = localDayStr(r.startMs)
            let m = displayModel(r.model)
            let key = "\(day)|\(m)"
            acc[key, default: Acc()].calls += 1
            acc[key, default: Acc()].credits += r.credits
            dayOf[key] = day
            modelOf[key] = m
        }
        return acc.map {
            DailyRow(day: dayOf[$0.key] ?? "", model: modelOf[$0.key] ?? "",
                     calls: $0.value.calls, credits: $0.value.credits)
        }
        .sorted { a, b in
            a.day == b.day ? a.credits > b.credits : a.day < b.day
        }
    }

    private static func buildDailyTotals(_ recs: [UsageRecord]) -> [DayTotal] {
        var totals: [String: Double] = [:]
        for r in recs {
            totals[localDayStr(r.startMs), default: 0] += r.credits
        }
        return totals.map { DayTotal(day: $0.key, credits: $0.value) }
            .sorted { $0.day < $1.day }
    }

    // -----------------------------------------------------------------------
    // Sessions — credits per chat session
    // -----------------------------------------------------------------------
    private static func buildSessions(_ recs: [UsageRecord]) -> [SessionRow] {
        struct Acc {
            var calls = 0; var credits = 0.0; var inTok = 0; var outTok = 0
            var startedAt = Int64.max
            var topModel = ""; var topModelCredits = -1.0
        }
        var acc: [String: Acc] = [:]
        for r in recs {
            let key = r.conversationId ?? r.chatSessionId ?? "unknown"
            var a = acc[key] ?? Acc()
            a.calls += 1
            a.credits += r.credits
            a.inTok += r.inputTokens
            a.outTok += r.outputTokens
            a.startedAt = min(a.startedAt, r.startMs)
            // Attribute the session to its highest-credit call's model.
            if r.credits > a.topModelCredits {
                a.topModelCredits = r.credits
                a.topModel = displayModel(r.model)
            }
            acc[key] = a
        }
        return acc.map {
            SessionRow(sessionId: $0.key, model: $0.value.topModel, startedAt: $0.value.startedAt,
                       calls: $0.value.calls, credits: $0.value.credits,
                       inputTokens: $0.value.inTok, outputTokens: $0.value.outTok)
        }
        .sorted { $0.credits > $1.credits }
    }

    // -----------------------------------------------------------------------
    // Top — N most expensive individual calls
    // -----------------------------------------------------------------------
    private static func buildTop(_ recs: [UsageRecord], n: Int) -> [TopRow] {
        return recs.sorted { $0.credits > $1.credits }
            .prefix(n)
            .enumerated()
            .map { idx, r in
                TopRow(rank: idx + 1, spanId: r.spanId, model: displayModel(r.model),
                       startedAt: r.startMs, operationName: r.operationName,
                       credits: r.credits, inputTokens: r.inputTokens, outputTokens: r.outputTokens)
            }
    }
}

// ---------------------------------------------------------------------------
// Period → (fromStr, toStr) date strings, computed in the LOCAL calendar
// (local date components).
// ---------------------------------------------------------------------------

enum PeriodResolver {

    static func todayStr() -> String {
        dateStr(Date())
    }

    static func dateStr(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func range(kind: PeriodKind, customFrom: Date, customTo: Date) -> (from: String, to: String) {
        let cal = Calendar.current
        let now = Date()
        let today = dateStr(now)

        switch kind {
        case .today:
            return (today, today)
        case .last7:
            let from = cal.date(byAdding: .day, value: -6, to: now) ?? now
            return (dateStr(from), today)
        case .thisMonth:
            let comps = cal.dateComponents([.year, .month], from: now)
            let first = cal.date(from: comps) ?? now
            return (dateStr(first), today)
        case .last30:
            let from = cal.date(byAdding: .day, value: -29, to: now) ?? now
            return (dateStr(from), today)
        case .thisYear:
            let comps = cal.dateComponents([.year], from: now)
            let first = cal.date(from: comps) ?? now
            return (dateStr(first), today)
        case .allTime:
            return ("2000-01-01", today)
        case .custom:
            // Keep ordering sane even if the user inverts the pickers.
            let a = dateStr(customFrom), b = dateStr(customTo)
            return a <= b ? (a, b) : (b, a)
        }
    }
}
