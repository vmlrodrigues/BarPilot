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
    @Published private(set) var currentMonthReport: Report = .empty
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

    /// Multi-machine sync (opt-in, default OFF). The primary timeline unions
    /// account-counter observations; legacy aggregate tabs still combine rows.
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

    /// Primary account-level credit connection, independent from gist sync.
    @Published private(set) var serverUsageEnabled = false
    @Published private(set) var serverUsageSample: CreditSample?
    @Published private(set) var serverUsageError: String?
    @Published private(set) var isConnectingServerUsage = false
    private var creditSamples: [CreditSample] = []
    private var serverUsageAccountFingerprint: String?
    private var serverUsageGeneration = 0
    private var activeServerRefreshes: Set<Int> = []

    /// Text shown in the menu bar (the compact current-month total cost).
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
    private static let serverUsageDisconnectedKey = "serverCreditUsageExplicitlyDisconnected"
    private static let serverUsageBaselineKey = "serverCreditUsageBaselineMs"
    private static let serverUsageAccountKey = "serverCreditUsageAccountFingerprint"
    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    /// Average days per month (365.25 / 12) — used to convert the monthly
    /// budget into a stable per-day rate for any selected range.
    private static let avgDaysPerMonth = 30.4375

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.periodKey)
        periodKind = PeriodKind(rawValue: saved ?? "") ?? .thisMonth

        if UserDefaults.standard.object(forKey: Self.budgetKey) != nil {
            monthlyBudget = max(0, UserDefaults.standard.double(forKey: Self.budgetKey))
        } else {
            monthlyBudget = 150  // ≈ $5/day default
        }

        displayCurrency = Currency(rawValue: UserDefaults.standard.string(forKey: Self.currencyKey) ?? "") ?? .usd
        let cachedRate = UserDefaults.standard.double(forKey: Self.rateKey)
        usdToAUD = cachedRate > 0 ? cachedRate : nil

        syncEnabled = UserDefaults.standard.bool(forKey: Self.syncKey)   // default false
        syncLogin = UserDefaults.standard.string(forKey: "syncLogin")

        let cal = Calendar.current
        let now = Date()
        customTo = now
        customFrom = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now

        // Connection is credential-driven, not an optional feature toggle. A
        // disconnected install presents its setup CTA in the primary dashboard.
        let explicitlyDisconnected = UserDefaults.standard.bool(
            forKey: Self.serverUsageDisconnectedKey
        )
        serverUsageEnabled = !explicitlyDisconnected && CreditUsageKeychain.token() != nil
        UserDefaults.standard.set(serverUsageEnabled, forKey: Self.serverUsageKey)
        serverUsageAccountFingerprint = UserDefaults.standard.string(forKey: Self.serverUsageAccountKey)
        if let baseline = Int64(UserDefaults.standard.string(forKey: Self.serverUsageBaselineKey) ?? ""),
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
        let monthRange = PeriodResolver.range(
            kind: .thisMonth, customFrom: customFrom, customTo: customTo)
        if range.from == monthRange.from && range.to == monthRange.to {
            currentMonthReport = report
        } else if syncEnabled {
            currentMonthReport = Aggregator.buildCombined(
                localRecords: allRecords, remoteAggregates: currentRemoteAggregates(),
                fromStr: monthRange.from, toStr: monthRange.to, todayStr: today)
        } else {
            currentMonthReport = Aggregator.build(
                records: allRecords, fromStr: monthRange.from,
                toStr: monthRange.to, todayStr: today)
        }
        reconciled = CreditReconciliation.build(
            report: report,
            periodKind: periodKind,
            snapshot: serverUsageEnabled ? serverUsageSample : nil,
        )
        // The menu-bar figure must signal when it is a local fallback rather than
        // the authoritative GitHub total. Reuse the existing warning glyph.
        let cost = costString(credits: compactTotalCredits)
        let needsWarning = !serverUsageEnabled || serverUsageError != nil
            || currentServerUsageSample == nil || serverUsageIsStale
            || showExporterWarning
        menuBarTitle = needsWarning ? "⚠︎ " + cost : cost
    }

    /// Other machines' payloads from the last successful pull. Excludes this
    /// machine's own id defensively.
    private func currentRemoteAggregates() -> [MachineSyncPayload] {
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
    private static func nowISO() -> String { ISO8601DateFormatter().string(from: Date()) }
    private static let pushFPKey = "syncLastPushFingerprint"

    /// Turn sync on with a freshly-obtained token: persist it, enable, and do an
    /// initial push + pull. Returns the machine count now contributing.
    func enableSyncWith(token: String) async -> Int {
        guard Keychain.saveToken(token) else {
            syncError = "The sync credential couldn’t be saved securely."
            return syncMachineCount
        }
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
        let removed = Keychain.deleteToken()
        RemoteStore.clear()
        syncLogin = nil
        syncError = removed
            ? nil
            : "Sync is off, but macOS couldn’t remove its saved credential."
        syncPushBlocked = false
        UserDefaults.standard.removeObject(forKey: Self.pushFPKey)
    }

    /// Push this machine's payload (only if it changed) and pull the others
    /// into the RemoteStore, then recompute. Safe no-op when off / no token.
    func syncNow(force: Bool = false) async {
        guard syncEnabled, !isSyncing, !isConnectingServerUsage,
              let token = Keychain.token() else { return }
        isSyncing = true
        defer { isSyncing = false }
        let backend = GitHubBackend(token: token)
        if syncLogin == nil { syncLogin = await backend.currentLogin() }   // backfill for already-enabled installs
        let mine = SyncAggregate.project(
            allRecords, creditSamples: creditSamples,
            accountFingerprint: serverUsageAccountFingerprint,
            machineId: Self.machineId, label: nil, updatedAt: Self.nowISO()
        )
        let syncedSamples = mine.creditSamples ?? []
        let fp = [
            "\(mine.rows.count)",
            "\(mine.rows.reduce(0.0) { $0 + $1.credits })",
            "\(mine.rows.reduce(0) { $0 + $1.inTok + $1.outTok })",
            "\(syncedSamples.count)",
            "\(syncedSamples.first?.resetAtMs ?? 0)",
            "\(mine.accountFingerprint ?? "")"
        ].joined(separator: ":")
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
        let previousFingerprint = serverUsageAccountFingerprint
        let previousBaseline = UserDefaults.standard.string(forKey: Self.serverUsageBaselineKey)
        serverUsageGeneration += 1
        let generation = serverUsageGeneration
        UserDefaults.standard.set(true, forKey: Self.serverUsageDisconnectedKey)
        serverUsageError = nil

        guard let fingerprint = await CreditUsageAPI.accountFingerprint(token: token) else {
            guard generation == serverUsageGeneration else { return false }
            serverUsageError = "GitHub authenticated, but BarPilot couldn’t verify the account for safe multi-Mac history."
            recompute()
            return false
        }

        let sample: CreditSample
        do {
            sample = try await CreditUsageAPI.fetch(token: token)
        } catch {
            guard generation == serverUsageGeneration else { return false }
            serverUsageError = Self.serverUsageErrorMessage(error)
            recompute()
            return false
        }
        guard generation == serverUsageGeneration else { return false }

        guard CreditUsageKeychain.saveToken(token) else {
            serverUsageError = "GitHub authenticated, but the credential couldn’t be saved securely."
            recompute()
            return false
        }
        let saved = await Task.detached(priority: .utility) {
            CreditSampleStore.save(sample)
        }.value
        guard generation == serverUsageGeneration else {
            _ = CreditUsageKeychain.deleteToken()
            return false
        }
        guard saved else {
            _ = CreditUsageKeychain.deleteToken()
            serverUsageError = "The GitHub total was received but couldn’t be saved locally."
            recompute()
            return false
        }
        serverUsageAccountFingerprint = fingerprint
        UserDefaults.standard.set(fingerprint, forKey: Self.serverUsageAccountKey)
        serverUsageEnabled = true
        UserDefaults.standard.set(true, forKey: Self.serverUsageKey)
        UserDefaults.standard.set(false, forKey: Self.serverUsageDisconnectedKey)
        if previousFingerprint == fingerprint,
           let baseline = Int64(previousBaseline ?? "") {
            creditSamples = CreditSampleStore.load(
                resetAtMs: sample.resetAtMs, from: baseline
            )
        } else {
            creditSamples = [sample]
            UserDefaults.standard.set(
                String(sample.capturedAtMs), forKey: Self.serverUsageBaselineKey
            )
        }
        serverUsageSample = sample
        serverUsageError = nil
        recompute()
        return true
    }

    func disableServerUsage() {
        serverUsageGeneration += 1
        serverUsageEnabled = false
        UserDefaults.standard.set(false, forKey: Self.serverUsageKey)
        UserDefaults.standard.set(true, forKey: Self.serverUsageDisconnectedKey)
        let removed = CreditUsageKeychain.deleteToken()
        serverUsageError = removed
            ? nil
            : "GitHub is disconnected, but macOS couldn’t remove the saved credential."
        recompute()
    }

    func beginServerUsageConnection() -> Bool {
        guard !isConnectingServerUsage else { return false }
        isConnectingServerUsage = true
        return true
    }

    func endServerUsageConnection() {
        isConnectingServerUsage = false
    }

    /// Fetch one cumulative counter observation. A failed request never writes a
    /// zero or replaces the last good sample.
    func refreshServerUsage() async {
        let generation = serverUsageGeneration
        guard serverUsageEnabled, !activeServerRefreshes.contains(generation) else { return }
        guard let token = CreditUsageKeychain.token() else {
            serverUsageError = "GitHub is disconnected. Connect again from the usage window."
            serverUsageEnabled = false
            UserDefaults.standard.set(false, forKey: Self.serverUsageKey)
            UserDefaults.standard.set(true, forKey: Self.serverUsageDisconnectedKey)
            recompute()
            return
        }
        activeServerRefreshes.insert(generation)
        defer { activeServerRefreshes.remove(generation) }
        do {
            let sample = try await CreditUsageAPI.fetch(token: token)
            guard serverUsageEnabled, generation == serverUsageGeneration else { return }
            if serverUsageAccountFingerprint == nil {
                guard let fingerprint = await CreditUsageAPI.accountFingerprint(token: token) else {
                    guard serverUsageEnabled, generation == serverUsageGeneration else { return }
                    serverUsageError = "GitHub authenticated, but BarPilot couldn’t verify the account for safe multi-Mac history."
                    recompute()
                    return
                }
                guard serverUsageEnabled, generation == serverUsageGeneration else { return }
                serverUsageAccountFingerprint = fingerprint
                UserDefaults.standard.set(fingerprint, forKey: Self.serverUsageAccountKey)
            }
            if creditSamples.isEmpty {
                UserDefaults.standard.set(String(sample.capturedAtMs), forKey: Self.serverUsageBaselineKey)
            }
            let saved = await Task.detached(priority: .utility) {
                CreditSampleStore.save(sample)
            }.value
            guard serverUsageEnabled, generation == serverUsageGeneration else { return }
            guard saved else {
                serverUsageError = "The GitHub total was received but couldn’t be saved locally."
                recompute()
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
            if case .unauthorized = error as? CreditUsageError {
                serverUsageEnabled = false
                UserDefaults.standard.set(false, forKey: Self.serverUsageKey)
                UserDefaults.standard.set(true, forKey: Self.serverUsageDisconnectedKey)
                _ = CreditUsageKeychain.deleteToken()
            }
            recompute()
        }
    }

    private static func serverUsageErrorMessage(_ error: Error) -> String {
        switch error as? CreditUsageError {
        case .unauthorized:
            return "GitHub authentication expired. Disconnect and connect again."
        case .forbidden:
            return "This GitHub account can’t read its Copilot credit total."
        case .invalidResponse:
            return "GitHub returned an unsupported credit-total response."
        default:
            return "Can’t refresh the GitHub credit total right now; the last good sample is retained."
        }
    }

    var displayTotalCredits: Double { reconciled.totalCredits }
    var currentServerUsageSample: CreditSample? {
        guard let sample = serverUsageSample,
              CreditReconciliation.isCurrentCycle(sample) else { return nil }
        return sample
    }
    var compactTotalCredits: Double {
        guard serverUsageEnabled, let sample = currentServerUsageSample else {
            return currentMonthReport.totalCredits
        }
        return max(sample.creditsUsed, currentMonthReport.totalCredits)
    }
    var creditTimeline: CreditTimeline {
        guard let current = currentServerUsageSample else { return .empty }
        guard let accountFingerprint = serverUsageAccountFingerprint else {
            return CreditTimeline.build(
                samples: creditSamples.filter { $0.resetAtMs == current.resetAtMs }
            )
        }
        let remotes = syncEnabled ? currentRemoteAggregates() : []
        let merged = SyncAggregate.mergedCreditSamples(
            local: creditSamples, remotes: remotes,
            resetAtMs: current.resetAtMs,
            accountFingerprint: accountFingerprint
        )
        return CreditTimeline.build(samples: merged)
    }

    var counterSyncMachineCount: Int {
        guard syncEnabled, let accountFingerprint = serverUsageAccountFingerprint else { return 1 }
        let matching = currentRemoteAggregates().filter {
            $0.accountFingerprint == accountFingerprint
                && !($0.creditSamples ?? []).isEmpty
        }
        return matching.count + 1
    }
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
        guard serverUsageEnabled else {
            return serverUsageError == nil ? "GitHub · disconnected" : "GitHub · reconnect required"
        }
        if serverUsageError != nil { return "GitHub · error" }
        if serverUsageSample == nil { return "GitHub · connecting" }
        if currentServerUsageSample == nil { return "GitHub · awaiting cycle" }
        if serverUsageIsStale { return "GitHub · stale" }
        return "GitHub · connected"
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

    func usdCostString(credits: Double) -> String {
        String(format: "$%.2f", credits / 100)
    }

    func audCostString(credits: Double) -> String {
        guard let usdToAUD else { return "A$—" }
        return String(format: "A$%.2f", credits / 100 * usdToAUD)
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

    var compactSpendProjection: SpendProjection? {
        var displayReport = currentMonthReport
        displayReport.totalCredits = compactTotalCredits
        return SpendProjection.compute(
            periodKind: .thisMonth, report: displayReport,
            monthlyBudgetUSD: monthlyBudget, now: Date(),
            calendar: Self.utcCalendar)
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
