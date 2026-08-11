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
        periodKind: PeriodKind,
        snapshot: CreditSample?,
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
        out.models.append(ModelRow(
            model: unclassifiedLabel, calls: 0, credits: unclassified,
            inputTokens: 0, outputTokens: 0,
            inRate: .nan, outRate: .nan, fit: .nan, levels: []
        ))
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
            report: report, periodKind: .thisMonth,
            snapshot: CreditSample(capturedAtMs: t2, serverAtMs: nil,
                                   resetAtMs: reset, creditsUsed: 100),
            now: Date(timeIntervalSince1970: Double(t2) / 1000)
        )
        precondition(reconciled.totalCredits == 100
                     && reconciled.unclassifiedCredits == 20
                     && reconciled.summary.last?.model == unclassifiedLabel
                     && reconciled.models.last?.model == unclassifiedLabel,
                     "unclassified usage must remain a separated final bucket")
        precondition(!reconciled.daily.contains { $0.model == unclassifiedLabel },
                     "daily usage must remain classified-only")
        print("credit reconciliation verification passed")
    }
}
