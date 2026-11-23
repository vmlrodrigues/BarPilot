import Foundation

enum CreditCycle {
    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static func utcMidnightMs(_ day: String) -> Int64 {
        let parts = day.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let date = Int(parts[2]),
              let value = utcCalendar.date(from: DateComponents(
                year: year, month: month, day: date
              )) else { return 0 }
        return Int64(value.timeIntervalSince1970 * 1_000)
    }

    static func utcDayStr(_ ms: Int64) -> String {
        CreditCycleSummary.utcDayString(
            for: Date(timeIntervalSince1970: Double(ms) / 1_000)
        )
    }

    /// Never present a missing, expired or failed poll as a real zero or as a
    /// current cached amount. History stays persisted for navigation and sync.
    static func visibleCurrentCredits(
        sample: CreditSample?, connected: Bool, pollFailed: Bool,
        hasSuccessfulPoll: Bool,
        now: Date = Date()
    ) -> Double? {
        guard connected, !pollFailed, hasSuccessfulPoll, let sample,
              isCurrentCycle(sample, now: now) else { return nil }
        let age = now.timeIntervalSince(
            Date(timeIntervalSince1970: Double(sample.observedAtMs) / 1_000)
        )
        guard age >= 0, age <= 5 * 60 else { return nil }
        return sample.creditsUsed
    }

    /// The cycle a sample belongs to is `[resetAt - 1 month, resetAt)`. Copilot
    /// resets are not always UTC midnight on the 1st — the account response
    /// carries the reset in four different fields, two of which encode a
    /// time-of-day, and anniversary-billed accounts never land on the 1st. So
    /// this is deliberately interval containment, not calendar-month equality:
    /// requiring alignment silently disabled the whole server dashboard for
    /// those accounts.
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

    static func verify() {
        CreditTimeline.verify()
        CreditCycleNavigation.verify()
        CreditCycleTransitionPolicy.verify()
        CreditSampleStore.verifyTelemetryRetirement()
        let reset = CreditCycle.utcMidnightMs("2030-02-01")
        let t0 = CreditCycle.utcMidnightMs("2030-01-10")
        let t1 = t0 + 60_000
        let t2 = t1 + 60_000
        let now = Date(timeIntervalSince1970: Double(t2) / 1_000)
        let zero = CreditSample(
            capturedAtMs: t2, serverAtMs: nil, resetAtMs: reset, creditsUsed: 0
        )
        precondition(visibleCurrentCredits(
            sample: zero, connected: true, pollFailed: false,
            hasSuccessfulPoll: true, now: now
        ) == 0, "a successful zero counter must remain visible")
        precondition(visibleCurrentCredits(
            sample: zero, connected: true, pollFailed: true,
            hasSuccessfulPoll: true, now: now
        ) == nil, "a failed poll must hide even a previously valid counter")
        precondition(visibleCurrentCredits(
            sample: zero, connected: false, pollFailed: false,
            hasSuccessfulPoll: true, now: now
        ) == nil, "disconnecting must hide current usage")
        precondition(visibleCurrentCredits(
            sample: nil, connected: true, pollFailed: false,
            hasSuccessfulPoll: true, now: now
        ) == nil, "a missing counter must not become zero")
        precondition(visibleCurrentCredits(
            sample: zero, connected: true, pollFailed: false,
            hasSuccessfulPoll: true,
            now: now.addingTimeInterval(301)
        ) == nil, "an old cached counter must not look current")
        precondition(visibleCurrentCredits(
            sample: zero, connected: true, pollFailed: false,
            hasSuccessfulPoll: false, now: now
        ) == nil, "a recent database sample must not appear current before this process polls")
        precondition(visibleCurrentCredits(
            sample: zero, connected: true, pollFailed: false,
            hasSuccessfulPoll: true,
            now: zero.resetAt
        ) == nil, "the prior cycle must not remain current after rollover")
        let available = CreditSample(
            capturedAtMs: t2, serverAtMs: nil, resetAtMs: reset, creditsUsed: 123
        )
        precondition(visibleCurrentCredits(
            sample: available, connected: true, pollFailed: false,
            hasSuccessfulPoll: true, now: now
        ) == 123, "a recovered poll must show the exact GitHub amount")
        let serverTimestampIsOld = CreditSample(
            capturedAtMs: t2, serverAtMs: t2 - 6 * 60_000,
            resetAtMs: reset, creditsUsed: 123
        )
        precondition(visibleCurrentCredits(
            sample: serverTimestampIsOld, connected: true, pollFailed: false,
            hasSuccessfulPoll: true, now: now
        ) == nil, "a recent fetch must not make an older GitHub observation current")
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
        precondition(alternate.creditsUsed == 100.5 && alternate.resetAtMs == reset
                        && alternate.serverAtMs == nil,
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
        func rejectsTimestamp(_ timestamp: String) -> Bool {
            let invalid = skewedServerFixture.replacingOccurrences(
                of: "2099-01-01T00:00:00Z", with: timestamp
            )
            do {
                _ = try CreditUsageAPI.parse(data: Data(invalid.utf8), capturedAt: now)
                return false
            } catch CreditUsageError.invalidResponse {
                return true
            } catch {
                return false
            }
        }
        precondition(rejectsTimestamp("2099-01-01T00:00:00Z"),
                     "an implausible future GitHub timestamp must fail parsing")
        precondition(rejectsTimestamp("2030-01-08T23:59:00Z"),
                     "an explicit observation more than 24 hours old must not become fresh")
        precondition(rejectsTimestamp("not a timestamp"),
                     "a malformed GitHub timestamp must not become fresh")

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

        verifyAccountRetention()
        print("credit counter verification passed")
    }

    /// Reconnecting, or changing how the account fingerprint is derived, must
    /// never cost the user their stored history. This is a real regression:
    /// switching the fingerprint to a key-derived form made the same account
    /// look like a different one, and the reconnect path responded by hiding the
    /// entire cycle behind a freshly advanced baseline pointer.
    private static func verifyAccountRetention() {
        let reset = CreditCycle.utcMidnightMs("2030-04-01")
        let base = CreditCycle.utcMidnightMs("2030-03-10")
        let old = "fingerprint-before-derivation-change"
        let new = "fingerprint-after-derivation-change"
        let other = "a-genuinely-different-account"
        let oldCycle = CreditCycleSummary(latestSample: CreditSample(
            capturedAtMs: base, serverAtMs: nil,
            resetAtMs: reset + 8 * 60 * 60 * 1000, creditsUsed: 75
        ))
        let nextReset = CreditCycle.utcMidnightMs("2030-05-01") + 8 * 60 * 60 * 1000
        let newCycle = CreditCycleSummary(latestSample: CreditSample(
            capturedAtMs: reset + 9 * 60 * 60 * 1000, serverAtMs: nil,
            resetAtMs: nextReset, creditsUsed: 10
        ))
        let march31 = Date(
            timeIntervalSince1970:
                Double(CreditCycle.utcMidnightMs("2030-03-31")) / 1000
        )
        let april1 = Date(
            timeIntervalSince1970:
                Double(CreditCycle.utcMidnightMs("2030-04-01")) / 1000
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

            let priorReset = CreditCycle.utcMidnightMs("2030-03-01")
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

            let peerOnlyResetDay = CreditCycle.utcMidnightMs("2031-01-01")
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
            let recoveryReset = CreditCycle.utcMidnightMs("2031-02-01")
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
