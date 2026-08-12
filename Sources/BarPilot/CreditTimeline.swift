import Foundation

struct HourlyCreditPoint: Identifiable {
    let id: Int64
    let atMs: Int64
    let credits: Double
}

struct ObservedDayCredits: Identifiable {
    let id: String
    let day: String
    let credits: Double
}

struct CreditTimeline {
    let hourly: [HourlyCreditPoint]
    let daily: [ObservedDayCredits]
    let openingCredits: Double
    let observedCredits: Double
    let unallocatedCredits: Double
    let firstAtMs: Int64?
    let lastAtMs: Int64?

    static let empty = CreditTimeline(
        hourly: [], daily: [], openingCredits: 0, observedCredits: 0,
        unallocatedCredits: 0, firstAtMs: nil, lastAtMs: nil
    )

    /// Build an observed timeline from a cumulative counter. Deltas spanning more
    /// than 90 minutes are kept unallocated because sleep/offline gaps cannot be
    /// assigned honestly to an hour or day.
    static func build(samples: [CreditSample]) -> CreditTimeline {
        let ordered = samples.sorted { $0.capturedAtMs < $1.capturedAtMs }
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
                let elapsed = current.capturedAtMs - previous.capturedAtMs
                guard current.resetAtMs == previous.resetAtMs else {
                    highWater = current.creditsUsed
                    continue
                }
                guard elapsed > 0, elapsed <= maxObservedGapMs else {
                    highWater = max(highWater, current.creditsUsed)
                    continue
                }
                guard current.creditsUsed > highWater else { continue }
                let delta = current.creditsUsed - highWater
                guard delta > 0 else { continue }
                highWater = current.creditsUsed
                let day = utcDay(current.serverAtMs ?? current.capturedAtMs, calendar: calendar)
                byDay[day, default: 0] += delta
                observed += delta
            }
        }

        var latestByHour: [Int64: CreditSample] = [:]
        for sample in ordered {
            let timestamp = sample.serverAtMs ?? sample.capturedAtMs
            let date = Date(timeIntervalSince1970: Double(timestamp) / 1000)
            let components = calendar.dateComponents([.year, .month, .day, .hour], from: date)
            guard let hour = calendar.date(from: components) else { continue }
            latestByHour[Int64(hour.timeIntervalSince1970 * 1000)] = sample
        }
        var hourly = latestByHour.map { hourMs, sample in
            let timestamp = sample.serverAtMs ?? sample.capturedAtMs
            return HourlyCreditPoint(id: timestamp, atMs: timestamp, credits: sample.creditsUsed)
        }
        .sorted { $0.atMs < $1.atMs }

        // Preserve the exact opening baseline even when later usage occurred in
        // that same hour; it is the only known starting point for the chart.
        if !hourly.contains(where: { $0.atMs == (first.serverAtMs ?? first.capturedAtMs) }) {
            let timestamp = first.serverAtMs ?? first.capturedAtMs
            hourly.insert(HourlyCreditPoint(
                id: timestamp, atMs: timestamp,
                credits: first.creditsUsed
            ), at: 0)
        }
        hourly.sort { $0.atMs < $1.atMs }

        let totalIncrease = max(0, last.creditsUsed - first.creditsUsed)
        if observed > totalIncrease {
            // A late downward correction invalidates attribution already assigned
            // to days. Preserve the cumulative chart, but keep all growth
            // unallocated rather than trimming an arbitrary day.
            byDay = [:]
            observed = 0
        }
        let daily = byDay.map {
            ObservedDayCredits(id: $0.key, day: $0.key, credits: $0.value)
        }
        .sorted { $0.day > $1.day }

        return CreditTimeline(
            hourly: hourly,
            daily: daily,
            openingCredits: first.creditsUsed,
            observedCredits: observed,
            unallocatedCredits: max(0, totalIncrease - observed),
            firstAtMs: first.capturedAtMs,
            lastAtMs: last.capturedAtMs
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
        precondition(timeline.observedCredits == 40)
        precondition(timeline.unallocatedCredits == 60)
        precondition(timeline.daily.first?.credits == 40)
        precondition(timeline.hourly.last?.credits == 200)
        precondition(zip(timeline.hourly, timeline.hourly.dropFirst()).allSatisfy { $0.atMs < $1.atMs })

        let corrected = build(samples: [
            CreditSample(capturedAtMs: start, serverAtMs: nil, resetAtMs: reset, creditsUsed: 100),
            CreditSample(capturedAtMs: start + hour, serverAtMs: nil, resetAtMs: reset, creditsUsed: 150),
            CreditSample(capturedAtMs: start + 2 * hour, serverAtMs: nil, resetAtMs: reset, creditsUsed: 120),
            CreditSample(capturedAtMs: start + 3 * hour, serverAtMs: nil, resetAtMs: reset, creditsUsed: 160)
        ])
        precondition(corrected.observedCredits == 60)
        precondition(corrected.unallocatedCredits == 0)
    }
}
