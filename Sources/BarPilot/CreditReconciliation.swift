import Foundation

// ---------------------------------------------------------------------------
// CreditReconciliation — server truth over local attribution.
//
// The local report remains untouched. For the current UTC billing cycle only,
// the server counter supplies the headline total and any positive difference is
// surfaced as "Unclassified"; it is never spread across known models/sessions.
// ---------------------------------------------------------------------------

struct ReconciledUsage {
    var isCurrentCycle = false
    var totalCredits = 0.0
    var classifiedCredits = 0.0
    var unclassifiedCredits = 0.0
    var summary: [SummaryRow] = []
    var models: [ModelRow] = []
    var daily: [DailyRow] = []
    var dailyTotals: [DayTotal] = []
    var todayCredits = 0.0
    var unallocatedDailyCredits = 0.0

    static func local(_ report: Report) -> ReconciledUsage {
        ReconciledUsage(
            totalCredits: report.totalCredits,
            classifiedCredits: report.totalCredits,
            summary: report.summary,
            models: report.models,
            daily: report.daily,
            dailyTotals: report.dailyTotals,
            todayCredits: report.todayCredits
        )
    }
}

enum CreditReconciliation {
    static let unclassifiedLabel = "Unclassified"

    static func build(
        report: Report,
        records: [UsageRecord],
        periodKind: PeriodKind,
        snapshot: CreditSample?,
        samples: [CreditSample],
        syncEnabled: Bool,
        now: Date = Date()
    ) -> ReconciledUsage {
        guard periodKind == .thisMonth,
              let snapshot,
              matchesCurrentCycle(snapshot: snapshot, report: report, now: now) else {
            return .local(report)
        }

        let total = max(snapshot.creditsUsed, report.totalCredits)
        let unclassified = max(0, total - report.totalCredits)
        var out = ReconciledUsage.local(report)
        out.isCurrentCycle = true
        out.totalCredits = total
        out.unclassifiedCredits = unclassified

        guard unclassified > 0 else { return out }

        out.summary.append(SummaryRow(model: unclassifiedLabel, calls: 0, credits: unclassified))
        out.summary.sort { $0.credits > $1.credits }
        out.models.append(ModelRow(
            model: unclassifiedLabel, calls: 0, credits: unclassified,
            inputTokens: 0, outputTokens: 0,
            inRate: .nan, outRate: .nan, fit: .nan, levels: []
        ))
        out.models.sort { $0.credits > $1.credits }

        // Remote gist aggregates have no interval timestamps, so an honest daily
        // gap cannot be derived while sync is combining machines.
        guard !syncEnabled else {
            out.unallocatedDailyCredits = unclassified
            return out
        }

        let gaps = dailyGaps(
            samples: samples, records: records,
            maximumUnclassified: unclassified
        )
        for (day, credits) in gaps where credits > 0 {
            out.daily.append(DailyRow(day: day, model: unclassifiedLabel, calls: 0, credits: credits))
        }
        out.daily.sort {
            $0.day == $1.day ? $0.credits > $1.credits : $0.day < $1.day
        }
        let gapTotal = gaps.values.reduce(0, +)
        out.unallocatedDailyCredits = max(0, unclassified - gapTotal)

        var totals = Dictionary(uniqueKeysWithValues: report.dailyTotals.map { ($0.day, $0.credits) })
        for (day, credits) in gaps { totals[day, default: 0] += credits }
        out.dailyTotals = totals.map { DayTotal(day: $0.key, credits: $0.value) }
            .sorted { $0.day < $1.day }

        let today = Aggregator.localDayStr(Int64(now.timeIntervalSince1970 * 1000))
        out.todayCredits = report.todayCredits + (gaps[today] ?? 0)
        return out
    }

    /// Missing server credits observed between consecutive successful samples,
    /// attributed to the local calendar day of the later sample.
    static func dailyGaps(
        samples: [CreditSample],
        records: [UsageRecord],
        maximumUnclassified: Double? = nil
    ) -> [String: Double] {
        let ordered = samples.sorted { $0.capturedAtMs < $1.capturedAtMs }
        guard ordered.count >= 2 else { return [:] }
        var out: [String: Double] = [:]
        for i in 1..<ordered.count {
            let previous = ordered[i - 1]
            let current = ordered[i]
            guard current.resetAtMs == previous.resetAtMs,
                  current.creditsUsed >= previous.creditsUsed else { continue }
            let day = Aggregator.localDayStr(current.capturedAtMs)
            // If the app was asleep or closed across local midnight, the delta's
            // day is unknowable. Keep it in the unallocated bucket.
            guard Aggregator.localDayStr(previous.capturedAtMs) == day else { continue }
            let serverDelta = current.creditsUsed - previous.creditsUsed
            guard serverDelta > 0 else { continue }
            let localDelta = records.lazy
                .filter { $0.startMs > previous.capturedAtMs && $0.startMs <= current.capturedAtMs }
                .reduce(0.0) { $0 + $1.credits }
            let gap = max(0, serverDelta - localDelta)
            if gap > 0 {
                out[day, default: 0] += gap
            }
        }
        // Telemetry can arrive after the server counter. If interval gaps now
        // exceed the current account-vs-local difference, their day attribution
        // is no longer defensible; leave the entire balance unallocated.
        if let maximumUnclassified,
           out.values.reduce(0, +) > maximumUnclassified + 0.0001 {
            return [:]
        }
        return out
    }

