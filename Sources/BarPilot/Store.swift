import Foundation
import SwiftUI
import AppKit

// ---------------------------------------------------------------------------
// UsageStore — the app's single source of truth.
//
// Raw records are loaded once (cheap to keep — a few hundred) and re-read on a
// timer / manual refresh. Changing the selected period only re-aggregates the
// cached records, so the menu-bar total and detail window update instantly.
// ---------------------------------------------------------------------------

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var report: Report = .empty
    @Published private(set) var isLoading = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var status = SourcesStatus()

    @Published var periodKind: PeriodKind { didSet { onPeriodChanged() } }
    @Published var customFrom: Date { didSet { if periodKind == .custom { recompute() } } }
    @Published var customTo: Date { didSet { if periodKind == .custom { recompute() } } }

    /// Monthly budget in USD. The per-period budget is derived from this by
    /// pro-rating across the days in the selected range (a per-day rate).
    @Published var monthlyBudget: Double { didSet { persistBudget() } }

    /// Currency the UI displays costs in. Internally everything stays USD.
    @Published var displayCurrency: Currency { didSet { persistCurrency(); recompute() } }
    /// Latest USD→AUD rate (nil until fetched/cached); published so the UI updates.
    @Published private(set) var usdToAUD: Double?

    /// Text shown in the menu bar (the selected period's total cost).
    @Published private(set) var menuBarTitle: String = "—"

    private var allRecords: [UsageRecord] = []
    private var timer: Timer?
    private var rateTimer: Timer?

    private static let periodKey = "selectedPeriodKind"
    private static let budgetKey = "monthlyBudgetUSD"
    private static let currencyKey = "displayCurrency"
    private static let rateKey = "usdToAUDRate"
    private static let rateDateKey = "usdToAUDRateDate"
    /// Average days per month (365.25 / 12) — used to convert the monthly
    /// budget into a stable per-day rate for any selected range.
    private static let avgDaysPerMonth = 30.4375

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.periodKey)
        periodKind = PeriodKind(rawValue: saved ?? "") ?? .thisMonth

        let storedBudget = UserDefaults.standard.double(forKey: Self.budgetKey)
        monthlyBudget = storedBudget > 0 ? storedBudget : 150  // ≈ $5/day default

        displayCurrency = Currency(rawValue: UserDefaults.standard.string(forKey: Self.currencyKey) ?? "") ?? .usd
        let cachedRate = UserDefaults.standard.double(forKey: Self.rateKey)
        usdToAUD = cachedRate > 0 ? cachedRate : nil

        let cal = Calendar.current
        let now = Date()
        customTo = now
        customFrom = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now

        Task { await reload() }
        Task { await refreshRate() }

        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { await self?.reload() }
        }
        rateTimer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            Task { await self?.refreshRate() }
        }
    }

    // -----------------------------------------------------------------------
    // Loading
    // -----------------------------------------------------------------------

    /// Re-read both data sources from disk, then re-aggregate.
    func reload() async {
        isLoading = true
        let loaded = await Task.detached(priority: .utility) {
            DataSources.loadAll()
        }.value
        allRecords = loaded.records
        status = loaded.status
        lastUpdated = Date()
        isLoading = false
        recompute()
    }

    // -----------------------------------------------------------------------
    // Aggregation (cheap; runs on the main actor)
    // -----------------------------------------------------------------------

    private func recompute() {
        let range = PeriodResolver.range(kind: periodKind, customFrom: customFrom, customTo: customTo)
        report = Aggregator.build(
            records: allRecords,
            fromStr: range.from,
            toStr: range.to,
            todayStr: PeriodResolver.todayStr()
        )
        menuBarTitle = costString(credits: report.totalCredits)
    }

    private func onPeriodChanged() {
        UserDefaults.standard.set(periodKind.rawValue, forKey: Self.periodKey)
        recompute()
    }

    private func persistBudget() {
        UserDefaults.standard.set(monthlyBudget, forKey: Self.budgetKey)
    }

    private func persistCurrency() {
        UserDefaults.standard.set(displayCurrency.rawValue, forKey: Self.currencyKey)
    }

    /// Fetch the latest USD→AUD rate, cache it, and refresh the UI on success.
    func refreshRate() async {
        guard let rate = await ExchangeRate.fetchUSDToAUD() else { return }
        usdToAUD = rate
        UserDefaults.standard.set(rate, forKey: Self.rateKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.rateDateKey)
        recompute()
    }

    // -----------------------------------------------------------------------
    // Currency / display formatting (everything is stored in USD)
    // -----------------------------------------------------------------------

    /// Falls back to USD if AUD is selected but no rate has loaded yet.
    var effectiveCurrency: Currency {
        (displayCurrency == .aud && usdToAUD == nil) ? .usd : displayCurrency
    }

    private func toDisplay(_ usd: Double) -> Double {
        effectiveCurrency == .aud ? usd * (usdToAUD ?? 1) : usd
    }

    /// Cost from credits, 2 dp, in the display currency. e.g. "$10.94" / "A$15.55".
    func costString(credits: Double) -> String {
        effectiveCurrency.symbol + String(format: "%.2f", toDisplay(credits / 100.0))
    }

    /// Cost from a USD amount, 2 dp, in the display currency.
    func costString(usd: Double) -> String {
        effectiveCurrency.symbol + String(format: "%.2f", toDisplay(usd))
    }

    /// The monthly-budget figure for the "/ mo" label: USD keeps the existing
    /// no-trailing-zeros style; AUD is converted and rounded to a whole dollar.
    func budgetMoneyString(usd: Double) -> String {
        effectiveCurrency == .aud
            ? effectiveCurrency.symbol + String(Int(toDisplay(usd).rounded()))
            : Fmt.money(usd)
    }

    // -----------------------------------------------------------------------
    // Budget derived for the currently-selected period.
    // -----------------------------------------------------------------------

    /// Budget for the selected span, in credits (100 credits = $1).
    /// "This Month" compares against the FULL monthly budget so the bar shows
    /// progress through the month (matching the "This month's budget" label),
    /// rather than a per-day pro-ration that collapses to a single day on the 1st.
    /// Every other period pro-rates the daily rate across the days in its range.
    var periodBudgetCredits: Double {
        if periodKind == .thisMonth {
            return monthlyBudget * 100.0
        }
        let perDayCredits = (monthlyBudget * 100.0) / Self.avgDaysPerMonth
        return perDayCredits * Double(max(report.daysInRange, 1))
    }

    var budgetTitle: String { periodKind.budgetTitle }

    // -----------------------------------------------------------------------
    // Telemetry setup (explicit, user-confirmed)
    // -----------------------------------------------------------------------

    /// Confirm, then natively enable OTel telemetry for any unconfigured source.
    func runTelemetrySetup() {
        let planned = TelemetrySetup.plannedChanges()
        guard !planned.isEmpty else { return }

        let confirm = NSAlert()
        confirm.messageText = "Enable Copilot telemetry?"
        confirm.informativeText = """
        BarPilot will make these changes (all in your ~/Library — no admin needed):

        • \(planned.joined(separator: "\n• "))

        macOS may show a “Background Items Added” notice for the LaunchAgent. \
        Afterwards, restart VS Code and quit & relaunch the GitHub Copilot app.
        """
        confirm.addButton(withTitle: "Enable")
        confirm.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        let result = TelemetrySetup.enableAll()

        let done = NSAlert()
        if result.ok {
            done.messageText = "Telemetry enabled"
            done.informativeText = """
            Applied:
            • \(result.changes.joined(separator: "\n• "))

            Next: restart VS Code, and quit & relaunch the GitHub Copilot app, then \
            use Copilot to start recording usage.
            """
        } else {
            done.alertStyle = .warning
            done.messageText = "Setup partly failed"
            let applied = result.changes.isEmpty ? "" : "Applied:\n• \(result.changes.joined(separator: "\n• "))\n\n"
            done.informativeText = applied + "Problems:\n• \(result.errors.joined(separator: "\n• "))"
        }
        done.runModal()

        Task { await reload() }
    }

    /// Set the monthly budget via a simple input dialog (right-click menu entry).
    /// Input is in the displayed currency; stored canonically in USD.
    func promptForBudget() {
        let cur = effectiveCurrency
        let alert = NSAlert()
        alert.messageText = "Monthly budget"
        alert.informativeText = "Your Copilot budget per month, in \(cur.code) (\(cur.symbol)). It's pro-rated across the days in the selected period."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        if cur == .aud, let rate = usdToAUD {
            field.stringValue = String(Int((monthlyBudget * rate).rounded()))
        } else {
            field.stringValue = Fmt.money(monthlyBudget).replacingOccurrences(of: "$", with: "")
        }
        field.placeholderString = cur == .aud ? "e.g. 230" : "e.g. 150"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let cleaned = field.stringValue
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "A$", with: "")
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
        guard let value = Double(cleaned), value >= 0 else { return }
        if cur == .aud, let rate = usdToAUD, rate > 0 {
            monthlyBudget = value / rate          // entered AUD → canonical USD
        } else {
            monthlyBudget = value
        }
    }
}
