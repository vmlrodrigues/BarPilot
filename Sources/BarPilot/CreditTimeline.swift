import Foundation

struct ObservedDayCredits: Identifiable {
    let id: String
    let day: String
    let credits: Double

    var date: Date {
        Date(timeIntervalSince1970: Double(Aggregator.utcMidnightMs(day)) / 1000)
    }
}

/// One stable chart slot for every UTC day touched by a billing cycle. Observed
/// spend is sparse, but the chart is not: keeping future and no-observation days
/// in the series prevents the graph changing width as the month progresses.
struct BillingCycleDayCredits: Identifiable {
    let id: String
    let day: String
    let date: Date
    let credits: Double
    let hasObservedIncrease: Bool
    let isFuture: Bool
    let isCurrentDay: Bool
}

struct CreditTimeline {
    let daily: [ObservedDayCredits]
    let openingCredits: Double
    let observedCredits: Double
    let unallocatedCredits: Double
    let firstAtMs: Int64?
    let lastAtMs: Int64?

    static let empty = CreditTimeline(
        daily: [], openingCredits: 0, observedCredits: 0,
        unallocatedCredits: 0, firstAtMs: nil, lastAtMs: nil
    )

    /// Build an observed timeline from a cumulative counter. A long gap can still
    /// be assigned when both observations fall within the same UTC day; gaps that
    /// cross a day boundary remain unallocated because their split is unknowable.
    static func build(samples: [CreditSample]) -> CreditTimeline {
        let ordered = samples.sorted {
            let lhs = $0.serverAtMs ?? $0.capturedAtMs
            let rhs = $1.serverAtMs ?? $1.capturedAtMs
            return lhs == rhs ? $0.capturedAtMs < $1.capturedAtMs : lhs < rhs
        }
        guard let first = ordered.first, let last = ordered.last else { return .empty }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let maxObservedGapMs: Int64 = 90 * 60 * 1000
        var byDay: [String: Double] = [:]
        var observed = 0.0
        var highWater = first.creditsUsed

        if ordered.count > 1 {
            for index in 1..<ordered.count {
                let previous = ordered[index - 1]
                let current = ordered[index]
                guard CreditCycleSummary.dayStart(for: current.resetAtMs)
                        == CreditCycleSummary.dayStart(for: previous.resetAtMs) else {
                    highWater = current.creditsUsed
                    continue
                }
                let previousAt = previous.serverAtMs ?? previous.capturedAtMs
                let currentAt = current.serverAtMs ?? current.capturedAtMs
                let elapsed = currentAt - previousAt
                guard elapsed > 0 else { continue }
                let sameUTCDay = utcDay(previousAt, calendar: calendar)
                    == utcDay(currentAt, calendar: calendar)
                guard elapsed <= maxObservedGapMs || sameUTCDay else {
                    highWater = max(highWater, current.creditsUsed)
                    continue
                }
                guard current.creditsUsed > highWater else { continue }
                let delta = current.creditsUsed - highWater
                guard delta > 0 else { continue }
                highWater = current.creditsUsed
                let day = utcDay(currentAt, calendar: calendar)
                byDay[day, default: 0] += delta
                observed += delta
            }
        }

        // `observed` accumulates against a monotonic high-water mark, so compare
        // it against the peak rather than the last sample. Using the last sample
        // meant any downward correction (refund, adjustment, stale cached value,
        // rollover lag) made observed > totalIncrease and discarded the whole
        // cycle's per-day attribution — including days the correction cannot
        // affect. Against the peak the invariant holds by construction and the
        // residual lands in unallocatedCredits as intended.
        let peak = ordered.map(\.creditsUsed).max() ?? first.creditsUsed
        let totalIncrease = max(0, peak - first.creditsUsed)
        let daily = byDay.map {
            ObservedDayCredits(id: $0.key, day: $0.key, credits: $0.value)
        }
        .sorted { $0.day > $1.day }

        return CreditTimeline(
            daily: daily,
            openingCredits: first.creditsUsed,
            observedCredits: observed,
            unallocatedCredits: max(0, totalIncrease - observed),
            firstAtMs: first.serverAtMs ?? first.capturedAtMs,
            lastAtMs: last.serverAtMs ?? last.capturedAtMs
        )
    }

    private static func utcDay(_ ms: Int64, calendar: Calendar) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func combinedDaily(
        samplesByCycle: [[CreditSample]], monthKey: String
    ) -> [String: Double] {
        var byDay: [String: Double] = [:]
        for samples in samplesByCycle {
            for row in build(samples: samples).daily
                where row.day.hasPrefix(monthKey) {
                byDay[row.day, default: 0] += row.credits
            }
        }
        return byDay
    }

