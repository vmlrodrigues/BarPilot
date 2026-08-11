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
    /// Server-authoritative overlay for the current billing cycle. The raw
    /// `report` above always remains the local/classified report.
    @Published private(set) var reconciled = ReconciledUsage.local(.empty)

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

    /// Multi-machine sync (opt-in, default OFF). When ON, the aggregate tabs show
    /// this machine + remote machines combined; Sessions/Top stay local.
    @Published var syncEnabled: Bool { didSet { UserDefaults.standard.set(syncEnabled, forKey: Self.syncKey); recompute() } }
    /// Machines contributing to the combined view (this + remotes); 1 when OFF.
    @Published private(set) var syncMachineCount: Int = 1
    /// GitHub login this machine's sync is authorized as (for the status bubble).
    @Published private(set) var syncLogin: String? { didSet { UserDefaults.standard.set(syncLogin, forKey: "syncLogin") } }
    /// Last sync failure to surface in the footer (nil = healthy). Mainly catches
    /// the "this account can't create gists" (enterprise) case.
    @Published private(set) var syncError: String?
    private var isSyncing = false        // reentrancy guard so overlapping syncNow calls don't interleave
    private var syncPushBlocked = false  // set after a permanent (403/401) failure; cleared on re-enable

    /// Account-level credit counter (opt-in, independent from gist sync).
    @Published private(set) var serverUsageEnabled = false
    @Published private(set) var serverUsageSample: CreditSample?
    @Published private(set) var serverUsageError: String?
    private var creditSamples: [CreditSample] = []
    private var serverUsageGeneration = 0
    private var activeServerRefreshes: Set<Int> = []

    /// Text shown in the menu bar (the selected period's total cost).
    @Published private(set) var menuBarTitle: String = "—"
    /// Is the Copilot app recording telemetry right now? Drives the menu-bar
    /// warning glyph and the window banner (#27).
    @Published private(set) var exporterVerdict: ExporterHealth.Verdict = .healthy
    private var simulatingExporterDown = false

    /// Whether to actually SHOW the exporter warning. Off by default while the
    /// detection is unreliable (#32) — the dev simulation flag still forces it so
    /// the UI can be worked on.
    var showExporterWarning: Bool {
        (ExporterHealth.warningsEnabled || simulatingExporterDown) && exporterVerdict.isWarning
    }

    private var allRecords: [UsageRecord] = []
    private var timer: Timer?
    private var rateTimer: Timer?

    private static let periodKey = "selectedPeriodKind"
    private static let budgetKey = "monthlyBudgetUSD"
    private static let currencyKey = "displayCurrency"
    private static let rateKey = "usdToAUDRate"
    private static let rateDateKey = "usdToAUDRateDate"
    private static let syncKey = "multiMachineSyncEnabled"
    private static let serverUsageKey = "serverCreditUsageEnabled"
    private static let serverUsageBaselineKey = "serverCreditUsageBaselineMs"
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

        syncEnabled = UserDefaults.standard.bool(forKey: Self.syncKey)   // default false
        syncLogin = UserDefaults.standard.string(forKey: "syncLogin")

        let cal = Calendar.current
        let now = Date()
        customTo = now
        customFrom = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now

        serverUsageEnabled = UserDefaults.standard.bool(forKey: Self.serverUsageKey)
        if serverUsageEnabled,
           let baseline = Int64(UserDefaults.standard.string(forKey: Self.serverUsageBaselineKey) ?? ""),
           let latest = CreditSampleStore.latest(from: baseline) {
            serverUsageSample = latest
            creditSamples = CreditSampleStore.load(resetAtMs: latest.resetAtMs, from: baseline)
        }

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
        // Single-flight: reload() is triggered from six places (60s timer, launch,
        // refresh, popover-open, telemetry setup, budget/currency change). Without
        // this, two triggers close together (typically on wake) each run a full
        // loadAll() — concurrent whole-file JSONL scans that peg CPU + memory. (#23)
        guard !isLoading else { return }
        isLoading = true
        let t0 = Date()
        let loaded = await Task.detached(priority: .utility) {
            DataSources.loadAll()
        }.value
        let loadMs = Int(Date().timeIntervalSince(t0) * 1000)
        allRecords = loaded.records
        status = loaded.status
        lastUpdated = Date()
        isLoading = false

        // Watchdog: the Copilot app heartbeats into its JSONL every ~10s, so if
        // it's running and the file isn't growing, its exporter is dead. Checked
        // here (main actor) because NSWorkspace is a UI-layer API. (#27)
        let copilot = NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == ExporterHealth.copilotBundleId }
        exporterVerdict = ExporterHealth.evaluate(
            appRunning: copilot != nil,
            appUptime: copilot?.launchDate.map { Date().timeIntervalSince($0) },
            secondsSinceGrowth: status.macAppSecondsSinceGrowth,
            gapSinceLastCheck: status.gapSinceLastCheck)
        // Dev-only: force the warning state to eyeball the UI without having to
        // break a real exporter. Gated to dev builds so a release can never be
        // coaxed into showing a false alarm.
        simulatingExporterDown = Updater.isDevBuild
            && ProcessInfo.processInfo.environment["BARPILOT_SIMULATE_EXPORTER_DOWN"] != nil
        if simulatingExporterDown { exporterVerdict = .silent(minutes: 14) }

        recompute()
        // Rotating support log (#24): load cost + what the reload actually computed
        // vs the menu title it set — also the #13 display-vs-data drift diagnostic.
        DiagLog.write("reload: \(loadMs)ms · scanned \(DiagLog.humanBytes(status.jsonlBytesScanned)) · +\(status.newRecords) new · \(allRecords.count) cached · period \(periodKind.rawValue) · total \(Fmt.credits(reconciled.totalCredits)) cr · menu \"\(menuBarTitle)\"")
        if syncEnabled { Task { await self.syncNow() } }   // background push/pull
        if serverUsageEnabled { Task { await self.refreshServerUsage() } }
    }

    // -----------------------------------------------------------------------
    // Aggregation (cheap; runs on the main actor)
    // -----------------------------------------------------------------------

    private func recompute() {
        // Don't paint the menu bar before the first load lands: init() kicks off
        // reload() and refreshRate() concurrently, and if the rate fetch wins the
        // race it would recompute with allRecords still empty — showing a
        // remote-only (sync) or $0 total until reload finishes. reload() sets
        // lastUpdated just before its own recompute, so this holds "—" until then. (#20)
        guard lastUpdated != nil else { return }
        let range = PeriodResolver.range(kind: periodKind, customFrom: customFrom, customTo: customTo)
        let today = PeriodResolver.todayStr()
        if syncEnabled {
            let remotes = currentRemoteAggregates()
            syncMachineCount = remotes.count + 1
            report = Aggregator.buildCombined(
                localRecords: allRecords, remoteAggregates: remotes,
                fromStr: range.from, toStr: range.to, todayStr: today)
        } else {
            syncMachineCount = 1
            report = Aggregator.build(
                records: allRecords, fromStr: range.from, toStr: range.to, todayStr: today)
        }
        reconciled = CreditReconciliation.build(
            report: report,
            periodKind: periodKind,
            snapshot: serverUsageEnabled ? serverUsageSample : nil,
        )
        // Prefix a warning glyph when telemetry has stopped: the menu-bar figure
        // is where the stale number is shown, so it's where the doubt belongs.
        let cost = costString(credits: reconciled.totalCredits)
        menuBarTitle = showExporterWarning ? "⚠︎ " + cost : cost
    }

    /// Other machines' aggregates to combine, from the local RemoteStore (last
    /// pull). Excludes this machine's own id defensively.
    private func currentRemoteAggregates() -> [MachineAggregate] {
        RemoteStore.load().filter { $0.machineId != Self.machineId }
    }

    // -----------------------------------------------------------------------
    // Multi-machine sync (GitHub gist backend)
    // -----------------------------------------------------------------------

    /// Stable per-machine id, generated once and kept in UserDefaults.
    static var machineId: String {
        if let id = UserDefaults.standard.string(forKey: "syncMachineId") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "syncMachineId")
        return id
    }
    private static var machineLabel: String { Host.current().localizedName ?? ProcessInfo.processInfo.hostName }
    private static func nowISO() -> String { ISO8601DateFormatter().string(from: Date()) }
    private static let pushFPKey = "syncLastPushFingerprint"

    /// Turn sync on with a freshly-obtained token: persist it, enable, and do an
    /// initial push + pull. Returns the machine count now contributing.
    func enableSyncWith(token: String) async -> Int {
        Keychain.saveToken(token)
        syncPushBlocked = false; syncError = nil   // fresh start (clears a prior permanent-error block)
        syncLogin = await GitHubBackend(token: token).currentLogin()   // show which account
        syncEnabled = true          // didSet persists + recomputes (local only until pull lands)
        await syncNow(force: true)
        return syncMachineCount
    }

    /// Turn sync off. Local raw cache untouched; remote data cache cleared and
    /// the token removed. Does NOT delete the remote gist (offered separately).
    func disableSync() {
        syncEnabled = false         // didSet persists + recomputes (back to local-only)
        Keychain.deleteToken()
        RemoteStore.clear()
        syncLogin = nil
        syncError = nil
        syncPushBlocked = false
        UserDefaults.standard.removeObject(forKey: Self.pushFPKey)
    }

    /// Push this machine's aggregate (only if it changed) and pull the others
    /// into the RemoteStore, then recompute. Safe no-op when off / no token.
    func syncNow(force: Bool = false) async {
        guard syncEnabled, !isSyncing, let token = Keychain.token() else { return }   // reentrancy guard
        isSyncing = true
        defer { isSyncing = false }
        let backend = GitHubBackend(token: token)
        if syncLogin == nil { syncLogin = await backend.currentLogin() }   // backfill for already-enabled installs
        let mine = SyncAggregate.project(allRecords, machineId: Self.machineId,
                                         label: Self.machineLabel, updatedAt: Self.nowISO())
        let fp = "\(mine.rows.count):\(mine.rows.reduce(0.0) { $0 + $1.credits }):\(mine.rows.reduce(0) { $0 + $1.inTok + $1.outTok })"
        if !syncPushBlocked && (force || fp != UserDefaults.standard.string(forKey: Self.pushFPKey) || syncError != nil) {
            do {
                try await backend.push(mine)
                UserDefaults.standard.set(fp, forKey: Self.pushFPKey)
                syncError = nil
            } catch {
                syncError = Self.syncErrorMessage(error)
                if (error as? SyncError)?.isPermanent == true { syncPushBlocked = true }   // stop hammering GitHub on a permanent failure
                NSLog("BarPilot sync: push failed (\(error))")
            }
        }
        if syncPushBlocked { return }   // this account can't sync — don't pull either
        // Replace the remote cache only on a NON-EMPTY pull, so a transient empty
        // result (eventual consistency right after our own push) can't wipe it.
        if let others = try? await backend.pullOthers(excluding: Self.machineId), !others.isEmpty {
            RemoteStore.clear()
            for o in others { RemoteStore.save(o) }
            recompute()
        }
    }

    /// Human-readable reason for a sync push failure (shown in the footer).
    private static func syncErrorMessage(_ error: Error) -> String {
        switch error as? SyncError {
        case .forbidden:
            return "This account can’t create gists — usually a work/enterprise account (gists are disabled there). Turn sync off and re-enable with a personal account."
        case .unauthorized:
            return "Sync authorization is no longer valid. Turn sync off and re-enable."
        case .network:
            return "Can’t reach GitHub right now — will keep retrying."
        default:
            return "Sync couldn’t upload — will retry."
        }
    }

    // -----------------------------------------------------------------------
    // Server-authoritative account usage (#33)
    // -----------------------------------------------------------------------

    /// Enable account usage with its own credential, then take the opening
    /// baseline. Existing gist-sync authorization is deliberately unaffected.
    func enableServerUsageWith(token: String) async -> Bool {
        serverUsageGeneration += 1
        CreditUsageKeychain.saveToken(token)
        serverUsageSample = nil
        creditSamples = []
        UserDefaults.standard.removeObject(forKey: Self.serverUsageBaselineKey)
        serverUsageEnabled = true
        UserDefaults.standard.set(true, forKey: Self.serverUsageKey)
        serverUsageError = nil
        await refreshServerUsage()
        guard serverUsageSample != nil && serverUsageError == nil else {
            let error = serverUsageError
            serverUsageGeneration += 1
            serverUsageEnabled = false
            UserDefaults.standard.set(false, forKey: Self.serverUsageKey)
            CreditUsageKeychain.deleteToken()
            UserDefaults.standard.removeObject(forKey: Self.serverUsageBaselineKey)
            creditSamples = []
            serverUsageSample = nil
            serverUsageError = error
            recompute()
            return false
        }
        return true
    }

    func disableServerUsage() {
        serverUsageGeneration += 1
        serverUsageEnabled = false
        UserDefaults.standard.set(false, forKey: Self.serverUsageKey)
        CreditUsageKeychain.deleteToken()
        serverUsageSample = nil
        creditSamples = []
        serverUsageError = nil
        UserDefaults.standard.removeObject(forKey: Self.serverUsageBaselineKey)
        recompute()
    }

    /// Fetch one cumulative counter observation. A failed request never writes a
    /// zero or replaces the last good sample.
    func refreshServerUsage() async {
        let generation = serverUsageGeneration
        guard serverUsageEnabled, !activeServerRefreshes.contains(generation) else { return }
        guard let token = CreditUsageKeychain.token() else {
            serverUsageError = "Authorization is missing. Reconnect GitHub Credit Total from the menu."
            return
        }
        activeServerRefreshes.insert(generation)
        defer { activeServerRefreshes.remove(generation) }
        do {
            let sample = try await CreditUsageAPI.fetch(token: token)
            guard serverUsageEnabled, generation == serverUsageGeneration else { return }
            if creditSamples.isEmpty {
                UserDefaults.standard.set(String(sample.capturedAtMs), forKey: Self.serverUsageBaselineKey)
            }
            let saved = await Task.detached(priority: .utility) {
                CreditSampleStore.save(sample)
            }.value
            guard serverUsageEnabled, generation == serverUsageGeneration else { return }
            guard saved else {
                serverUsageError = "The GitHub total was received but couldn’t be saved locally."
                return
            }
            if serverUsageSample?.resetAtMs != sample.resetAtMs {
                creditSamples = [sample]
                UserDefaults.standard.set(String(sample.capturedAtMs), forKey: Self.serverUsageBaselineKey)
            } else {
                creditSamples.append(sample)
            }
            serverUsageSample = sample
            serverUsageError = nil
            recompute()
        } catch {
            guard serverUsageEnabled, generation == serverUsageGeneration else { return }
            serverUsageError = Self.serverUsageErrorMessage(error)
        }
    }

    private static func serverUsageErrorMessage(_ error: Error) -> String {
        switch error as? CreditUsageError {
        case .unauthorized:
            return "GitHub authorization expired. Reconnect GitHub Credit Total from the menu."
        case .forbidden:
            return "This GitHub account can’t read its Copilot credit total."
        case .invalidResponse:
            return "GitHub returned an unsupported credit-total response."
        default:
            return "Can’t refresh the GitHub credit total right now; the last good sample is retained."
        }
    }

    var displayTotalCredits: Double { reconciled.totalCredits }
    var classifiedTotalCredits: Double { reconciled.classifiedCredits }
    var sessionClassifiedTotalCredits: Double {
        report.sessions.reduce(0) { $0 + $1.credits }
    }
    var unclassifiedCredits: Double { reconciled.unclassifiedCredits }
    var summaryRows: [SummaryRow] { reconciled.summary }
    var modelRows: [ModelRow] { reconciled.models }
    var dailyRows: [DailyRow] { reconciled.daily }

    var serverUsageIsStale: Bool {
        guard let sample = serverUsageSample else { return false }
        return Date().timeIntervalSince(sample.capturedAt) > 5 * 60
    }

    var serverUsageStatusLabel: String {
        guard serverUsageEnabled else { return "GitHub total · off" }
        if serverUsageError != nil { return "GitHub total · error" }
        if serverUsageSample == nil { return "GitHub total · connecting" }
        if serverUsageIsStale { return "GitHub total · stale" }
        return "GitHub total · live"
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

    var spendTitle: String { periodKind.spendTitle }

    /// Run-rate projection of full-month spend (nil unless viewing an in-progress
    /// month with usage). Pure + derived from the current report — see #18.
    var spendProjection: SpendProjection? {
        var displayReport = report
        displayReport.totalCredits = reconciled.totalCredits
        displayReport.todayCredits = reconciled.todayCredits
        return SpendProjection.compute(periodKind: periodKind, report: displayReport,
                                monthlyBudgetUSD: monthlyBudget, now: Date())
    }

    // -----------------------------------------------------------------------
    // Sparkline series
    // -----------------------------------------------------------------------

    /// Daily series for the header sparkline. For short periods it spans the
    /// period's FULL calendar extent — so "This Month" shows the whole month with
    /// only used days drawn and the rest blank, filling in as the month
    /// progresses. This Year / All Time (and any range > 45 days) keep the raw
    /// data-day series, since a bar-per-day won't fit the strip.
    var sparklineTotals: [DayTotal] {
        // In sync mode the combined dailyTotals are UTC-keyed; the full-extent grid
        // keys by local day, so they wouldn't match — fall back to the raw series.
        guard !syncEnabled, let (start, end) = sparklineExtent() else { return reconciled.dailyTotals }
        let cal = Calendar.current
        let days = (cal.dateComponents([.day], from: start, to: end).day ?? 0) + 1
        guard days >= 1, days <= 45 else { return reconciled.dailyTotals }
        var byDay: [String: Double] = [:]
        for t in reconciled.dailyTotals { byDay[t.day] = t.credits }
        var out: [DayTotal] = []
        var d = start
        for _ in 0..<days {
            let key = Self.dayString(d, cal)
            out.append(DayTotal(day: key, credits: byDay[key] ?? 0))
            guard let next = cal.date(byAdding: .day, value: 1, to: d) else { break }
            d = next
        }
        return out
    }

    /// Full calendar extent (local calendar) to chart for the current period, or
    /// nil for periods that keep the raw data-day series (This Year / All Time).
    private func sparklineExtent() -> (start: Date, end: Date)? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        switch periodKind {
        case .today:
            return (today, today)
        case .last7:
            return (cal.date(byAdding: .day, value: -6, to: today) ?? today, today)
        case .last30:
            return (cal.date(byAdding: .day, value: -29, to: today) ?? today, today)
        case .thisMonth:
            let comps = cal.dateComponents([.year, .month], from: today)
            guard let first = cal.date(from: comps),
                  let range = cal.range(of: .day, in: .month, for: today) else { return nil }
            return (first, cal.date(byAdding: .day, value: range.count - 1, to: first) ?? first)
        case .previousMonth:
            let comps = cal.dateComponents([.year, .month], from: today)
            guard let firstOfThis = cal.date(from: comps),
                  let lastOfPrev = cal.date(byAdding: .day, value: -1, to: firstOfThis),
                  let firstOfPrev = cal.date(from: cal.dateComponents([.year, .month], from: lastOfPrev))
                  else { return nil }
            return (firstOfPrev, lastOfPrev)
        case .custom:
            let a = cal.startOfDay(for: customFrom), b = cal.startOfDay(for: customTo)
            return a <= b ? (a, b) : (b, a)
        case .thisYear, .allTime:
            return nil
        }
    }

    /// "YYYY-MM-DD" in the local calendar — matches `Aggregator.localDayStr` keys.
    private static func dayString(_ d: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

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