    private static func matchesCurrentCycle(snapshot: CreditSample, report: Report, now: Date) -> Bool {
        guard snapshot.resetAt > now else { return false }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        guard let start = utc.date(byAdding: .month, value: -1, to: snapshot.resetAt) else { return false }
        return Aggregator.utcDayStr(Int64(start.timeIntervalSince1970 * 1000)) == report.fromStr
            && Aggregator.utcDayStr(Int64(now.timeIntervalSince1970 * 1000)) == report.toStr
    }

    static func verify() {
        let reset = Aggregator.utcMidnightMs("2030-02-01")
        let t0 = Aggregator.utcMidnightMs("2030-01-10")
        let t1 = t0 + 60_000
        let t2 = t1 + 60_000
        let samples = [
            CreditSample(capturedAtMs: t0, serverAtMs: nil, resetAtMs: reset, creditsUsed: 100),
            CreditSample(capturedAtMs: t1, serverAtMs: nil, resetAtMs: reset, creditsUsed: 150),
            CreditSample(capturedAtMs: t2, serverAtMs: nil, resetAtMs: reset + 2_678_400_000, creditsUsed: 2)
        ]
        let records = [
            UsageRecord(source: .vscode, spanId: "a", model: "test", startMs: t0 + 30_000,
                        credits: 30, inputTokens: 1, outputTokens: 1,
                        conversationId: nil, chatSessionId: nil,
                        operationName: "chat", reasoningLevel: nil)
        ]
        let gaps = dailyGaps(samples: samples, records: records)
        precondition(abs((gaps.values.first ?? 0) - 20) < 0.0001,
                     "server delta minus local attribution must be unclassified")
        precondition(gaps.values.reduce(0, +) == 20,
                     "reset boundaries must never be diffed")

        let crossDay = [
            CreditSample(capturedAtMs: t0, serverAtMs: nil, resetAtMs: reset, creditsUsed: 100),
            CreditSample(capturedAtMs: t0 + 86_400_000, serverAtMs: nil, resetAtMs: reset, creditsUsed: 150)
        ]
        precondition(dailyGaps(samples: crossDay, records: []).isEmpty,
                     "cross-day polling gaps must remain unallocated")

        let laggedSamples = [
            CreditSample(capturedAtMs: t0, serverAtMs: nil, resetAtMs: reset, creditsUsed: 0),
            CreditSample(capturedAtMs: t1, serverAtMs: nil, resetAtMs: reset, creditsUsed: 50),
            CreditSample(capturedAtMs: t2, serverAtMs: nil, resetAtMs: reset, creditsUsed: 50)
        ]
        let laggedRecord = UsageRecord(
            source: .vscode, spanId: "late", model: "test", startMs: t1 + 30_000,
            credits: 40, inputTokens: 1, outputTokens: 1,
            conversationId: nil, chatSessionId: nil,
            operationName: "chat", reasoningLevel: nil
        )
        precondition(dailyGaps(
            samples: laggedSamples, records: [laggedRecord],
            maximumUnclassified: 10
        ).isEmpty, "daily attribution must never exceed the current gap")

        let fixture = """
        {
          "quota_reset_date_utc": "2030-02-01T00:00:00Z",
          "quota_snapshots": {
            "premium_interactions": {
              "credits_used": 100.5,
              "timestamp_utc": "2030-01-10T00:02:00.000Z"
            }
          }
        }
        """
        let parsed = try! CreditUsageAPI.parse(data: Data(fixture.utf8), capturedAt: Date(timeIntervalSince1970: Double(t2) / 1000))
        precondition(parsed.creditsUsed == 100.5 && parsed.resetAtMs == reset,
                     "account response fields must parse without lossy defaults")
        let alternateFixture = """
        {
          "quota_reset_date": "2030-02-01",
          "quota_snapshots": {
            "premium_interactions": { "credits_used": "100.5" }
          }
        }
        """
        let alternate = try! CreditUsageAPI.parse(
            data: Data(alternateFixture.utf8),
            capturedAt: Date(timeIntervalSince1970: Double(t2) / 1000)
        )
        precondition(alternate.creditsUsed == 100.5 && alternate.resetAtMs == reset,
                     "alternate reset fields and numeric strings must remain compatible")

        var report = Report.empty
        report.fromStr = "2030-01-01"
        report.toStr = "2030-01-10"
        report.totalCredits = 80
        let reconciled = build(
            report: report, records: records, periodKind: .thisMonth,
            snapshot: CreditSample(capturedAtMs: t2, serverAtMs: nil,
                                   resetAtMs: reset, creditsUsed: 100),
            samples: Array(samples.prefix(2)), syncEnabled: false,
            now: Date(timeIntervalSince1970: Double(t2) / 1000)
        )
        precondition(reconciled.totalCredits == 100
                     && reconciled.unclassifiedCredits == 20
                     && reconciled.summary.contains { $0.model == unclassifiedLabel },
                     "current-cycle total must reconcile without inventing attribution")
        print("credit reconciliation verification passed")
    }
}