    /// Merge independently reconciled cycles into one newest-first activity
    /// history. A UTC day can straddle a non-midnight reset, so both sides are
    /// summed instead of letting one cycle replace the other.
    static func mergedDailyRows(
        _ groups: [[ObservedDayCredits]]
    ) -> [ObservedDayCredits] {
        var byDay: [String: Double] = [:]
        for group in groups {
            for row in group {
                byDay[row.day, default: 0] += row.credits
            }
        }
        return byDay.map {
            ObservedDayCredits(id: $0.key, day: $0.key, credits: $0.value)
        }.sorted { $0.day > $1.day }
    }

    static func combinedDailyRows(
        samplesByCycle: [[CreditSample]]
    ) -> [ObservedDayCredits] {
        mergedDailyRows(samplesByCycle.map { build(samples: $0).daily })
    }

    /// Expand sparse observed-day totals into the complete selected billing
    /// cycle. The reset instant is exclusive: a midnight reset belongs to the
    /// next cycle, while a non-midnight reset legitimately leaves a partial
    /// final UTC day in this one.
    static func billingCycleDays(
        daily: [ObservedDayCredits],
        startAt: Date,
        resetAt: Date,
        now: Date = Date()
    ) -> [BillingCycleDayCredits] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard resetAt > startAt else { return [] }

        let firstDay = calendar.startOfDay(for: startAt)
        let finalInstant = resetAt.addingTimeInterval(-0.001)
        let lastDay = calendar.startOfDay(for: finalInstant)
        let today = calendar.startOfDay(for: now)
        let byDay = Dictionary(uniqueKeysWithValues: daily.map { ($0.day, $0.credits) })
        let observedDays = Set(daily.map(\.day))
        let cycleContainsNow = now >= startAt && now < resetAt

