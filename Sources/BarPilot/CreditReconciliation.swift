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

    /// The cycle a sample belongs to is `[resetAt - 1 month, resetAt)`. Copilot
    /// resets are not always UTC midnight on the 1st — the account response
    /// carries the reset in four different fields, two of which encode a
    /// time-of-day, and anniversary-billed accounts never land on the 1st. So
    /// this is deliberately interval containment, not calendar-month equality:
    /// requiring alignment silently disabled the whole server dashboard for
    /// those accounts. Callers that must line up with a locally aggregated
    /// calendar-month range add that check themselves (`matchesCurrentCycle`).
    static func cycleStart(for sample: CreditSample) -> Date? {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return utc.date(byAdding: .month, value: -1, to: sample.resetAt)
    }

    /// Guards against a nonsense reset far in the future being treated as the
    /// current cycle; the longest real cycle is a 31-day month.
    private static let maxCycleLength: TimeInterval = 40 * 24 * 60 * 60

    static func isCurrentCycle(_ sample: CreditSample, now: Date = Date()) -> Bool {
        guard sample.resetAt > now,
              sample.resetAt.timeIntervalSince(now) <= maxCycleLength,
              let start = cycleStart(for: sample) else { return false }
        return start <= now
    }

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

    /// The legacy overlay sits on top of a locally aggregated calendar-month
    /// report, so it additionally requires the cycle to line up with that range.
    /// A non-calendar cycle simply falls back to the local report rather than
    /// mixing two different windows.
    private static func matchesCurrentCycle(snapshot: CreditSample, report: Report, now: Date) -> Bool {
        guard isCurrentCycle(snapshot, now: now),
              let start = cycleStart(for: snapshot) else { return false }
        return Aggregator.utcDayStr(Int64(start.timeIntervalSince1970 * 1000)) == report.fromStr
            && Aggregator.utcDayStr(Int64(now.timeIntervalSince1970 * 1000)) == report.toStr
    }

    static func verify() {
        CreditTimeline.verify()
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

        // A reset that is not UTC midnight on the 1st must still count as the
        // current cycle — otherwise the whole server dashboard goes blank for
        // anniversary-billed and time-of-day resets, with no error shown.
        func sample(resetISO: String) -> CreditSample {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            let reset = f.date(from: resetISO)!
            return CreditSample(capturedAtMs: 0, serverAtMs: nil,
                                resetAtMs: Int64(reset.timeIntervalSince1970 * 1000),
                                creditsUsed: 10)
        }
        let midCycle = ISO8601DateFormatter().date(from: "2030-01-20T12:00:00Z")!
        precondition(isCurrentCycle(sample(resetISO: "2030-02-01T08:00:00Z"), now: midCycle),
                     "a non-midnight reset must still be the current cycle")
        precondition(isCurrentCycle(sample(resetISO: "2030-01-25T00:00:00Z"), now: midCycle),
                     "an anniversary reset must still be the current cycle")
        precondition(!isCurrentCycle(sample(resetISO: "2029-12-01T00:00:00Z"), now: midCycle),
                     "an elapsed cycle must not be current")
        precondition(!isCurrentCycle(sample(resetISO: "2030-06-01T00:00:00Z"), now: midCycle),
                     "a reset beyond one cycle length must not be current")
        precondition(!isCurrentCycle(sample(resetISO: "2030-01-21T00:00:00Z"), now:
                        ISO8601DateFormatter().date(from: "2029-12-01T00:00:00Z")!),
                     "a cycle that has not started must not be current")

        // The legacy overlay still requires calendar alignment, so an
        // anniversary cycle must fall back to the local calendar-month report
        // rather than mix two different windows.
        var offset = Report.empty
        offset.fromStr = "2030-01-01"
        offset.toStr = "2030-01-20"
        offset.totalCredits = 80
        let unaligned = build(
            report: offset, periodKind: .thisMonth,
            snapshot: sample(resetISO: "2030-01-25T00:00:00Z"), now: midCycle
        )
        precondition(!unaligned.isCurrentCycle && unaligned.totalCredits == 80,
                     "an anniversary cycle must not overlay the calendar-month report")
        // A same-day-aligned cycle with a time-of-day reset still overlays: the
        // day keys match the local range, and the dashboard needs it to work.
        let alignedWithTime = build(
            report: offset, periodKind: .thisMonth,
            snapshot: sample(resetISO: "2030-02-01T08:00:00Z"), now: midCycle
        )
        precondition(alignedWithTime.isCurrentCycle,
                     "a time-of-day reset on an aligned day must still overlay")
        verifyAccountRetention()
        print("credit reconciliation verification passed")
    }

    /// Reconnecting, or changing how the account fingerprint is derived, must
    /// never cost the user their stored history. This is a real regression:
    /// switching the fingerprint to a key-derived form made the same account
    /// look like a different one, and the reconnect path responded by hiding the
    /// entire cycle behind a freshly advanced baseline pointer.
    private static func verifyAccountRetention() {
        let reset = Aggregator.utcMidnightMs("2030-04-01")
        let base = Aggregator.utcMidnightMs("2030-03-10")
        let old = "fingerprint-before-derivation-change"
        let new = "fingerprint-after-derivation-change"
        let other = "a-genuinely-different-account"

        CreditSampleStore.withTemporaryStore {
            // History captured before rows carried an account.
            for i in 0..<3 {
                precondition(
                    CreditSampleStore.save(
                        CreditSample(capturedAtMs: base + Int64(i) * 60_000, serverAtMs: nil,
                                     resetAtMs: reset, creditsUsed: Double(10 * (i + 1))),
                        account: nil),
                    "unattributed sample must save")
            }
            precondition(CreditSampleStore.load(resetAtMs: reset, account: old).count == 3,
                         "pre-attribution rows must be visible to the connected account")

            // Reconnecting under a *different-looking* fingerprint for the same
            // account must adopt, not discard.
            let adopted = CreditSampleStore.adoptUnattributed(account: new)
            precondition(adopted == 3, "adoption must claim every unattributed row")
            precondition(CreditSampleStore.load(resetAtMs: reset, account: new).count == 3,
                         "history must survive a fingerprint derivation change")

            // Adoption is one-shot: a second account cannot inherit the first's.
            precondition(CreditSampleStore.adoptUnattributed(account: other) == 0,
                         "adoption must not run twice")
            precondition(CreditSampleStore.load(resetAtMs: reset, account: other).isEmpty,
                         "a different account must not see another account's history")

            // New rows stay attributed and isolated.
            CreditSampleStore.save(
                CreditSample(capturedAtMs: base + 600_000, serverAtMs: nil,
                             resetAtMs: reset, creditsUsed: 90),
                account: other)
            precondition(CreditSampleStore.load(resetAtMs: reset, account: new).count == 3,
                         "another account's writes must not appear in this account's cycle")
            precondition(CreditSampleStore.load(resetAtMs: reset, account: other).count == 1,
                         "an account must see its own writes")
        }
    }
}
