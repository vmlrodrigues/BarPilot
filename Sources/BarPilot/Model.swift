import Foundation

// ---------------------------------------------------------------------------
// Spend projection (#18) — run-rate estimate of billing-cycle spend, shown on the
// budget bar. Pure and derived from the account counter and billing cycle.
// ---------------------------------------------------------------------------

struct SpendProjection {
    let projectedCredits: Double
    let budgetCredits: Double
    let daysElapsed: Int
    let daysInPeriod: Int
    let endLabel: String            // "Jul 31"
    /// True when the run rate is per *working* day rather than per calendar day,
    /// so `daysElapsed`/`daysInPeriod` count workdays.
    let excludesWeekends: Bool

    var hasBudget: Bool  { budgetCredits > 0 }
    var overBudget: Bool { hasBudget && projectedCredits > budgetCredits }
    var pctOfBudget: Double { hasBudget ? projectedCredits / budgetCredits * 100 : 0 }

    private static let utcEndFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d"
        f.timeZone = TimeZone(identifier: "UTC")!
        return f
    }()

    /// Working days in the `days` calendar days starting at `start`.
    ///
    /// Weekend-ness comes from the calendar rather than a hardcoded Sat/Sun, so
    /// a region with a Fri/Sat weekend gets its own working week.
    private static func workdays(from start: Date, days: Int, calendar: Calendar) -> Int {
        guard days > 0 else { return 0 }
        var count = 0
        for offset in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
            if !calendar.isDateInWeekend(day) { count += 1 }
        }
        return count
    }

    /// Project an account counter across its actual GitHub billing cycle. This
    /// deliberately does not assume that the cycle begins on day one or ends at
    /// the end of the current calendar month.
    static func computeBillingCycle(
        totalCredits: Double,
        monthlyBudgetUSD: Double,
        startAt: Date,
        resetAt: Date,
        now: Date,
        calendar: Calendar,
        excludeWeekends: Bool = false
    ) -> SpendProjection? {
        guard totalCredits > 0, resetAt > startAt,
              now >= startAt, now < resetAt else { return nil }
        let cycleDays = calendar.dateComponents(
            [.day], from: startAt, to: resetAt
        ).day ?? 0
        let elapsedDays = (calendar.dateComponents(
            [.day], from: startAt, to: now
        ).day ?? 0) + 1
        guard cycleDays > 0 else { return nil }
        let calendarElapsed = min(cycleDays, max(1, elapsedDays))
        guard calendarElapsed < cycleDays else { return nil }

        let daysInPeriod: Int
        let elapsed: Int
        if excludeWeekends {
            let firstDay = calendar.startOfDay(for: startAt)
            daysInPeriod = workdays(
                from: firstDay, days: cycleDays, calendar: calendar
            )
            elapsed = workdays(
                from: firstDay, days: calendarElapsed, calendar: calendar
            )
            guard elapsed > 0, elapsed < daysInPeriod else { return nil }
        } else {
            daysInPeriod = cycleDays
            elapsed = calendarElapsed
        }

        return SpendProjection(
            projectedCredits: totalCredits / Double(elapsed)
                * Double(daysInPeriod),
            budgetCredits: monthlyBudgetUSD * 100,
            daysElapsed: elapsed,
            daysInPeriod: daysInPeriod,
            endLabel: utcEndFormatter.string(from: resetAt),
            excludesWeekends: excludeWeekends
        )
    }

    static func verify() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let start = calendar.date(from: DateComponents(year: 2025, month: 7, day: 1))!
        let reset = calendar.date(from: DateComponents(year: 2025, month: 8, day: 1))!
        let now = calendar.date(from: DateComponents(year: 2025, month: 7, day: 10))!
        func project(
            _ credits: Double, budget: Double = 150,
            now: Date = now, excludeWeekends: Bool = false
        ) -> SpendProjection? {
            computeBillingCycle(
                totalCredits: credits, monthlyBudgetUSD: budget,
                startAt: start, resetAt: reset, now: now,
                calendar: calendar, excludeWeekends: excludeWeekends
            )
        }
        let standard = project(300)!
        precondition(abs(standard.projectedCredits - 930) < 1e-6)
        precondition(standard.daysElapsed == 10 && standard.daysInPeriod == 31)
        precondition(!standard.overBudget && standard.budgetCredits == 15_000)
        precondition(project(6_000)!.overBudget)
        let noBudget = project(300, budget: 0)!
        precondition(!noBudget.hasBudget && noBudget.pctOfBudget == 0)
        precondition(project(0) == nil)
        precondition(project(300, now: reset) == nil)
        precondition(project(300, now: start.addingTimeInterval(-1)) == nil)
        let weekdays = project(300, excludeWeekends: true)!
        precondition(weekdays.daysElapsed == 8 && weekdays.daysInPeriod == 23)
        precondition(abs(weekdays.projectedCredits - 862.5) < 1e-6)
        precondition(weekdays.excludesWeekends && weekdays.projectedCredits >= 300)
        let febStart = calendar.date(from: DateComponents(year: 2025, month: 2, day: 1))!
        let febReset = calendar.date(from: DateComponents(year: 2025, month: 3, day: 1))!
        let febNow = febStart.addingTimeInterval(86_400)
        precondition(computeBillingCycle(
            totalCredits: 300, monthlyBudgetUSD: 150,
            startAt: febStart, resetAt: febReset, now: febNow,
            calendar: calendar, excludeWeekends: true
        ) == nil, "a weekend opening has no working-day rate yet")
        let augStart = reset
        let augReset = calendar.date(from: DateComponents(year: 2025, month: 9, day: 1))!
        let augNow = calendar.date(from: DateComponents(year: 2025, month: 8, day: 29))!
        precondition(computeBillingCycle(
            totalCredits: 300, monthlyBudgetUSD: 150,
            startAt: augStart, resetAt: augReset, now: augNow,
            calendar: calendar, excludeWeekends: true
        ) == nil, "no forecast remains once all working days have elapsed")
        let anniversaryStart = calendar.date(from: DateComponents(year: 2025, month: 6, day: 25))!
        let anniversaryReset = calendar.date(from: DateComponents(year: 2025, month: 7, day: 25))!
        let anniversaryNow = calendar.date(from: DateComponents(year: 2025, month: 7, day: 15))!
        let anniversary = computeBillingCycle(
            totalCredits: 2_100, monthlyBudgetUSD: 150,
            startAt: anniversaryStart, resetAt: anniversaryReset,
            now: anniversaryNow, calendar: calendar
        )!
        precondition(anniversary.daysElapsed == 21 && anniversary.daysInPeriod == 30)
        precondition(anniversary.endLabel == "Jul 25" && anniversary.projectedCredits == 3_000)
        BudgetInput.verify { name, passed in
            precondition(passed, name)
        }
        print("Billing-cycle projection verification passed")
    }
}