        var result: [BillingCycleDayCredits] = []
        var date = firstDay
        while date <= lastDay && result.count < 35 {
            let day = CreditCycleSummary.utcDayString(for: date)
            result.append(BillingCycleDayCredits(
                id: day,
                day: day,
                date: date,
                credits: byDay[day] ?? 0,
                hasObservedIncrease: observedDays.contains(day),
                isFuture: cycleContainsNow && date > today,
                isCurrentDay: cycleContainsNow && date == today
            ))
            guard let next = calendar.date(byAdding: .day, value: 1, to: date)
            else { break }
            date = next
        }
        return result
    }

    static func verify() {
        let hour: Int64 = 60 * 60 * 1000
        let reset = Aggregator.utcMidnightMs("2030-02-01")
        let start = Aggregator.utcMidnightMs("2030-01-10")
        let samples = [
            CreditSample(capturedAtMs: start, serverAtMs: nil, resetAtMs: reset, creditsUsed: 100),
            CreditSample(capturedAtMs: start + hour, serverAtMs: nil, resetAtMs: reset, creditsUsed: 125),
            CreditSample(capturedAtMs: start + 2 * hour, serverAtMs: nil, resetAtMs: reset, creditsUsed: 140),
            CreditSample(capturedAtMs: start + 5 * hour, serverAtMs: nil, resetAtMs: reset, creditsUsed: 200)
        ]
        let timeline = build(samples: samples)
        precondition(timeline.openingCredits == 100)
        precondition(timeline.observedCredits == 100)
        precondition(timeline.unallocatedCredits == 0)
        precondition(timeline.daily.first?.credits == 100)

        let crossDayStart = Aggregator.utcMidnightMs("2030-01-10") + 23 * hour
        let crossDay = build(samples: [
            CreditSample(capturedAtMs: crossDayStart, serverAtMs: nil, resetAtMs: reset, creditsUsed: 100),
            CreditSample(capturedAtMs: crossDayStart + 3 * hour, serverAtMs: nil, resetAtMs: reset, creditsUsed: 160)
        ])
        precondition(crossDay.observedCredits == 0)
        precondition(crossDay.unallocatedCredits == 60)

        let corrected = build(samples: [
            CreditSample(capturedAtMs: start, serverAtMs: nil, resetAtMs: reset, creditsUsed: 100),
            CreditSample(capturedAtMs: start + hour, serverAtMs: nil, resetAtMs: reset, creditsUsed: 150),
            CreditSample(capturedAtMs: start + 2 * hour, serverAtMs: nil, resetAtMs: reset, creditsUsed: 120),
            CreditSample(capturedAtMs: start + 3 * hour, serverAtMs: nil, resetAtMs: reset, creditsUsed: 160)
        ])
        precondition(corrected.observedCredits == 60)
        precondition(corrected.unallocatedCredits == 0)

        // A final sample BELOW the running peak must not discard days already
        // attributed. The first two hours are provably spent regardless of a
        // later downward correction.
        let lateDrop = build(samples: [
            CreditSample(capturedAtMs: start, serverAtMs: nil, resetAtMs: reset, creditsUsed: 100),
            CreditSample(capturedAtMs: start + hour, serverAtMs: nil, resetAtMs: reset, creditsUsed: 150),
            CreditSample(capturedAtMs: start + 2 * hour, serverAtMs: nil, resetAtMs: reset, creditsUsed: 190),
            CreditSample(capturedAtMs: start + 3 * hour, serverAtMs: nil, resetAtMs: reset, creditsUsed: 120)
        ])
        precondition(lateDrop.observedCredits == 90,
                     "a late downward correction must not wipe attributed days")
        precondition(lateDrop.daily.first?.credits == 90)
        precondition(lateDrop.unallocatedCredits == 0)

        let resetTimeVariant = build(samples: [
            CreditSample(capturedAtMs: start, serverAtMs: nil,
                         resetAtMs: reset, creditsUsed: 100),
            CreditSample(capturedAtMs: start + hour, serverAtMs: nil,
                         resetAtMs: reset + 8 * hour, creditsUsed: 120)
        ])
        precondition(resetTimeVariant.observedCredits == 20
                     && resetTimeVariant.daily.first?.credits == 20
                     && resetTimeVariant.unallocatedCredits == 0,
                     "same-day reset variants must retain assignable deltas")

        let splitResetDay = combinedDaily(
            samplesByCycle: [
                [
                    CreditSample(capturedAtMs: start + 24 * hour + 6 * hour,
                                 serverAtMs: nil,
                                 resetAtMs: reset + 8 * hour, creditsUsed: 100),
                    CreditSample(capturedAtMs: start + 24 * hour + 7 * hour,
                                 serverAtMs: nil, resetAtMs: reset + 8 * hour,
                                 creditsUsed: 110)
                ],
                [
                    CreditSample(capturedAtMs: start + 24 * hour + 9 * hour,
                                 serverAtMs: nil, resetAtMs: reset + 28 * 24 * hour + 8 * hour,
                                 creditsUsed: 0),
                    CreditSample(capturedAtMs: start + 24 * hour + 10 * hour,
                                 serverAtMs: nil, resetAtMs: reset + 28 * 24 * hour + 8 * hour,
                                 creditsUsed: 20)
                ]
            ],
            monthKey: "2030-01"
        )
        precondition(splitResetDay["2030-01-11"] == 30,
                     "calendar spend must sum both sides of a reset-day boundary")

        let chartStart = Date(timeIntervalSince1970: Double(
            Aggregator.utcMidnightMs("2030-09-01")) / 1000)
        let chartReset = Date(timeIntervalSince1970: Double(
            Aggregator.utcMidnightMs("2030-10-01")) / 1000)
        let chartNow = Date(timeIntervalSince1970: Double(
            Aggregator.utcMidnightMs("2030-09-02") + 12 * hour) / 1000)
        let chartDays = billingCycleDays(
            daily: [ObservedDayCredits(
                id: "2030-09-01", day: "2030-09-01", credits: 42
            )],
            startAt: chartStart,
            resetAt: chartReset,
            now: chartNow
        )
        precondition(chartDays.count == 30,
                     "September must keep all 30 daily chart slots from day one")
        precondition(chartDays.first?.credits == 42
                     && chartDays.first?.hasObservedIncrease == true)
        precondition(chartDays[1].isCurrentDay && !chartDays[1].isFuture)
        precondition(chartDays[2].isFuture && chartDays.last?.isFuture == true)

        let middayReset = chartReset.addingTimeInterval(Double(12 * hour) / 1000)
        let partialResetDay = billingCycleDays(
            daily: [], startAt: chartStart, resetAt: middayReset, now: chartNow
        )
        precondition(partialResetDay.count == 31,
                     "a non-midnight reset must retain its partial final UTC day")

        let combinedRows = mergedDailyRows([
            [ObservedDayCredits(id: "2030-09-01", day: "2030-09-01", credits: 10)],
            [
                ObservedDayCredits(id: "2030-09-01", day: "2030-09-01", credits: 5),
                ObservedDayCredits(id: "2030-08-31", day: "2030-08-31", credits: 20)
            ]
        ])
        precondition(combinedRows.map(\.day) == ["2030-09-01", "2030-08-31"]
                     && combinedRows.first?.credits == 15,
                     "rolling history must retain and combine activity across cycles")
    }
}
