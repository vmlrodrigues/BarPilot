import Foundation

struct ObservedDayCredits: Identifiable {
    let id: String
    let day: String
    let credits: Double

    var date: Date {
        Date(timeIntervalSince1970: Double(Aggregator.utcMidnightMs(day)) / 1000)
    }
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
                guard current.resetAtMs == previous.resetAtMs else {
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
    }
}
