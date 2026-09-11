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
    static func matchesCurrentCycle(snapshot: CreditSample, report: Report, now: Date) -> Bool {
        guard isCurrentCycle(snapshot, now: now),
              let start = cycleStart(for: snapshot) else { return false }
        let startMs = Int64(start.timeIntervalSince1970 * 1_000)
        // A local calendar-month report starts at UTC midnight. A 10am reset on
        // the first still leaves ten hours from the previous cycle in that
        // report, so matching only the day key is not sufficient.
        guard startMs == Aggregator.utcMidnightMs(report.fromStr) else {
            return false
        }
        return Aggregator.utcDayStr(startMs) == report.fromStr
            && Aggregator.utcDayStr(Int64(now.timeIntervalSince1970 * 1000)) == report.toStr
    }

    static func verify() {
        CreditTimeline.verify()
        CreditCycleTransitionPolicy.verify()
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
        func rejectsReset(_ value: String) -> Bool {
            let invalid = """
            {
              "quota_reset_date": "\(value)",
              "quota_snapshots": {
                "premium_interactions": { "credits_used": 1 }
              }
            }
            """
            do {
                _ = try CreditUsageAPI.parse(
                    data: Data(invalid.utf8),
                    capturedAt: Date(
                        timeIntervalSince1970: Double(t2) / 1_000
                    )
                )
                return false
            } catch CreditUsageError.invalidResponse {
                return true
            } catch {
                return false
            }
        }
        precondition(rejectsReset("inf"),
                     "non-finite reset epochs must be rejected without trapping")
        precondition(rejectsReset("1e309"),
                     "out-of-range reset epochs must be rejected without trapping")
        precondition(rejectsReset("2030-02-30"),
                     "nonexistent calendar reset dates must be rejected")
        precondition(rejectsReset("2029-12-01"),
                     "an expired reset boundary must be rejected")
        precondition(rejectsReset("2099-01-01"),
                     "a reset outside the current billing window must be rejected")
        let skewedServerFixture = """
        {
          "quota_reset_date": "2030-02-01",
          "quota_snapshots": {
            "premium_interactions": {
              "credits_used": 1,
              "timestamp_utc": "2099-01-01T00:00:00Z"
            }
          }
        }
        """
        let skewedServer = try! CreditUsageAPI.parse(
            data: Data(skewedServerFixture.utf8),
            capturedAt: Date(timeIntervalSince1970: Double(t2) / 1_000)
        )
        precondition(skewedServer.serverAtMs == nil,
                     "an implausible optional server clock must be ignored")

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
        // A same-day but non-midnight start still contains hours from the prior
        // cycle in the local report, so the authoritative counter must stand
        // alone rather than being maxed against that mixed window.
        let alignedWithTime = build(
            report: offset, periodKind: .thisMonth,
            snapshot: sample(resetISO: "2030-02-01T08:00:00Z"), now: midCycle
        )
        precondition(!alignedWithTime.isCurrentCycle
                     && alignedWithTime.totalCredits == offset.totalCredits,
                     "a non-midnight cycle must not overlay a calendar-day report")
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
        let oldCycle = CreditCycleSummary(latestSample: CreditSample(
            capturedAtMs: base, serverAtMs: nil,
            resetAtMs: reset + 8 * 60 * 60 * 1000, creditsUsed: 75
        ))
        let nextReset = Aggregator.utcMidnightMs("2030-05-01") + 8 * 60 * 60 * 1000
        let newCycle = CreditCycleSummary(latestSample: CreditSample(
            capturedAtMs: reset + 9 * 60 * 60 * 1000, serverAtMs: nil,
            resetAtMs: nextReset, creditsUsed: 10
        ))
        let march31 = Date(
            timeIntervalSince1970:
                Double(Aggregator.utcMidnightMs("2030-03-31")) / 1000
        )
        let april1 = Date(
            timeIntervalSince1970:
                Double(Aggregator.utcMidnightMs("2030-04-01")) / 1000
        )
        precondition(
            CreditCycleSummary.cycle(
                containingUTCDate: march31, in: [newCycle, oldCycle]
            ) == oldCycle,
            "a calendar day before reset must select the completing cycle")
        precondition(
            CreditCycleSummary.cycle(
                containingUTCDate: april1, in: [newCycle, oldCycle]
            ) == newCycle,
            "a split reset day must select the cycle owning most of that UTC day")
        precondition(
            CreditCycleSummary.liveCycleDay(
                currentSample: nil, cycles: [newCycle, oldCycle]
            ) == newCycle.resetDayMs,
            "the newest stored cycle must remain live while the current sample is unavailable")
        precondition(
            CreditCycleSummary.liveCycleDay(
                currentSample: oldCycle.latestSample,
                cycles: [newCycle, oldCycle]
            ) == oldCycle.resetDayMs,
            "a valid current sample must remain authoritative for live-cycle identity")

        CreditSampleStore.withTemporaryStore {
            let storeIdentity = CreditSampleStore.storeIdentity()
            precondition(
                storeIdentity != nil
                    && CreditSampleStore.storeIdentity() == storeIdentity,
                "the credit database identity must remain stable across opens"
            )
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
            precondition(CreditSampleStore.latest(account: nil)?.creditsUsed == 30,
                         "nil-account latest must read only unattributed rows")
            precondition(
                CreditSampleStore.cycleBudget(
                    resetDayMs: CreditCycleSummary.dayStart(for: reset),
                    account: old
                ) == nil,
                "pre-migration history must not invent a budget snapshot")
            precondition(
                !CreditSampleStore.setCycleBudget(
                    resetDayMs: CreditCycleSummary.dayStart(for: reset),
                    account: old, budgetUSD: 0.001,
                    updatedAtMs: base
                ),
                "storage must reject a target below the supported minimum"
            )

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
            let otherSample = CreditSample(
                capturedAtMs: base + 600_000, serverAtMs: nil,
                resetAtMs: reset, creditsUsed: 90
            )
            CreditSampleStore.save(otherSample, account: other, budgetUSD: 222)
            precondition(CreditSampleStore.load(resetAtMs: reset, account: new).count == 3,
                         "another account's writes must not appear in this account's cycle")
            precondition(CreditSampleStore.load(resetAtMs: reset, account: other).count == 1,
                         "an account must see its own writes")
            precondition(CreditSampleStore.load(resetAtMs: reset, account: nil).isEmpty,
                         "nil-account loads must not expose attributed rows")
            precondition(CreditSampleStore.cycles(account: nil).isEmpty,
                         "nil-account cycle lists must not expose attributed rows")
            precondition(
                CreditSampleStore.cycleBudget(
                    resetDayMs: CreditCycleSummary.dayStart(for: reset),
                    account: other
                ) == 222,
                "a budget snapshot must remain isolated to its account")
            CreditSampleStore.save(otherSample, account: other)
            precondition(
                CreditSampleStore.cycleBudget(
                    resetDayMs: CreditCycleSummary.dayStart(for: reset),
                    account: other
                ) == 222,
                "rewriting a sample without a budget must preserve its snapshot")

            let priorReset = Aggregator.utcMidnightMs("2030-03-01")
            CreditSampleStore.save(
                CreditSample(capturedAtMs: base - 2_000_000, serverAtMs: nil,
                             resetAtMs: priorReset, creditsUsed: 40),
                account: new)
            CreditSampleStore.save(
                CreditSample(capturedAtMs: base - 1_500_000, serverAtMs: nil,
                             resetAtMs: priorReset, creditsUsed: 90),
                account: new)
            CreditSampleStore.save(
                CreditSample(capturedAtMs: base - 1_000_000, serverAtMs: nil,
                             resetAtMs: priorReset, creditsUsed: 75),
                account: new)
            let boundary = base - CreditCycleSummary.dayMs
            let boundarySamples = [
                CreditSample(
                    capturedAtMs: boundary + 60_000,
                    serverAtMs: boundary - 60_000,
                    resetAtMs: priorReset, creditsUsed: 10
                ),
                CreditSample(
                    capturedAtMs: boundary + 120_000,
                    serverAtMs: boundary - 30_000,
                    resetAtMs: priorReset, creditsUsed: 20
                ),
                CreditSample(
                    capturedAtMs: boundary + 43_200_000,
                    serverAtMs: boundary + 43_200_000,
                    resetAtMs: priorReset, creditsUsed: 30
                )
            ]
            for sample in boundarySamples {
                CreditSampleStore.save(sample, account: new)
            }
            let cycles = CreditSampleStore.cycles(account: new)
            precondition(cycles.map(\.resetAtMs) == [reset, priorReset],
                         "stored billing cycles must be newest first")
            precondition(cycles.last?.latestSample.creditsUsed == 75,
                         "a completed cycle must expose its final saved counter")
            precondition(!cycles.contains { $0.latestSample.creditsUsed == 90 },
                         "cycle navigation must not expose another account")

            let shiftedReset = reset + 8 * 60 * 60 * 1000
            CreditSampleStore.save(
                CreditSample(capturedAtMs: base + 700_000, serverAtMs: nil,
                             resetAtMs: shiftedReset, creditsUsed: 95),
                account: new, budgetUSD: 140)
            let coalesced = CreditSampleStore.cycles(account: new)
            precondition(coalesced.count == 2
                         && coalesced.first?.latestSample.creditsUsed == 95,
                         "same-day reset variants must remain one billing cycle")
            let compactedHistory = CreditSampleStore.compactedHistory(account: new)!
            precondition(
                compactedHistory.cycles.count == 2
                    && compactedHistory.cycles.first?.latestSample.creditsUsed == 95
                    && compactedHistory.cycles.last?.latestSample.creditsUsed == 75,
                "one-pass history loading must preserve every cycle's final counter"
            )
            precondition(
                compactedHistory.samplesByCycle[
                    CreditCycleSummary.dayStart(for: reset)
                ]?.map(\.creditsUsed) == [10, 95],
                "history loading must compact dense polls while retaining the cycle close"
            )
            let compactedPrior = compactedHistory.samplesByCycle[
                CreditCycleSummary.dayStart(for: priorReset)
            ] ?? []
            precondition(
                compactedPrior.contains { $0.creditsUsed == 90 },
                "completed history must retain a same-day high-water observation"
            )
            precondition(
                compactedPrior.contains(boundarySamples[1]),
                "server time must own SQL compaction across a UTC-day boundary"
            )
            precondition(
                !compactedHistory.samples.contains(otherSample),
                "compacted history must remain isolated to the selected account"
            )
            precondition(
                CreditSampleStore.loadCycle(
                    resetDayMs: CreditCycleSummary.dayStart(for: reset),
                    account: new
                ).count == 4,
                "a coalesced cycle must load every same-day reset variant")
            let resetDay = CreditCycleSummary.dayStart(for: reset)
            precondition(
                CreditSampleStore.cycleBudget(
                    resetDayMs: resetDay, account: new
                ) == 140,
                "the newest same-day reset variant must supply the cycle budget")
            precondition(
                CreditSampleStore.budgetMigrationCycle(
                    liveResetDayMs: resetDay,
                    cycles: coalesced,
                    account: new,
                    eligibleStartMonth: "2030-02"
                ) == CreditCycleSummary.dayStart(for: priorReset),
                "only the immediately preceding missing cycle may be repaired")
            let priorResetDay = CreditCycleSummary.dayStart(for: priorReset)
            precondition(
                CreditSampleStore.assignCycleBudgetIfMissing(
                    resetDayMs: priorResetDay, account: new, budgetUSD: 125,
                    updatedAtMs: base + 800_000
                ),
                "the missed pre-migration cycle must accept one assignment")
            precondition(
                CreditSampleStore.cycleBudget(
                    resetDayMs: priorResetDay, account: new
                ) == 125,
                "the one-time historical assignment must persist")
            precondition(
                !CreditSampleStore.assignCycleBudgetIfMissing(
                    resetDayMs: priorResetDay, account: new, budgetUSD: 999,
                    updatedAtMs: base + 900_000
                ),
                "the migration repair must never overwrite an assigned budget")
            CreditSampleStore.completeBudgetMigration(account: new)
            precondition(
                CreditSampleStore.budgetMigrationCycle(
                    liveResetDayMs: resetDay,
                    cycles: coalesced,
                    account: new,
                    eligibleStartMonth: "2030-02"
                ) == nil,
                "the one-time repair must disappear instead of moving backward")
            precondition(
                CreditSampleStore.setCycleBudget(
                    resetDayMs: resetDay, account: new, budgetUSD: 175,
                    updatedAtMs: base + 1_000_000
                ),
                "the active cycle budget must follow a current target change")
            precondition(
                CreditSampleStore.cycleBudget(
                    resetDayMs: resetDay, account: new
                ) == 175,
                "the active cycle target update must persist")
            let laterPoll = CreditSample(
                capturedAtMs: base + 1_200_000, serverAtMs: nil,
                resetAtMs: reset, creditsUsed: 100
            )
            precondition(CreditSampleStore.save(
                laterPoll, account: new, budgetUSD: 175,
                budgetUpdatedAtMs: base + 1_000_000
            ))
            precondition(
                CreditSampleStore.cycleBudgetSnapshot(
                    resetDayMs: resetDay, account: new
                )?.updatedAtMs == base + 1_000_000,
                "routine polling must not advance the budget edit timestamp"
            )
            precondition(
                CreditSampleStore.cycleBudget(
                    resetDayMs: resetDay, account: other
                ) == 222,
                "updating one account must not alter another account")

            let peerOnlyResetDay = Aggregator.utcMidnightMs("2031-01-01")
            precondition(
                CreditSampleStore.loadCycle(
                    resetDayMs: peerOnlyResetDay, account: new
                ).isEmpty,
                "the peer-only fixture must have no local counter rows"
            )
            precondition(
                CreditSampleStore.setCycleBudget(
                    resetDayMs: peerOnlyResetDay, account: new,
                    budgetUSD: 210, updatedAtMs: base + 1_300_000
                ),
                "a peer-only current cycle must accept a local budget edit"
            )
            precondition(
                CreditSampleStore.cycleBudgetSnapshot(
                    resetDayMs: peerOnlyResetDay, account: new
                ) == SyncedCycleBudget(
                    resetDayMs: peerOnlyResetDay, budgetUSD: 210,
                    updatedAtMs: base + 1_300_000
                ),
                "a budget must persist independently of local counter observations"
            )
            precondition(
                CreditSampleStore.compactedHistory(account: new)?
                    .cycleBudgets.contains(where: {
                        $0.resetDayMs == peerOnlyResetDay && $0.budgetUSD == 210
                    }) == true,
                "peer-only cycle budgets must be available to sync publication"
            )

            let recoveryAccount = "recovered-self-payload"
            let recoveryReset = Aggregator.utcMidnightMs("2031-02-01")
            let recoveredSamples = [
                CreditSample(
                    capturedAtMs: recoveryReset - 120_000,
                    serverAtMs: recoveryReset - 125_000,
                    resetAtMs: recoveryReset, creditsUsed: 40
                ),
                CreditSample(
                    capturedAtMs: recoveryReset - 60_000,
                    serverAtMs: recoveryReset - 65_000,
                    resetAtMs: recoveryReset, creditsUsed: 45
                )
            ]
            let recoveredBudget = SyncedCycleBudget(
                resetDayMs: CreditCycleSummary.dayStart(for: recoveryReset),
                budgetUSD: 180,
                updatedAtMs: recoveryReset - 60_000
            )
            precondition(
                CreditSampleStore.saveAll(
                    recoveredSamples, cycleBudgets: [recoveredBudget],
                    account: recoveryAccount
                ),
                "recovered self history must save atomically"
            )
            precondition(
                CreditSampleStore.load(
                    resetAtMs: recoveryReset, account: recoveryAccount
                ) == recoveredSamples,
                "recovered self history must reload intact"
            )
            precondition(
                CreditSampleStore.cycleBudget(
                    resetDayMs: recoveredBudget.resetDayMs,
                    account: recoveryAccount
                ) == recoveredBudget.budgetUSD,
                "recovered self history must restore its cycle budget"
            )
        }
    }
}