// ---------------------------------------------------------------------------
// Formatting helpers
// ---------------------------------------------------------------------------

enum Fmt {
    /// "2026-08-04" — for generated filenames (diagnostics export).
    static func fileStamp(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: d)
    }

    /// 2 decimal places, e.g. "1094.16".
    static func credits(_ n: Double) -> String {
        String(format: "%.2f", n)
    }

    /// USD without trailing ".00" for whole amounts, e.g. "$150" or "$99.50".
    static func money(_ usd: Double) -> String {
        usd == usd.rounded() ? String(format: "$%.0f", usd) : String(format: "$%.2f", usd)
    }

    /// Money for a chart axis, in a caller-supplied currency and at a caller-
    /// chosen precision. The precision must come from the axis' own tick step,
    /// not from the value: a step of 2.5 formatted to whole dollars labels its
    /// gridlines "$2" and "$8", which are simply the wrong numbers.
    /// Separate from `money`, which is USD-only by construction.
    static func axisMoney(_ amount: Double, symbol: String, decimals: Int) -> String {
        symbol + String(format: "%.\(decimals)f", amount)
    }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "MM/dd/yyyy, HH:mm"
        return f
    }()

    /// "06/03/2026, 14:05" — local time, 24-hour.
    static func dateTime(_ ms: Int64) -> String {
        dateFmt.string(from: Date(timeIntervalSince1970: Double(ms) / 1000.0))
    }

}
