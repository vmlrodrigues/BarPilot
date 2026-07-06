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

    /// UTC calendar date string "YYYY-MM-DD" for an epoch-ms instant — the bucket
    /// used by the cross-machine synced aggregate (unambiguous across timezones,
    /// and matches GitHub's UTC billing cycle). Distinct from `localDayStr`, which
    /// the single-machine Daily tab uses.
    static func utcDayStr(_ ms: Int64) -> String {
        let d = Date(timeIntervalSince1970: Double(ms) / 1000.0)
        let c = utcCalendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Replace a single trailing "-<digit>" with ".<digit>".
    static func normaliseModel(_ m: String) -> String {
        m.replacingOccurrences(of: "-(\\d)$", with: ".$1", options: .regularExpression)
    }

    private static func displayModel(_ raw: String?) -> String {
        normaliseModel(raw ?? "unknown")
    }

    /// Canonical reasoning-effort label: trimmed + lowercased. Both sources use
    /// the same words (low/medium/high/xhigh/max), so this only harmonises casing.
    static func normaliseLevel(_ level: String?) -> String? {
        guard let l = level?.trimmingCharacters(in: .whitespaces).lowercased(), !l.isEmpty else { return nil }
        return l
    }

    /// Display order for reasoning levels (ascending effort). Unknown labels sort
    /// after these; the no-level (`nil`) bucket sorts last of all.
    static let levelOrder: [String: Int] = ["minimal": 0, "low": 1, "medium": 2, "high": 3, "xhigh": 4, "max": 5]

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
        // Plain totals + the cross-product sums needed for a least-squares fit of
        // credits against (input, output) tokens. Accumulated at BOTH the model
        // level (the reliable, all-spans fit shown on the group row) and per
        // (model, reasoning-level) so each level's own rate/fit can be shown.
        struct Acc {
            var calls = 0; var credits = 0.0; var inTok = 0; var outTok = 0
            var sii = 0.0, soo = 0.0, sio = 0.0, sic = 0.0, soc = 0.0, scc = 0.0
            mutating func add(_ r: UsageRecord) {
                let i = Double(r.inputTokens), o = Double(r.outputTokens), c = r.credits
                calls += 1; credits += c; inTok += r.inputTokens; outTok += r.outputTokens
                sii += i*i; soo += o*o; sio += i*o
                sic += i*c; soc += o*c; scc += c*c
            }
        }
        var byModel: [String: Acc] = [:]
        var byLevel: [String: [String: Acc]] = [:]   // model -> levelKey ("" = no level) -> Acc
        for r in recs {
            let m = displayModel(r.model)
            let lk = normaliseLevel(r.reasoningLevel) ?? ""
            byModel[m, default: Acc()].add(r)
            byLevel[m, default: [:]][lk, default: Acc()].add(r)
        }
        func levelSortOrder(_ level: String?) -> Int {
            level == nil ? 99 : (levelOrder[level!] ?? 98)
        }
        return byModel.map { model, a -> ModelRow in
            let mf = fitRates(sii: a.sii, soo: a.soo, sio: a.sio, sic: a.sic, soc: a.soc, scc: a.scc)
            let levels: [ModelLevelRow] = (byLevel[model] ?? [:]).map { lk, la in
                let lf = fitRates(sii: la.sii, soo: la.soo, sio: la.sio, sic: la.sic, soc: la.soc, scc: la.scc)
                return ModelLevelRow(level: lk.isEmpty ? nil : lk,
                                     calls: la.calls, credits: la.credits,
                                     inputTokens: la.inTok, outputTokens: la.outTok,
                                     inRate: lf.inRate, outRate: lf.outRate, fit: lf.fit)
            }
            .sorted { l1, l2 in
                let o1 = levelSortOrder(l1.level), o2 = levelSortOrder(l2.level)
                return o1 != o2 ? o1 < o2 : l1.credits > l2.credits
            }
            return ModelRow(model: model, calls: a.calls, credits: a.credits,
                            inputTokens: a.inTok, outputTokens: a.outTok,
                            inRate: mf.inRate, outRate: mf.outRate, fit: mf.fit,
                            levels: levels)
        }
        .sorted { $0.credits > $1.credits }
    }

    /// Least-squares fit (no intercept) of `credits = inRate·in + outRate·out`,
    /// returning credits-per-token rates and the uncentered R². Returns `.nan`
    /// when the system is degenerate or yields a negative rate (collinear or
    /// too-few spans to separate input from output cost).
    static func fitRates(sii: Double, soo: Double, sio: Double,
                         sic: Double, soc: Double, scc: Double)
        -> (inRate: Double, outRate: Double, fit: Double) {
        let det = sii*soo - sio*sio
        guard det != 0 else { return (.nan, .nan, .nan) }
        let inRate = (sic*soo - soc*sio) / det
        let outRate = (sii*soc - sio*sic) / det
        guard inRate >= 0, outRate >= 0 else { return (.nan, .nan, .nan) }
        let ssRes = scc - 2*inRate*sic - 2*outRate*soc +
            inRate*inRate*sii + 2*inRate*outRate*sio + outRate*outRate*soo
        let fit = scc > 0 ? 1 - ssRes/scc : .nan
        return (inRate, outRate, fit)
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
            var startedAt = Int64.max; var lastActiveAt = Int64.min
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
            a.lastActiveAt = max(a.lastActiveAt, r.startMs)
            // Attribute the session to its highest-credit call's model.
            if r.credits > a.topModelCredits {
                a.topModelCredits = r.credits
                a.topModel = displayModel(r.model)
            }
            acc[key] = a
        }
        return acc.map {
            SessionRow(sessionId: $0.key, model: $0.value.topModel,
                       startedAt: $0.value.startedAt, lastActiveAt: $0.value.lastActiveAt,
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

    // -----------------------------------------------------------------------
    // Combined (multi-machine) build — Summary/Models/Daily/total/sparkline from
    // pooled aggregate rows (this machine's projection + remote machines');
    // Sessions/Top stay LOCAL. Daily buckets by UTC day (Design Decision 1).
    // Sync-OFF never calls this — it uses build(...) — so OFF stays byte-identical.
    // -----------------------------------------------------------------------
    static func buildCombined(localRecords: [UsageRecord], remoteAggregates: [MachineAggregate],
                              fromStr: String, toStr: String, todayStr: String) -> Report {
        let localAgg = SyncAggregate.project(localRecords, machineId: "local", label: nil, updatedAt: "")
        let allRows = localAgg.rows + remoteAggregates.flatMap { $0.rows }
        let rows = allRows.filter { $0.utcDay >= fromStr && $0.utcDay <= toStr }

        let fromMs = utcMidnightMs(fromStr)
        let toMs = utcMidnightMs(toStr) + 86_399_999
        let localInRange = localRecords.filter { $0.startMs >= fromMs && $0.startMs <= toMs }
        let days = Int((utcMidnightMs(toStr) - fromMs) / 86_400_000) + 1
        let todayCredits = allRows.filter { $0.utcDay == todayStr }.reduce(0.0) { $0 + $1.credits }

        return Report(
            fromStr: fromStr, toStr: toStr, daysInRange: max(days, 1),
            summary: summaryFromRows(rows),
            models: modelsFromRows(rows),
            daily: dailyFromRows(rows),
            dailyTotals: dailyTotalsFromRows(rows),
            sessions: buildSessions(localInRange),   // local only — a session lives on one machine
            top: buildTop(localInRange, n: 20),       // local only
            totalCredits: rows.reduce(0.0) { $0 + $1.credits },
            todayCredits: todayCredits
        )
    }

    // Aggregate-row builders — parallel the record builders but sum pre-aggregated
    // rows (which already carry the cross-products), so the Models fit reconstructs.
    private struct RowAcc {
        var calls = 0; var credits = 0.0; var inTok = 0; var outTok = 0
        var sii = 0.0, soo = 0.0, sio = 0.0, sic = 0.0, soc = 0.0, scc = 0.0
        mutating func add(_ r: AggregateRow) {
            calls += r.calls; credits += r.credits; inTok += r.inTok; outTok += r.outTok
            sii += r.sii; soo += r.soo; sio += r.sio; sic += r.sic; soc += r.soc; scc += r.scc
        }
    }

    private static func summaryFromRows(_ rows: [AggregateRow]) -> [SummaryRow] {
        var calls: [String: Int] = [:]; var credits: [String: Double] = [:]
        for r in rows { calls[r.model, default: 0] += r.calls; credits[r.model, default: 0] += r.credits }
        return credits.keys
            .map { SummaryRow(model: $0, calls: calls[$0] ?? 0, credits: credits[$0] ?? 0) }
            .sorted { $0.credits > $1.credits }
    }

    private static func modelsFromRows(_ rows: [AggregateRow]) -> [ModelRow] {
        var byModel: [String: RowAcc] = [:]
        var byLevel: [String: [String: RowAcc]] = [:]
        for r in rows {
            let lk = r.level ?? ""
            byModel[r.model, default: RowAcc()].add(r)
            byLevel[r.model, default: [:]][lk, default: RowAcc()].add(r)
        }
        func ord(_ level: String?) -> Int { level == nil ? 99 : (levelOrder[level!] ?? 98) }
        return byModel.map { model, a -> ModelRow in
            let mf = fitRates(sii: a.sii, soo: a.soo, sio: a.sio, sic: a.sic, soc: a.soc, scc: a.scc)
            let levels: [ModelLevelRow] = (byLevel[model] ?? [:]).map { lk, la in
                let lf = fitRates(sii: la.sii, soo: la.soo, sio: la.sio, sic: la.sic, soc: la.soc, scc: la.scc)
                return ModelLevelRow(level: lk.isEmpty ? nil : lk, calls: la.calls, credits: la.credits,
                                     inputTokens: la.inTok, outputTokens: la.outTok,
                                     inRate: lf.inRate, outRate: lf.outRate, fit: lf.fit)
            }
            .sorted { l1, l2 in let o1 = ord(l1.level), o2 = ord(l2.level); return o1 != o2 ? o1 < o2 : l1.credits > l2.credits }
            return ModelRow(model: model, calls: a.calls, credits: a.credits,
                            inputTokens: a.inTok, outputTokens: a.outTok,
                            inRate: mf.inRate, outRate: mf.outRate, fit: mf.fit, levels: levels)
        }
        .sorted { $0.credits > $1.credits }
    }

    private static func dailyFromRows(_ rows: [AggregateRow]) -> [DailyRow] {
        struct Acc { var calls = 0; var credits = 0.0 }
        var acc: [String: Acc] = [:]; var dayOf: [String: String] = [:]; var modelOf: [String: String] = [:]
        for r in rows {
            let key = "\(r.utcDay)|\(r.model)"
            acc[key, default: Acc()].calls += r.calls
            acc[key, default: Acc()].credits += r.credits
            dayOf[key] = r.utcDay; modelOf[key] = r.model
        }
        return acc.map { DailyRow(day: dayOf[$0.key] ?? "", model: modelOf[$0.key] ?? "",
                                  calls: $0.value.calls, credits: $0.value.credits) }
            .sorted { a, b in a.day == b.day ? a.credits > b.credits : a.day < b.day }
    }

    private static func dailyTotalsFromRows(_ rows: [AggregateRow]) -> [DayTotal] {
        var totals: [String: Double] = [:]
        for r in rows { totals[r.utcDay, default: 0] += r.credits }
        return totals.map { DayTotal(day: $0.key, credits: $0.value) }.sorted { $0.day < $1.day }
    }
}

// ---------------------------------------------------------------------------
// Period → (fromStr, toStr) date strings. All computed boundaries use UTC
// so that "This Month" / "This Year" / "Today" align with GitHub's billing
// cycle, which resets at UTC midnight on the 1st of each month.
// ---------------------------------------------------------------------------

enum PeriodResolver {

    private static let utcCal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    static func todayStr() -> String {
        utcDateStr(Date())
    }

    // UTC date string — used for all computed period boundaries.
    private static func utcDateStr(_ date: Date) -> String {
        let c = utcCal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // Local date string — used only for custom DatePicker dates, where the
    // user has selected a calendar date in their local timezone.
    static func dateStr(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func range(kind: PeriodKind, customFrom: Date, customTo: Date) -> (from: String, to: String) {
        let now = Date()
        let today = utcDateStr(now)

        switch kind {
        case .today:
            return (today, today)
        case .last7:
            let from = utcCal.date(byAdding: .day, value: -6, to: now) ?? now
            return (utcDateStr(from), today)
        case .thisMonth:
            let comps = utcCal.dateComponents([.year, .month], from: now)
            let first = utcCal.date(from: comps) ?? now
            return (utcDateStr(first), today)
        case .previousMonth:
            // First→last day of the prior calendar month (UTC). Calendar
            // arithmetic handles the Jan→Dec year rollover for free.
            let firstOfThis = utcCal.date(from: utcCal.dateComponents([.year, .month], from: now)) ?? now
            let lastOfPrev  = utcCal.date(byAdding: .day, value: -1, to: firstOfThis) ?? now
            let firstOfPrev = utcCal.date(from: utcCal.dateComponents([.year, .month], from: lastOfPrev)) ?? now
            return (utcDateStr(firstOfPrev), utcDateStr(lastOfPrev))
        case .last30:
            let from = utcCal.date(byAdding: .day, value: -29, to: now) ?? now
            return (utcDateStr(from), today)
        case .thisYear:
            let comps = utcCal.dateComponents([.year], from: now)
            let first = utcCal.date(from: comps) ?? now
            return (utcDateStr(first), today)
        case .allTime:
            return ("2000-01-01", today)
        case .custom:
            // DatePicker gives local midnight — use local calendar so the
            // selected calendar date maps correctly to a UTC date string.
            let a = dateStr(customFrom), b = dateStr(customTo)
            return a <= b ? (a, b) : (b, a)
        }
    }
}
