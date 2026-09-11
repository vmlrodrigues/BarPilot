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

/// Serialises budget snapshots and rejects a late-arriving obsolete write.
/// This keeps the database aligned with the newest value even when a user
/// changes the field repeatedly while SQLite work is still queued.
private actor CycleBudgetWriter {
    private var newestRevision = 0

    func persist(
        revision: Int,
        resetDayMs: Int64,
        account: String?,
        budgetUSD: Double,
        updatedAtMs: Int64
    ) -> Bool {
        guard revision >= newestRevision else { return true }
        newestRevision = revision
        return CreditSampleStore.setCycleBudget(
            resetDayMs: resetDayMs,
            account: account,
            budgetUSD: budgetUSD,
            updatedAtMs: updatedAtMs
        )
    }
}

/// Serialises remote-cache mutations away from the UI actor. The generation
/// makes a late write harmless when sync is disabled or re-authorized while a
/// large snapshot is still being encoded and committed.
private actor RemoteSnapshotWriter {
    private var newestGeneration = Int.min

    func replaceAll(
        _ payloads: [MachineSyncPayload], generation: Int
    ) -> Bool {
        guard generation >= newestGeneration else { return false }
        newestGeneration = generation
        return RemoteStore.replaceAll(payloads)
    }

    func clear(generation: Int) {
        guard generation >= newestGeneration else { return }
        newestGeneration = generation
        RemoteStore.clear()
    }
}

enum RemoteCacheApplicationPolicy {
    static func shouldReapplyHistory(
        installedCurrentCache: Bool, hasLocalHistory: Bool
    ) -> Bool {
        installedCurrentCache && hasLocalHistory
    }

    static func verify() {
        precondition(shouldReapplyHistory(
            installedCurrentCache: true, hasLocalHistory: true
        ))
        precondition(!shouldReapplyHistory(
            installedCurrentCache: true, hasLocalHistory: false
        ))
        precondition(!shouldReapplyHistory(
            installedCurrentCache: false, hasLocalHistory: true
        ))
    }
}

enum BudgetPersistenceCompletionPolicy {
    static func shouldApply(
        revision: Int, latestRevision: Int,
        accountGeneration: Int, currentAccountGeneration: Int,
        account: String?, currentAccount: String?
    ) -> Bool {
        revision == latestRevision
            && accountGeneration == currentAccountGeneration
            && account == currentAccount
    }

    static func verify() {
        precondition(shouldApply(
            revision: 2, latestRevision: 2,
            accountGeneration: 3, currentAccountGeneration: 3,
            account: "same", currentAccount: "same"
        ))
        precondition(!shouldApply(
            revision: 2, latestRevision: 2,
            accountGeneration: 2, currentAccountGeneration: 3,
            account: "same", currentAccount: "same"
        ))
        precondition(!shouldApply(
            revision: 2, latestRevision: 2,
            accountGeneration: 3, currentAccountGeneration: 3,
            account: "old", currentAccount: "new"
        ))
    }
}

enum CreditCycleTransitionPolicy {
    private static let boundaryWindowMs: Int64 = 24 * 60 * 60 * 1_000

    /// GitHub can advance the reset boundary one response before its cumulative
    /// counter resets. Do not persist that ambiguous first response into the new
    /// cycle: if it is the old counter, it would become an artificial high-water
    /// mark for the entire month.
    static func needsConfirmation(
        previous: CreditSample?, current: CreditSample
    ) -> Bool {
        guard let previous else { return false }
        let observedAtMs = current.serverAtMs ?? current.capturedAtMs
        let distanceFromBoundary = abs(
            Double(observedAtMs) - Double(previous.resetAtMs)
        )
        return distanceFromBoundary <= Double(boundaryWindowMs)
            && CreditCycleSummary.dayStart(for: current.resetAtMs)
                > CreditCycleSummary.dayStart(for: previous.resetAtMs)
            && current.creditsUsed >= previous.creditsUsed
    }

    /// A response for the same new boundary confirms it only after the counter
    /// falls below the previous cycle's high-water mark. Mere movement is not
    /// enough: the stale old counter may still be increasing while fields settle.
    static func confirms(
        previous: CreditSample,
        pending: CreditSample,
        current: CreditSample
    ) -> Bool {
        CreditCycleSummary.dayStart(for: pending.resetAtMs)
            == CreditCycleSummary.dayStart(for: current.resetAtMs)
            && CreditCycleSummary.dayStart(for: current.resetAtMs)
                > CreditCycleSummary.dayStart(for: previous.resetAtMs)
            && current.creditsUsed < previous.creditsUsed
    }

    static func changed(previous: CreditSample?, current: CreditSample) -> Bool {
        guard let previous else { return false }
        return CreditCycleSummary.dayStart(for: previous.resetAtMs)
            != CreditCycleSummary.dayStart(for: current.resetAtMs)
    }

    static func rolledOver(
        previous: CreditSample?, current: CreditSample
    ) -> Bool {
        guard let previous else { return false }
        return CreditCycleSummary.dayStart(for: current.resetAtMs)
                > CreditCycleSummary.dayStart(for: previous.resetAtMs)
            && current.creditsUsed < previous.creditsUsed
    }

    static func verify() {
        let oldReset = Aggregator.utcMidnightMs("2030-01-01")
        let newReset = Aggregator.utcMidnightMs("2030-02-01")
        let previous = CreditSample(
            capturedAtMs: oldReset - 1, serverAtMs: nil,
            resetAtMs: oldReset, creditsUsed: 1_000
        )
        let staleCounter = CreditSample(
            capturedAtMs: oldReset, serverAtMs: nil,
            resetAtMs: newReset, creditsUsed: 1_000
        )
        precondition(changed(previous: previous, current: staleCounter))
        precondition(!rolledOver(previous: previous, current: staleCounter))
        precondition(needsConfirmation(
            previous: previous, current: staleCounter
        ))
        let delayedReconnect = CreditSample(
            capturedAtMs: oldReset + 3 * CreditCycleSummary.dayMs,
            serverAtMs: nil,
            resetAtMs: newReset,
            creditsUsed: 1_200
        )
        precondition(!needsConfirmation(
            previous: previous, current: delayedReconnect
        ))
        let resetCounter = CreditSample(
            capturedAtMs: oldReset + 1, serverAtMs: nil,
            resetAtMs: newReset, creditsUsed: 10
        )
        precondition(rolledOver(previous: previous, current: resetCounter))
        precondition(confirms(
            previous: previous, pending: staleCounter, current: resetCounter
        ))
        precondition(!needsConfirmation(
            previous: staleCounter, current: resetCounter
        ))
        let growingNewCounter = CreditSample(
            capturedAtMs: oldReset + 2, serverAtMs: nil,
            resetAtMs: newReset, creditsUsed: 1_001
        )
        precondition(!confirms(
            previous: previous,
            pending: staleCounter,
            current: growingNewCounter
        ))
        let zeroBoundary = CreditSample(
            capturedAtMs: oldReset + 3, serverAtMs: nil,
            resetAtMs: newReset, creditsUsed: 0
        )
        precondition(confirms(
            previous: previous,
            pending: zeroBoundary,
            current: zeroBoundary
        ))
    }
}

enum CreditHistoryMergePolicy {
    /// A database read can begin before a target edit and finish after it. Merge
    /// its snapshot with the live values so that late reads cannot roll back an
    /// already-persisted edit in memory or in the next sync payload.
    static func cycleBudgets(
        stored: [SyncedCycleBudget], live: [SyncedCycleBudget]
    ) -> [SyncedCycleBudget] {
        SyncAggregate.compactCycleBudgets(stored + live)
    }

    static func verify() {
        let day = Aggregator.utcMidnightMs("2030-02-01")
        let stale = SyncedCycleBudget(
            resetDayMs: day, budgetUSD: 100, updatedAtMs: day - 2
        )
        let edited = SyncedCycleBudget(
            resetDayMs: day, budgetUSD: 200, updatedAtMs: day - 1
        )
        precondition(cycleBudgets(
            stored: [stale], live: [edited]
        ).first?.budgetUSD == 200)
    }
}

/// Loading policy shared by launch and sync. Account usage can be disconnected
/// while multi-Mac sync deliberately remains enabled, so UI connection state
/// must never decide whether a complete counter history is safe to publish.
enum CreditHistoryLoadPolicy {
    static func shouldLoad(
        serverUsageEnabled: Bool,
        syncEnabled: Bool,
        accountFingerprint: String?
    ) -> Bool {
        serverUsageEnabled || (syncEnabled && accountFingerprint != nil)
    }

    static func mustLoadBeforeSync(accountFingerprint: String?) -> Bool {
        accountFingerprint != nil
    }

    /// An enabled account connection with no verified identity is transient: it
    /// commonly occurs while an older install is resolving its fingerprint.
    /// Publishing then would replace this Mac's remote counter history with a
    /// payload whose account fields are deliberately nil.
    static func canPublish(
        serverUsageEnabled: Bool,
        accountFingerprint: String?
    ) -> Bool {
        !serverUsageEnabled || accountFingerprint != nil
    }

    static func verify() {
        precondition(shouldLoad(
            serverUsageEnabled: true,
            syncEnabled: false,
            accountFingerprint: nil
        ))
        precondition(shouldLoad(
            serverUsageEnabled: false,
            syncEnabled: true,
            accountFingerprint: "known-account"
        ), "disconnected account usage must not permit a partial sync upload")
        precondition(!shouldLoad(
            serverUsageEnabled: false,
            syncEnabled: true,
            accountFingerprint: nil
        ))
        precondition(mustLoadBeforeSync(accountFingerprint: "known-account"))
        precondition(!mustLoadBeforeSync(accountFingerprint: nil))
        precondition(canPublish(
            serverUsageEnabled: true,
            accountFingerprint: "known-account"
        ))
        precondition(!canPublish(
            serverUsageEnabled: true,
            accountFingerprint: nil
        ), "sync must wait while an enabled account's identity is unresolved")
        precondition(canPublish(
            serverUsageEnabled: false,
            accountFingerprint: nil
        ))
    }
}

/// Upload policy kept pure so the simultaneous first-enable race is covered by
/// deterministic verification rather than requiring two live GitHub accounts.
enum SyncPublishPolicy {
    static func shouldPush(
        force: Bool,
        fingerprint: String,
        needsRetry: Bool,
        remoteFingerprint: String?
    ) -> Bool {
        force || needsRetry || fingerprint != remoteFingerprint
    }

    static func verify() {
        precondition(shouldPush(
            force: false, fingerprint: "same", needsRetry: false,
            remoteFingerprint: nil
        ), "a Mac missing from the canonical Gist must republish after a creation race")
        precondition(!shouldPush(
            force: false, fingerprint: "same", needsRetry: false,
            remoteFingerprint: "same"
        ), "an unchanged published payload must not upload every minute")
        precondition(shouldPush(
            force: false, fingerprint: "current", needsRetry: false,
            remoteFingerprint: "stale"
        ), "an existing but stale self file must be repaired")
    }
}

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
    @Published var monthlyBudget: Double {
        didSet { persistBudget(previousValue: oldValue) }
    }
    @Published private(set) var budgetPersistenceError: String?
    /// Project the month-end forecast across working days only. Off by default,
    /// so an existing install's forecast does not move on upgrade.
    @Published var excludeWeekendsFromProjection: Bool {
        didSet { UserDefaults.standard.set(excludeWeekendsFromProjection, forKey: Self.excludeWeekendsKey) }
    }

    /// Currency the UI displays costs in. Internally everything stays USD.
    @Published var displayCurrency: Currency { didSet { persistCurrency(); recompute() } }
    /// Latest USD→AUD rate (nil until fetched/cached); published so the UI updates.
    @Published private(set) var usdToAUD: Double?
    private var exchangeRateSnapshot: ExchangeRateSnapshot?

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
    /// Changes whenever sync is enabled or disabled. Account-generation,
    /// connection-state and fingerprint snapshots independently invalidate work
    /// when the account connection changes during a network request.
    private var syncGeneration = 0
    private struct ActiveSyncRun {
        let id: UUID
        let generation: Int
        let serverUsageGeneration: Int
        let serverUsageEnabled: Bool
        let accountFingerprint: String?
        let task: Task<Void, Never>
    }
    private var activeSyncRun: ActiveSyncRun?
    private var syncPushBlocked = false  // set after a permanent (403/401) failure; cleared on re-enable
    private var syncPushNeedsRetry = false
    /// Decoded once and then replaced from successful pulls. Never reopen and
    /// JSON-decode the remote SQLite cache during a main-actor recomputation.
    private var remoteAggregates: [MachineSyncPayload] = []
    private var hasLoadedRemoteAggregateCache = false
    /// Resolved once whenever source state changes. A payload can contain several
    /// thousand samples, so SwiftUI accessors must not rescan every peer on each
    /// body evaluation.
    private var resolvedCurrentCreditObservation: CurrentCreditObservation?

    /// Primary account-level credit connection, independent from gist sync.
    @Published private(set) var serverUsageEnabled = false
    @Published private(set) var serverUsageSample: CreditSample?
    @Published private(set) var serverUsageError: String?
    @Published private(set) var isConnectingServerUsage = false
    /// The in-flight device-flow poll, retained so the user can cancel it.
    private var serverUsageConnectTask: Task<Void, Never>?
    /// Cached in `recompute()` — see `updateCreditCycleView()`.
    @Published private(set) var creditTimeline: CreditTimeline = .empty
    /// Completed-cycle rows retained beside the live cycle so Recent activity
    /// remains a true rolling history when a new billing cycle begins.
    @Published private(set) var previousCreditActivity: [ObservedDayCredits] = []
    @Published private(set) var creditCycles: [CreditCycleSummary] = []
    @Published private(set) var selectedCreditCycleDayMs: Int64?
    @Published private(set) var isLoadingCreditCycle = false
    @Published private(set) var selectedHistoricalTotalCredits: Double?
    @Published private(set) var selectedHistoricalBudgetUSD: Double?
    @Published private(set) var budgetMigrationCycleDayMs: Int64?
    @Published private(set) var spendCalendarDailyCredits: [String: Double] = [:]
    @Published private(set) var spendCalendarMonthKey: String?
    @Published private(set) var isLoadingSpendCalendar = false
    @Published private(set) var counterSyncMachineCount = 1
    private var creditSamples: [CreditSample] = []
    /// Local-only compacted history published by this Mac. Remote observations
    /// are deliberately never copied here, which prevents sync feedback loops.
    private var syncCreditSamples: [CreditSample] = []
    /// Local-only cycle targets published beside the observations. Remote
    /// targets are resolved for display but never copied into this collection.
    private var syncCycleBudgets: [SyncedCycleBudget] = []
    /// One-pass local history snapshot. Routine one-minute sync pulls recombine
    /// this with the remote cache in memory instead of rescanning SQLite.
    private var localCreditHistory: CreditSampleStore.HistorySnapshot?
    private var selectedCreditCycleSamples: [CreditSample] = []
    private var serverUsageAccountFingerprint: String?
    private var serverUsageGeneration = 0
    private var creditCycleLoadGeneration = 0
    private var spendCalendarLoadGeneration = 0
    private let cycleBudgetWriter = CycleBudgetWriter()
    private let remoteSnapshotWriter = RemoteSnapshotWriter()
    private var budgetWriteRevision = 0
    /// True user-edit time for the active target. Routine counter observations
    /// reuse this value instead of pretending that each poll changed the budget.
    private var budgetUpdatedAtMs: Int64
    private var budgetPersistenceTask: Task<Void, Never>?
    private struct ActiveServerRefresh {
        let id: UUID
        let startedAt: Date
        let task: Task<ServerUsageRefreshOutcome, Never>
    }
    private var activeServerRefreshes: [Int: ActiveServerRefresh] = [:]
    private struct ActiveCreditHistoryLoad {
        let id: UUID
        let generation: Int
        let account: String?
        let task: Task<CreditSampleStore.HistorySnapshot?, Never>
    }
    private var activeCreditHistoryLoad: ActiveCreditHistoryLoad?
    /// An ambiguous first response after GitHub advances the reset boundary.
    /// It remains in memory only and cannot seed the new cycle's high-water mark
    /// until another response confirms the transition.
    private var pendingCycleTransitionSample: CreditSample?

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
    private static let budgetUpdatedAtKey = "monthlyBudgetUpdatedAtMs"
    private static let excludeWeekendsKey = "excludeWeekendsFromProjection"
    private static let currencyKey = "displayCurrency"
    private static let rateKey = "usdToAUDRate"
    private static let rateDateKey = "usdToAUDRateDate"
    private static let rateProviderUpdatedKey = "usdToAUDProviderUpdatedAt"
    private static let rateProviderNextKey = "usdToAUDProviderNextUpdateAt"
    private static let syncKey = "multiMachineSyncEnabled"
    private static let serverUsageKey = "serverCreditUsageEnabled"
    private static let serverUsageDisconnectedKey = "serverCreditUsageExplicitlyDisconnected"
    private static let serverUsageAccountKey = "serverCreditUsageAccountFingerprint"
    private static let creditStoreIdentityKey = "creditHistoryStoreIdentity"
    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    /// Average days per month (365.25 / 12) — used to convert the monthly
    /// budget into a stable per-day rate for any selected range.
    private static let avgDaysPerMonth = 30.4375
    /// True only when the database identity differs from the one seen on the
    /// prior launch. Normal retention must not resurrect pruned remote rows.
    private var needsSelfHistoryRecovery = false
    private var creditStoreIdentity: String?

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.periodKey)
        periodKind = PeriodKind(rawValue: saved ?? "") ?? .thisMonth

        if UserDefaults.standard.object(forKey: Self.budgetKey) != nil {
            let stored = UserDefaults.standard.double(forKey: Self.budgetKey)
            if case let .ok(value) = BudgetInput.parse(String(stored)) {
                monthlyBudget = value
            } else {
                monthlyBudget = 0
            }
        } else {
            monthlyBudget = 150  // ≈ $5/day default
        }
        let storedBudgetUpdatedAt = (UserDefaults.standard.object(
            forKey: Self.budgetUpdatedAtKey
        ) as? NSNumber)?.int64Value ?? 0
        budgetUpdatedAtMs = storedBudgetUpdatedAt > 0 ? storedBudgetUpdatedAt
            : Int64(Date().timeIntervalSince1970 * 1_000)
        UserDefaults.standard.set(
            budgetUpdatedAtMs, forKey: Self.budgetUpdatedAtKey
        )

        displayCurrency = Currency(rawValue: UserDefaults.standard.string(forKey: Self.currencyKey) ?? "") ?? .usd
        excludeWeekendsFromProjection = UserDefaults.standard.bool(forKey: Self.excludeWeekendsKey)  // default false
        let cachedRate = UserDefaults.standard.double(forKey: Self.rateKey)
        usdToAUD = cachedRate > 0 ? cachedRate : nil
        let providerUpdated = (UserDefaults.standard.object(
            forKey: Self.rateProviderUpdatedKey
        ) as? NSNumber)?.int64Value ?? 0
        let providerNext = (UserDefaults.standard.object(
            forKey: Self.rateProviderNextKey
        ) as? NSNumber)?.int64Value ?? 0
        let cachedSnapshot = ExchangeRateSnapshot(
            usdToAUD: cachedRate,
            providerUpdatedAtUnix: providerUpdated,
            providerNextUpdateAtUnix: providerNext > 0 ? providerNext : nil
        )
        exchangeRateSnapshot = cachedSnapshot.isValid() ? cachedSnapshot : nil

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
        let previousStoreIdentity = UserDefaults.standard.string(
            forKey: Self.creditStoreIdentityKey
        )
        let currentStoreIdentity = CreditSampleStore.storeIdentity()
        creditStoreIdentity = currentStoreIdentity
        needsSelfHistoryRecovery = previousStoreIdentity != nil
            && currentStoreIdentity != nil
            && previousStoreIdentity != currentStoreIdentity
        // Do not acknowledge a replacement database until remote recovery has
        // succeeded. A crash or network failure must retry on the next launch.
        if !needsSelfHistoryRecovery, let currentStoreIdentity {
            UserDefaults.standard.set(
                currentStoreIdentity, forKey: Self.creditStoreIdentityKey
            )
        }
        // Hydrate from the cycle itself. Keying this off the baseline pointer
        // alone meant a missing or advanced pointer left the dashboard blank
        // even though the samples were sitting in the database.
        let latest = CreditSampleStore.latest(account: serverUsageAccountFingerprint)
        if let latest {
            creditCycles = [CreditCycleSummary(latestSample: latest)]
            serverUsageSample = latest
            creditSamples = Self.loadCycleSamples(
                resetAtMs: latest.resetAtMs, account: serverUsageAccountFingerprint
            )
            syncCreditSamples = creditSamples
            selectedCreditCycleSamples = creditSamples
        }
        refreshCurrentCreditObservation()

        Task { await reload() }
        Task { await refreshCreditCycles() }
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
        let loadRemoteCache = syncEnabled && !hasLoadedRemoteAggregateCache
        let remoteCacheGeneration = syncGeneration
        let machineId = Self.machineId
        let loaded = await Task.detached(priority: .utility) {
            let usage = DataSources.loadAll()
            let remotes: [MachineSyncPayload]?
            let remoteCacheReadFailed: Bool
            if loadRemoteCache {
                if let snapshot = RemoteStore.load() {
                    remotes = snapshot.filter { $0.machineId != machineId }
                    remoteCacheReadFailed = false
                } else {
                    remotes = nil
                    remoteCacheReadFailed = true
                }
            } else {
                remotes = nil
                remoteCacheReadFailed = false
            }
            return (
                usage: usage,
                remotes: remotes,
                remoteCacheReadFailed: remoteCacheReadFailed
            )
        }.value
        let loadMs = Int(Date().timeIntervalSince(t0) * 1000)
        allRecords = loaded.usage.records
        status = loaded.usage.status
        var installedCurrentRemoteCache = false
        if let remotes = loaded.remotes, syncEnabled,
           syncGeneration == remoteCacheGeneration {
            remoteAggregates = remotes
            hasLoadedRemoteAggregateCache = true
            installedCurrentRemoteCache = true
        } else if loaded.remoteCacheReadFailed, syncEnabled,
                  syncGeneration == remoteCacheGeneration {
            syncError = "Saved multi-Mac usage couldn’t be read. BarPilot kept its current view and will retry."
        }
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

        if RemoteCacheApplicationPolicy.shouldReapplyHistory(
            installedCurrentCache: installedCurrentRemoteCache,
            hasLocalHistory: localCreditHistory != nil
        ), let localCreditHistory {
            // The local-history task may have completed before the slower usage
            // and remote-cache read. Reapply it now so cached peer-only cycles
            // are available even when the following network sync is offline.
            applyCreditHistory(localCreditHistory)
        } else {
            recompute()
        }
        // Rotating support log (#24): load cost + what the reload actually computed
        // vs the menu title it set — also the #13 display-vs-data drift diagnostic.
        DiagLog.write("reload: \(loadMs)ms · scanned \(DiagLog.humanBytes(status.jsonlBytesScanned)) · +\(status.newRecords) new · \(allRecords.count) cached · period \(periodKind.rawValue) · menu \(menuBarTitle.hasPrefix("⚠︎") ? "warn" : "ok")\(menuBarTitle.hasSuffix(costString(credits: currentCompactTotalCredits)) ? "" : " · DRIFT")")
        if syncEnabled { Task { await self.syncNow() } }   // background push/pull
        if serverUsageEnabled { Task { await self.refreshServerUsage() } }
    }

    // -----------------------------------------------------------------------
    // Aggregation (cheap; runs on the main actor)
    // -----------------------------------------------------------------------

    private func recompute() {
        refreshCurrentCreditObservation()
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
        updateCreditCycleView()
        counterSyncMachineCount = countCounterSyncMachines()
        // The menu-bar figure must signal when it is a local fallback rather than
        // the authoritative GitHub total. Reuse the existing warning glyph.
        let cost = costString(credits: currentCompactTotalCredits)
        let needsWarning = !serverUsageEnabled || serverUsageStatusIsError
            || currentServerUsageSample == nil || serverUsageIsStale
            || showExporterWarning
        menuBarTitle = needsWarning ? "⚠︎ " + cost : cost
    }

    /// Other machines' payloads from the last successful pull. Excludes this
    /// machine's own id defensively.
    private func currentRemoteAggregates() -> [MachineSyncPayload] {
        remoteAggregates
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
    /// Turn sync on with a freshly-obtained token: persist it, enable, and do an
    /// initial push + pull. Returns the machine count now contributing.
    func enableSyncWith(token: String) async -> Int {
        guard Keychain.saveToken(token) else {
            syncError = "The sync credential couldn’t be saved securely."
            return syncMachineCount
        }
        syncPushBlocked = false
        syncPushNeedsRetry = false
        syncError = nil   // fresh start (clears a prior permanent-error block)
        syncLogin = nil   // the freshly authorized token may be another account
        syncGeneration += 1
        activeSyncRun?.task.cancel()
        activeSyncRun = nil
        syncEnabled = true          // didSet persists + recomputes (local only until pull lands)
        await syncNow(force: true)
        return syncMachineCount
    }

    /// Turn sync off. Local raw cache untouched; remote data cache cleared and
    /// the token removed. Does NOT delete the remote gist (offered separately).
    func disableSync() {
        syncGeneration += 1
        let generation = syncGeneration
        activeSyncRun?.task.cancel()
        activeSyncRun = nil
        syncEnabled = false         // didSet persists + recomputes (back to local-only)
        let removed = Keychain.deleteToken()
        let remoteSnapshotWriter = remoteSnapshotWriter
        Task {
            await remoteSnapshotWriter.clear(generation: generation)
        }
        remoteAggregates = []
        hasLoadedRemoteAggregateCache = true
        syncLogin = nil
        syncError = removed
            ? nil
            : "Sync is off, but macOS couldn’t remove its saved credential."
        syncPushBlocked = false
        syncPushNeedsRetry = false
        if let localCreditHistory {
            applyCreditHistory(localCreditHistory)
        } else {
            Task { await refreshCreditCycles() }
        }
    }

    /// Push this machine's payload (only if it changed) and pull the others
    /// into the RemoteStore, then recompute. Safe no-op when off / no token.
    func syncNow(force: Bool = false) async {
        let generation = syncGeneration
        let accountGeneration = serverUsageGeneration
        let accountUsageEnabled = serverUsageEnabled
        let accountFingerprint = serverUsageAccountFingerprint
        guard syncEnabled, !isConnectingServerUsage else { return }
        guard let token = Keychain.token() else {
            syncError = "Sync authorization is missing. Turn sync off and re-enable it to reconnect."
            return
        }
        if let active = activeSyncRun {
            if active.generation == generation,
               active.serverUsageGeneration == accountGeneration,
               active.serverUsageEnabled == accountUsageEnabled,
               active.accountFingerprint == accountFingerprint {
                await active.task.value
                return
            }
            active.task.cancel()
            activeSyncRun = nil
        }
        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performSync(
                force: force, token: token, generation: generation,
                serverUsageGeneration: accountGeneration,
                serverUsageEnabled: accountUsageEnabled,
                accountFingerprint: accountFingerprint
            )
        }
        activeSyncRun = ActiveSyncRun(
            id: id,
            generation: generation,
            serverUsageGeneration: accountGeneration,
            serverUsageEnabled: accountUsageEnabled,
            accountFingerprint: accountFingerprint,
            task: task
        )
        await task.value
        if activeSyncRun?.id == id {
            activeSyncRun = nil
        }
    }

    private func performSync(
        force: Bool,
        token: String,
        generation: Int,
        serverUsageGeneration accountGeneration: Int,
        serverUsageEnabled accountUsageEnabled: Bool,
        accountFingerprint: String?
    ) async {
        guard syncContextIsCurrent(
            generation: generation,
            serverUsageGeneration: accountGeneration,
            serverUsageEnabled: accountUsageEnabled,
            accountFingerprint: accountFingerprint
        ),
              !Task.isCancelled else { return }
        // Never overwrite this Mac's complete gist history with the one cycle
        // hydrated synchronously during launch. A failed history read pauses the
        // push rather than publishing a destructive partial snapshot.
        if CreditHistoryLoadPolicy.mustLoadBeforeSync(
            accountFingerprint: accountFingerprint
        ),
           localCreditHistory == nil {
            await refreshCreditCycles()
            guard syncContextIsCurrent(
                generation: generation,
                serverUsageGeneration: accountGeneration,
                serverUsageEnabled: accountUsageEnabled,
                accountFingerprint: accountFingerprint
            ),
                  !Task.isCancelled else { return }
            guard localCreditHistory != nil else {
                syncError = "Saved usage history couldn’t be read, so sync is paused to protect the remote copy."
                return
            }
        }

        var backend = GitHubBackend(token: token, cacheIdentity: syncLogin)
        if syncPushBlocked { return }
        if syncLogin == nil {
            let login = await backend.currentLogin()
            guard syncContextIsCurrent(
                generation: generation,
                serverUsageGeneration: accountGeneration,
                serverUsageEnabled: accountUsageEnabled,
                accountFingerprint: accountFingerprint
            ),
                  !Task.isCancelled else { return }
            syncLogin = login
            backend = GitHubBackend(token: token, cacheIdentity: login)
        }

        // Read and validate the complete Gist before writing anything. Besides
        // producing the peer snapshot, this protects a newer-schema self file
        // during downgrade and recovers this machine's own observations if its
        // local database was recreated while UserDefaults retained the machine id.
        let snapshot: [MachineSyncPayload]
        do {
            snapshot = try await backend.pullAll()
        } catch {
            guard syncContextIsCurrent(
                generation: generation,
                serverUsageGeneration: accountGeneration,
                serverUsageEnabled: accountUsageEnabled,
                accountFingerprint: accountFingerprint
            ), !Task.isCancelled else { return }
            syncError = Self.syncPullErrorMessage(error)
            NSLog("BarPilot sync: preflight pull failed (\(error))")
            return
        }
        guard syncContextIsCurrent(
            generation: generation,
            serverUsageGeneration: accountGeneration,
            serverUsageEnabled: accountUsageEnabled,
            accountFingerprint: accountFingerprint
        ), !Task.isCancelled else { return }
        let existingSelf = snapshot
            .filter { $0.machineId == Self.machineId }
            .max { $0.updatedAt < $1.updatedAt }
        let remotes = snapshot.filter { $0.machineId != Self.machineId }

        let projected = SyncAggregate.project(
            allRecords, creditSamples: syncCreditSamples,
            cycleBudgets: syncCycleBudgets,
            accountFingerprint: accountFingerprint,
            exchangeRateSnapshot: exchangeRateSnapshot,
            machineId: Self.machineId, label: nil, updatedAt: Self.nowISO()
        )
        let mine = SyncAggregate.reconciledSelfPayload(
            local: projected, remote: existingSelf,
            recoverRemoteHistory: needsSelfHistoryRecovery
        )

        // Put recovered self observations back into SQLite, not just into the
        // outgoing payload, so navigation and the dashboard survive subsequent
        // offline launches too. A write failure does not endanger the Gist—the
        // reconciled outgoing payload still contains its previous observations.
        var recoveryPersistFailed = false
        if let accountFingerprint,
           mine.accountFingerprint == accountFingerprint {
            let recovered = (mine.creditSamples ?? []).map(\.creditSample)
            let recoveredBudgets = mine.cycleBudgets ?? []
            let compactLocal = SyncAggregate.compactCreditSamples(syncCreditSamples)
            let compactLocalBudgets = SyncAggregate.compactCycleBudgets(
                syncCycleBudgets
            )
            if recovered != compactLocal
                || recoveredBudgets != compactLocalBudgets {
                let saved = await Task.detached(priority: .utility) {
                    CreditSampleStore.saveAll(
                        recovered, cycleBudgets: recoveredBudgets,
                        account: accountFingerprint
                    )
                }.value
                guard syncContextIsCurrent(
                    generation: generation,
                    serverUsageGeneration: accountGeneration,
                    serverUsageEnabled: accountUsageEnabled,
                    accountFingerprint: accountFingerprint
                ), !Task.isCancelled else { return }
                if saved {
                    let newestRecovered = recovered.max {
                        let lhs = $0.serverAtMs ?? $0.capturedAtMs
                        let rhs = $1.serverAtMs ?? $1.capturedAtMs
                        return lhs < rhs
                    }
                    let recoveredAt = newestRecovered.map {
                        $0.serverAtMs ?? $0.capturedAtMs
                    } ?? .min
                    let currentAt = serverUsageSample.map {
                        $0.serverAtMs ?? $0.capturedAtMs
                    } ?? .min
                    if let newestRecovered, recoveredAt > currentAt {
                        serverUsageSample = newestRecovered
                        creditSamples = Self.loadCycleSamples(
                            resetAtMs: newestRecovered.resetAtMs,
                            account: accountFingerprint
                        )
                        if selectedCreditCycleDayMs == nil {
                            selectedCreditCycleSamples = creditSamples
                        }
                    }
                    localCreditHistory = nil
                    await refreshCreditCycles()
                    completeSelfHistoryRecovery()
                } else {
                    recoveryPersistFailed = true
                    syncError = "Synced usage was recovered, but couldn’t be restored to local storage. BarPilot will retry."
                }
            } else {
                completeSelfHistoryRecovery()
            }
        }
        guard let fp = SyncAggregate.contentFingerprint(mine) else {
            syncPushNeedsRetry = true
            syncError = "Sync data couldn’t be prepared safely. BarPilot will retry."
            return
        }
        let publishDeferredForIdentity = !CreditHistoryLoadPolicy.canPublish(
            serverUsageEnabled: accountUsageEnabled,
            accountFingerprint: accountFingerprint
        )
        if publishDeferredForIdentity {
            syncError = "Sync is waiting for BarPilot to verify the connected GitHub account."
        }
        let shouldPush = SyncPublishPolicy.shouldPush(
            force: force,
            fingerprint: fp,
            needsRetry: syncPushNeedsRetry,
            remoteFingerprint: existingSelf.flatMap(
                SyncAggregate.contentFingerprint
            )
        )
        if !publishDeferredForIdentity && !syncPushBlocked && shouldPush {
            do {
                try await backend.push(mine)
                guard syncContextIsCurrent(
                    generation: generation,
                    serverUsageGeneration: accountGeneration,
                    serverUsageEnabled: accountUsageEnabled,
                    accountFingerprint: accountFingerprint
                ),
                      !Task.isCancelled else { return }
                syncPushNeedsRetry = false
            } catch {
                guard syncContextIsCurrent(
                    generation: generation,
                    serverUsageGeneration: accountGeneration,
                    serverUsageEnabled: accountUsageEnabled,
                    accountFingerprint: accountFingerprint
                ),
                      !Task.isCancelled else { return }
                syncPushNeedsRetry = true
                syncError = Self.syncErrorMessage(error)
                if (error as? SyncError)?.isPermanent == true { syncPushBlocked = true }   // stop hammering GitHub on a permanent failure
                NSLog("BarPilot sync: push failed (\(error))")
            }
        }
        if syncPushBlocked { return }
        // A successful pull is the authoritative complete peer snapshot. This
        // includes an empty list: retaining absent peers would keep deleted or
        // disconnected Macs contributing forever. Failed pulls throw above and
        // preserve the last-good cache instead.
        let cacheSaved = await remoteSnapshotWriter.replaceAll(
            remotes, generation: generation
        )
        guard syncContextIsCurrent(
            generation: generation,
            serverUsageGeneration: accountGeneration,
            serverUsageEnabled: accountUsageEnabled,
            accountFingerprint: accountFingerprint
        ), !Task.isCancelled else { return }
        guard cacheSaved else {
            syncError = "Multi-Mac usage downloaded, but its local cache couldn’t be updated. BarPilot will retry."
            DiagLog.write("sync: remote snapshot persist failed")
            return
        }
        remoteAggregates = remotes
        hasLoadedRemoteAggregateCache = true
        adoptNewestExchangeRate(from: remoteAggregates)
        if let localCreditHistory {
            applyCreditHistory(localCreditHistory)
        } else {
            await refreshCreditCycles()
        }
        if !syncPushNeedsRetry && !publishDeferredForIdentity
            && !recoveryPersistFailed {
            syncError = nil
        }
    }

    private func syncContextIsCurrent(
        generation: Int,
        serverUsageGeneration accountGeneration: Int,
        serverUsageEnabled accountUsageEnabled: Bool,
        accountFingerprint: String?
    ) -> Bool {
        syncEnabled
            && syncGeneration == generation
            && serverUsageGeneration == accountGeneration
            && serverUsageEnabled == accountUsageEnabled
            && serverUsageAccountFingerprint == accountFingerprint
    }

    private func completeSelfHistoryRecovery() {
        needsSelfHistoryRecovery = false
        if let creditStoreIdentity {
            UserDefaults.standard.set(
                creditStoreIdentity, forKey: Self.creditStoreIdentityKey
            )
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

    private static func syncPullErrorMessage(_ error: Error) -> String {
        switch error as? SyncError {
        case .unauthorized:
            return "Sync authorization is no longer valid. Turn sync off and re-enable."
        case .forbidden:
            return "GitHub wouldn’t allow BarPilot to download the sync data."
        case .encoding:
            return "GitHub sync data couldn’t be read. BarPilot kept the last good local copy and will retry."
        default:
            return "Can’t download multi-Mac usage from GitHub right now — will keep retrying."
        }
    }

    // -----------------------------------------------------------------------
    // Server-authoritative account usage (#33)
    // -----------------------------------------------------------------------

    /// Enable account usage with its own credential, then take the opening
    /// baseline. Existing gist-sync authorization is deliberately unaffected.
    func enableServerUsageWith(token: String) async -> Bool {
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
        let budgetUSD = monthlyBudget
        let budgetChangedAtMs = budgetUpdatedAtMs
        let previous = serverUsageAccountFingerprint == fingerprint
            ? serverUsageSample : nil
        let transitionNeedsConfirmation = CreditCycleTransitionPolicy
            .needsConfirmation(previous: previous, current: sample)

        guard CreditUsageKeychain.saveToken(token) else {
            serverUsageError = "GitHub authenticated, but the credential couldn’t be saved securely."
            recompute()
            return false
        }
        if transitionNeedsConfirmation {
            return finishServerUsageConnectionAwaitingTransition(
                sample: sample, fingerprint: fingerprint
            )
        }
        let saved = await Task.detached(priority: .utility) {
            // Claim pre-attribution rows before the first attributed write, so
            // the opening sample and the existing history share one account.
            CreditSampleStore.adoptUnattributed(account: fingerprint)
            let didSave = CreditSampleStore.save(
                sample, account: fingerprint, budgetUSD: budgetUSD,
                budgetUpdatedAtMs: budgetChangedAtMs
            )
            return (
                didSave,
                CreditSampleStore.cycles(account: fingerprint)
            )
        }.value
        guard generation == serverUsageGeneration else {
            _ = CreditUsageKeychain.deleteToken()
            return false
        }
        guard saved.0 else {
            // Authentication succeeded and the credential is stored; only the
            // opening sample failed to persist. Discarding the token here would
            // bounce the user back to "Connect GitHub" at the end of a device
            // flow they completed correctly. Fall through and connect: the
            // sample is still shown from memory and the next poll re-saves it.
            DiagLog.write("connect: opening sample not persisted; connecting anyway")
            return finishServerUsageConnection(
                sample: sample, fingerprint: fingerprint, cycles: saved.1
            )
        }
        return finishServerUsageConnection(
            sample: sample, fingerprint: fingerprint, cycles: saved.1
        )
    }

    /// Reconnect without persisting a boundary response that still carries the
    /// previous cycle's counter. The normal poll path will accept it only after
    /// GitHub supplies a value below that prior high-water mark.
    private func finishServerUsageConnectionAwaitingTransition(
        sample: CreditSample, fingerprint: String
    ) -> Bool {
        resetCreditCycleSelection()
        resetSpendCalendar()
        pendingCycleTransitionSample = sample
        serverUsageAccountFingerprint = fingerprint
        UserDefaults.standard.set(fingerprint, forKey: Self.serverUsageAccountKey)
        serverUsageEnabled = true
        UserDefaults.standard.set(true, forKey: Self.serverUsageKey)
        UserDefaults.standard.set(false, forKey: Self.serverUsageDisconnectedKey)
        serverUsageError = nil
        recompute()
        Task { await refreshCreditCycles() }
        Task { await refreshServerUsage() }
        return true
    }

    /// Commit a verified connection. Shared so a failed *local* persist takes
    /// exactly the same path as a successful one.
    private func finishServerUsageConnection(
        sample: CreditSample, fingerprint: String,
        cycles: [CreditCycleSummary]
    ) -> Bool {
        let accountChanged = serverUsageAccountFingerprint != fingerprint
        resetCreditCycleSelection()
        resetSpendCalendar()
        pendingCycleTransitionSample = nil
        serverUsageAccountFingerprint = fingerprint
        if accountChanged {
            syncCycleBudgets = []
            localCreditHistory = nil
        }
        UserDefaults.standard.set(fingerprint, forKey: Self.serverUsageAccountKey)
        serverUsageEnabled = true
        UserDefaults.standard.set(true, forKey: Self.serverUsageKey)
        UserDefaults.standard.set(false, forKey: Self.serverUsageDisconnectedKey)
        // Reconnecting must not cost the user their history. This used to reset
        // to a single sample whenever the fingerprint differed from the stored
        // one — which fires for the *same* account whenever the derivation
        // changes, silently hiding the cycle. Attribution now lives on the rows,
        // so a genuinely different account is excluded by the query instead.
        creditSamples = Self.loadCycleSamples(resetAtMs: sample.resetAtMs, account: fingerprint)
        if !creditSamples.contains(sample) { creditSamples.append(sample) }
        syncCreditSamples = creditSamples
        upsertLocalCycleBudget(
            resetDayMs: CreditCycleSummary.dayStart(for: sample.resetAtMs),
            budgetUSD: monthlyBudget, updatedAtMs: budgetUpdatedAtMs
        )
        localCreditHistory = nil
        creditCycles = cycles
        upsertCreditCycle(sample)
        selectedCreditCycleSamples = creditSamples
        serverUsageSample = sample
        serverUsageError = nil
        recompute()
        Task { await refreshCreditCycles() }
        return true
    }

    private func resetCreditCycleSelection() {
        creditCycleLoadGeneration += 1
        selectedCreditCycleDayMs = nil
        selectedCreditCycleSamples = creditSamples
        selectedHistoricalTotalCredits = nil
        selectedHistoricalBudgetUSD = nil
        isLoadingCreditCycle = false
    }

    private func resetSpendCalendar() {
        spendCalendarLoadGeneration += 1
        spendCalendarDailyCredits = [:]
        spendCalendarMonthKey = nil
        isLoadingSpendCalendar = false
    }

    private func upsertCreditCycle(_ sample: CreditSample) {
        let summary = CreditCycleSummary(latestSample: sample)
        if let index = creditCycles.firstIndex(where: {
            $0.resetDayMs == summary.resetDayMs
        }) {
            if sample.capturedAtMs >= creditCycles[index].latestSample.capturedAtMs {
                creditCycles[index] = summary
            }
        } else {
            creditCycles.append(summary)
        }
        creditCycles.sort { $0.resetDayMs > $1.resetDayMs }
    }

    private func refreshCreditCycles() async {
        guard CreditHistoryLoadPolicy.shouldLoad(
            serverUsageEnabled: serverUsageEnabled,
            syncEnabled: syncEnabled,
            accountFingerprint: serverUsageAccountFingerprint
        ) else { return }
        let account = serverUsageAccountFingerprint
        let generation = serverUsageGeneration
        let active: ActiveCreditHistoryLoad
        if let existing = activeCreditHistoryLoad,
           existing.generation == generation,
           existing.account == account {
            active = existing
        } else {
            let created = ActiveCreditHistoryLoad(
                id: UUID(),
                generation: generation,
                account: account,
                task: Task.detached(priority: .utility) {
                    CreditSampleStore.compactedHistory(account: account)
                }
            )
            activeCreditHistoryLoad = created
            active = created
        }
        let stored = await active.task.value
        if activeCreditHistoryLoad?.id == active.id {
            activeCreditHistoryLoad = nil
        }
        guard CreditHistoryLoadPolicy.shouldLoad(
            serverUsageEnabled: serverUsageEnabled,
            syncEnabled: syncEnabled,
            accountFingerprint: serverUsageAccountFingerprint
        ), generation == serverUsageGeneration,
              account == serverUsageAccountFingerprint else {
            return
        }
        guard let stored else {
            DiagLog.write("credit history: compacted load failed")
            return
        }
        localCreditHistory = stored
        applyCreditHistory(stored)
        await refreshBudgetMigrationCycle()
    }

    /// Rebuild the visible cycle list and rolling rows from an already compacted
    /// local snapshot plus the current remote cache. This path is intentionally
    /// database-free because sync can call it every minute.
    private func applyCreditHistory(
        _ stored: CreditSampleStore.HistorySnapshot
    ) {
        let account = serverUsageAccountFingerprint
        // The stored snapshot is intentionally stable between rollovers; union
        // the live in-memory cycle so routine remote recomputes cannot discard
        // buckets captured since the startup history query.
        syncCreditSamples = SyncAggregate.compactCreditSamples(
            stored.samples + creditSamples
        )
        syncCycleBudgets = CreditHistoryMergePolicy.cycleBudgets(
            stored: stored.cycleBudgets, live: syncCycleBudgets
        )

        // A disconnected dashboard intentionally falls back to local telemetry.
        // The history load above exists only to keep the sync upload complete;
        // do not leak retained account-counter rows back into that fallback UI.
        guard serverUsageEnabled else {
            previousCreditActivity = []
            recompute()
            return
        }

        let remotes = syncEnabled ? currentRemoteAggregates() : []
        let remoteSamples: [CreditSample]
        if let account {
            remoteSamples = remotes
                .filter { $0.accountFingerprint == account }
                .flatMap { $0.creditSamples ?? [] }
                .map(\.creditSample)
        } else {
            remoteSamples = []
        }
        creditCycles = SyncAggregate.mergedCreditCycles(
            local: stored.cycles,
            additionalSamples: remoteSamples
                + [serverUsageSample].compactMap { $0 }
        )
        refreshCurrentCreditObservation()
        let liveDay = CreditCycleSummary.liveCycleDay(
            currentSample: currentServerUsageSample, cycles: creditCycles
        )
        previousCreditActivity = CreditTimeline.combinedDailyRows(
            samplesByCycle: creditCycles.compactMap { cycle in
                guard cycle.resetDayMs != liveDay else { return nil }
                let local = stored.samplesByCycle[cycle.resetDayMs] ?? []
                if let account {
                    return SyncAggregate.mergedCreditSamples(
                        local: local,
                        remotes: remotes,
                        resetAtMs: cycle.resetAtMs,
                        accountFingerprint: account
                    )
                }
                return local
            }
        )
        if let selectedCreditCycleDayMs,
           !creditCycles.contains(where: {
               $0.resetDayMs == selectedCreditCycleDayMs
           }) {
            resetCreditCycleSelection()
        }
        recompute()
    }

    func disableServerUsage() {
        serverUsageGeneration += 1
        let removed = CreditUsageKeychain.deleteToken()
        transitionToDisconnectedServerUsage(error: removed
            ? nil
            : "GitHub is disconnected, but macOS couldn’t remove the saved credential.")
    }

    private func transitionToDisconnectedServerUsage(error: String?) {
        serverUsageEnabled = false
        pendingCycleTransitionSample = nil
        budgetMigrationCycleDayMs = nil
        previousCreditActivity = []
        resetCreditCycleSelection()
        resetSpendCalendar()
        UserDefaults.standard.set(false, forKey: Self.serverUsageKey)
        UserDefaults.standard.set(true, forKey: Self.serverUsageDisconnectedKey)
        serverUsageError = error
        recompute()
    }

    func beginServerUsageConnection() -> Bool {
        guard !isConnectingServerUsage else { return false }
        isConnectingServerUsage = true
        return true
    }

    func endServerUsageConnection() {
        isConnectingServerUsage = false
        serverUsageConnectTask = nil
        if syncEnabled { Task { await syncNow() } }
    }

    /// Let the user abandon a device-flow authorization that can't complete —
    /// an account needing a sign-in route BarPilot can't drive, for instance.
    /// Without this the only exit was force-quitting the app.
    func cancelServerUsageConnection() {
        serverUsageConnectTask?.cancel()
        serverUsageConnectTask = nil
    }

    /// Hand the store the running device-flow task so `cancel` can reach it.
    func registerServerUsageConnectTask(_ task: Task<Void, Never>) {
        serverUsageConnectTask = task
    }

    /// Fetch one cumulative counter observation. A failed request never writes a
    /// zero or replaces the last good sample.
    @discardableResult
    func refreshServerUsage() async -> ServerUsageRefreshOutcome {
        let generation = serverUsageGeneration
        guard serverUsageEnabled else { return .notNeeded }
        if let active = activeServerRefreshes[generation] {
            return await finishServerRefresh(active, generation: generation)
        }
        let active = ActiveServerRefresh(
            id: UUID(),
            startedAt: Date(),
            task: Task { @MainActor [weak self] in
                guard let self else { return .notNeeded }
                return await self.performServerUsageRefresh(generation: generation)
            }
        )
        activeServerRefreshes[generation] = active
        return await finishServerRefresh(active, generation: generation)
    }

    private func finishServerRefresh(
        _ active: ActiveServerRefresh,
        generation: Int
    ) async -> ServerUsageRefreshOutcome {
        let outcome = await active.task.value
        if activeServerRefreshes[generation]?.id == active.id {
            activeServerRefreshes.removeValue(forKey: generation)
        }
        return outcome
    }

    private func cancelServerRefreshStarted(
        before cutoff: Date,
        generation: Int
    ) async {
        guard let active = activeServerRefreshes[generation],
              active.startedAt < cutoff else {
            return
        }
        active.task.cancel()
        _ = await finishServerRefresh(active, generation: generation)
    }

    private func performServerUsageRefresh(
        generation: Int
    ) async -> ServerUsageRefreshOutcome {
        guard serverUsageEnabled, generation == serverUsageGeneration,
              !Task.isCancelled else {
            return .notNeeded
        }
        guard let token = CreditUsageKeychain.token() else {
            serverUsageGeneration += 1
            transitionToDisconnectedServerUsage(
                error: "GitHub is disconnected. Connect again from the usage window."
            )
            return .notNeeded
        }
        do {
            let sample = try await CreditUsageAPI.fetch(token: token)
            guard serverUsageEnabled, generation == serverUsageGeneration,
                  !Task.isCancelled else {
                return .notNeeded
            }
            let previous = serverUsageSample
            var confirmedPendingTransition = false
            if let pending = pendingCycleTransitionSample {
                if CreditCycleTransitionPolicy.confirms(
                    previous: previous ?? pending,
                    pending: pending,
                    current: sample
                ) {
                    confirmedPendingTransition = true
                    pendingCycleTransitionSample = nil
                } else if CreditCycleSummary.dayStart(for: pending.resetAtMs)
                            == CreditCycleSummary.dayStart(for: sample.resetAtMs) {
                    // A repeated non-zero value is still indistinguishable from
                    // the old cycle's cached counter. Keep waiting without ever
                    // writing it into the new cycle.
                    serverUsageError = nil
                    recompute()
                    return .refreshed
                } else {
                    pendingCycleTransitionSample = nil
                }
            }
            if !confirmedPendingTransition,
               CreditCycleTransitionPolicy.needsConfirmation(
                   previous: previous, current: sample
               ) {
                pendingCycleTransitionSample = sample
                serverUsageError = nil
                recompute()
                return .refreshed
            }

            let resolvedAccountDuringRefresh = serverUsageAccountFingerprint == nil
            if resolvedAccountDuringRefresh {
                guard let fingerprint = await CreditUsageAPI.accountFingerprint(token: token) else {
                    guard serverUsageEnabled, generation == serverUsageGeneration,
                          !Task.isCancelled else {
                        return .notNeeded
                    }
                    serverUsageError = "GitHub authenticated, but BarPilot couldn’t verify the account for safe multi-Mac history."
                    recompute()
                    return .retryableFailure
                }
                guard serverUsageEnabled, generation == serverUsageGeneration,
                      !Task.isCancelled else {
                    return .notNeeded
                }
                serverUsageAccountFingerprint = fingerprint
                localCreditHistory = nil
                syncCycleBudgets = []
                UserDefaults.standard.set(fingerprint, forKey: Self.serverUsageAccountKey)
            }
            let account = serverUsageAccountFingerprint
            let budgetUSD = monthlyBudget
            let budgetChangedAtMs = self.budgetUpdatedAtMs
            let persisted = await Task.detached(priority: .utility) {
                if let account { CreditSampleStore.adoptUnattributed(account: account) }
                let saved = CreditSampleStore.save(
                    sample, account: account, budgetUSD: budgetUSD,
                    budgetUpdatedAtMs: budgetChangedAtMs
                )
                let cycles = resolvedAccountDuringRefresh
                    ? CreditSampleStore.cycles(account: account)
                    : nil
                return (saved, cycles)
            }.value
            guard serverUsageEnabled, generation == serverUsageGeneration,
                  !Task.isCancelled else {
                return .notNeeded
            }
            guard persisted.0 else {
                serverUsageError = "The GitHub total was received but couldn’t be saved locally."
                recompute()
                return .notNeeded
            }
            budgetPersistenceError = nil
            upsertLocalCycleBudget(
                resetDayMs: CreditCycleSummary.dayStart(for: sample.resetAtMs),
                budgetUSD: budgetUSD, updatedAtMs: budgetChangedAtMs
            )
            if let cycles = persisted.1 { creditCycles = cycles }
            upsertCreditCycle(sample)
            // Only treat this as a genuine rollover when the cycle actually moved
            // FORWARD and the counter reset with it. Reacting to any change meant
            // one response whose reset resolved from a different field discarded
            // the cycle's history even though nothing had actually rolled over.
            let cycleChanged = CreditCycleTransitionPolicy.changed(
                previous: previous, current: sample
            )
            let rolledOver = CreditCycleTransitionPolicy.rolledOver(
                previous: previous, current: sample
            )
            if rolledOver || confirmedPendingTransition {
                creditSamples = [sample]
            } else if previous == nil || sample.resetAtMs != previous?.resetAtMs {
                // First sample of the session, or the reset instant shifted within
                // the same cycle: re-read from storage instead of discarding.
                creditSamples = Self.loadCycleSamples(
                    resetAtMs: sample.resetAtMs, account: serverUsageAccountFingerprint
                )
                if !creditSamples.contains(sample) { creditSamples.append(sample) }
            } else {
                creditSamples.append(sample)
            }
            if !syncCreditSamples.contains(sample) {
                syncCreditSamples.append(sample)
            }
            if selectedCreditCycleDayMs == nil {
                selectedCreditCycleSamples = creditSamples
            } else if !creditCycles.contains(where: {
                $0.resetDayMs == selectedCreditCycleDayMs
            }) {
                resetCreditCycleSelection()
            }
            serverUsageSample = sample
            serverUsageError = nil
            recompute()
            if cycleChanged || resolvedAccountDuringRefresh {
                await refreshCreditCycles()
            } else {
                await refreshBudgetMigrationCycle()
            }
            if resolvedAccountDuringRefresh, syncEnabled {
                await syncNow()
            }
            return .refreshed
        } catch {
            guard !Task.isCancelled else { return .notNeeded }
            guard serverUsageEnabled, generation == serverUsageGeneration else {
                return .notNeeded
            }
            serverUsageError = Self.serverUsageErrorMessage(error)
            if case .unauthorized = error as? CreditUsageError {
                let message = serverUsageError
                serverUsageGeneration += 1
                let removed = CreditUsageKeychain.deleteToken()
                transitionToDisconnectedServerUsage(error: removed
                    ? message
                    : "GitHub authentication expired, and macOS couldn’t remove the saved credential."
                )
                return .notNeeded
            }
            recompute()
            if case .network = error as? CreditUsageError {
                return .retryableFailure
            }
            return .notNeeded
        }
    }

    /// A visible screen wake should not wait for the next 60-second reload. The
    /// caller already allows networking to settle; replace any request that began
    /// before that point, then retry once only after a transient failure.
    func refreshServerUsageAfterWake(wokeAt: Date) async {
        let settledAt = wokeAt.addingTimeInterval(
            WakeRefreshPolicy.networkSettleDelaySeconds
        )
        await cancelServerRefreshStarted(
            before: settledAt,
            generation: serverUsageGeneration
        )
        let outcome = await refreshServerUsage()
        guard WakeRefreshPolicy.shouldRetry(
            outcome: outcome,
            latestCapturedAt: serverUsageSample?.capturedAt,
            wokeAt: wokeAt
        ) else {
            return
        }

        do {
            try await Task.sleep(nanoseconds: WakeRefreshPolicy.retryDelayNanoseconds)
        } catch {
            return
        }
        guard serverUsageEnabled,
              !WakeRefreshPolicy.hasPostWakeSample(
                capturedAt: serverUsageSample?.capturedAt,
                wokeAt: wokeAt
              ) else {
            return
        }
        await refreshServerUsage()
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

    /// Load the current cycle's persisted samples for the connected account.
    /// Rows are attributed at write time, so a disconnect/reconnect — or a
    /// change in how the account fingerprint is derived — no longer hides them.
    /// The old mutable baseline pointer did exactly that: it was the only thing
    /// isolating accounts, so it had to jump forward on every reconnect.
    private static func loadCycleSamples(resetAtMs: Int64, account: String?) -> [CreditSample] {
        CreditSampleStore.loadCycle(
            resetDayMs: CreditCycleSummary.dayStart(for: resetAtMs),
            account: account
        )
    }

    var displayTotalCredits: Double { reconciled.totalCredits }
    var rollingCreditActivity: [ObservedDayCredits] {
        CreditTimeline.mergedDailyRows([
            creditTimeline.daily, previousCreditActivity
        ])
    }
    private func refreshCurrentCreditObservation() {
        // Gated on the connection too: an explicit disconnect drops the headline
        // to local telemetry. While connected, however, a matching peer may be
        // the only Mac that observed the current cycle rollover.
        guard serverUsageEnabled else {
            resolvedCurrentCreditObservation = nil
            return
        }
        resolvedCurrentCreditObservation = SyncAggregate.currentCreditObservation(
            local: serverUsageSample,
            remotes: syncEnabled ? currentRemoteAggregates() : [],
            accountFingerprint: serverUsageAccountFingerprint
        )
    }
    private var currentServerUsageObservation: CurrentCreditObservation? {
        resolvedCurrentCreditObservation
    }
    var currentServerUsageSample: CreditSample? {
        currentServerUsageObservation?.sample
    }
    var currentServerUsageSampleIsRemote: Bool {
        currentServerUsageObservation?.cameFromRemote == true
    }
    var currentServerUsageObservedAt: Date? {
        guard let sample = currentServerUsageSample else { return nil }
        return Date(timeIntervalSince1970: Double(
            sample.serverAtMs ?? sample.capturedAtMs
        ) / 1000)
    }
    var compactTotalCredits: Double {
        if selectedCreditCycleDayMs != nil {
            return selectedHistoricalTotalCredits
                ?? selectedCreditCycle?.latestSample.creditsUsed
                ?? currentCompactTotalCredits
        }
        return currentCompactTotalCredits
    }

    private var currentCompactTotalCredits: Double {
        guard serverUsageEnabled, let sample = currentServerUsageSample else {
            return currentMonthReport.totalCredits
        }
        guard CreditReconciliation.matchesCurrentCycle(
            snapshot: sample, report: currentMonthReport, now: Date()
        ) else {
            return sample.creditsUsed
        }
        return max(sample.creditsUsed, currentMonthReport.totalCredits)
    }

    var selectedCreditCycle: CreditCycleSummary? {
        guard serverUsageEnabled else { return nil }
        if let selectedCreditCycleDayMs {
            return creditCycles.first { $0.resetDayMs == selectedCreditCycleDayMs }
        }
        guard let current = currentServerUsageSample else { return nil }
        let currentDay = CreditCycleSummary.dayStart(for: current.resetAtMs)
        return creditCycles.first { $0.resetDayMs == currentDay }
    }

    var isViewingCurrentCreditCycle: Bool {
        selectedCreditCycleDayMs == nil
    }

    /// The target belonging to the cycle rendered by the primary dashboard.
    /// Historical nil is not replaced with today's preference: it means the
    /// cycle predates budget snapshots and its target is unknown.
    var compactBudgetUSD: Double? {
        isViewingCurrentCreditCycle ? monthlyBudget : selectedHistoricalBudgetUSD
    }

    /// The sole historical write affordance is a migration repair for the one
    /// cycle that completed before snapshots existed.
    var canAssignMissingBudgetForSelectedCreditCycle: Bool {
        selectedHistoricalBudgetUSD == nil
            && selectedCreditCycleDayMs != nil
            && selectedCreditCycleDayMs == budgetMigrationCycleDayMs
    }

    @discardableResult
    func assignMissingBudgetForSelectedCreditCycle(
        _ budgetUSD: Double
    ) async -> Bool {
        guard budgetUSD.isFinite, budgetUSD >= 0,
              canAssignMissingBudgetForSelectedCreditCycle,
              let resetDayMs = selectedCreditCycleDayMs else {
            return false
        }
        let account = serverUsageAccountFingerprint
        let updatedAtMs = Int64(Date().timeIntervalSince1970 * 1_000)
        let saved = await Task.detached(priority: .utility) {
            let saved = CreditSampleStore.assignCycleBudgetIfMissing(
                resetDayMs: resetDayMs,
                account: account,
                budgetUSD: budgetUSD,
                updatedAtMs: updatedAtMs
            )
            if saved { CreditSampleStore.completeBudgetMigration(account: account) }
            return saved
        }.value
        guard saved, selectedCreditCycleDayMs == resetDayMs,
              serverUsageAccountFingerprint == account else {
            return false
        }
        selectedHistoricalBudgetUSD = budgetUSD
        budgetMigrationCycleDayMs = nil
        upsertLocalCycleBudget(
            resetDayMs: resetDayMs, budgetUSD: budgetUSD,
            updatedAtMs: updatedAtMs
        )
        localCreditHistory = nil
        await refreshCreditCycles()
        if syncEnabled { await syncNow() }
        return true
    }

    private func refreshBudgetMigrationCycle() async {
        guard serverUsageEnabled,
              let account = serverUsageAccountFingerprint,
              let current = currentServerUsageSample else {
            budgetMigrationCycleDayMs = nil
            return
        }
        let liveResetDayMs = CreditCycleSummary.dayStart(for: current.resetAtMs)
        let cycles = creditCycles
        let generation = serverUsageGeneration
        let candidate = await Task.detached(priority: .utility) {
            CreditSampleStore.budgetMigrationCycle(
                liveResetDayMs: liveResetDayMs,
                cycles: cycles,
                account: account
            )
        }.value
        guard serverUsageEnabled,
              generation == serverUsageGeneration,
              account == serverUsageAccountFingerprint else {
            return
        }
        budgetMigrationCycleDayMs = candidate
    }

    var canSelectOlderCreditCycle: Bool {
        guard let selectedCreditCycle,
              let index = creditCycles.firstIndex(of: selectedCreditCycle) else {
            return false
        }
        return creditCycles.indices.contains(index + 1)
    }

    var canSelectNewerCreditCycle: Bool {
        guard let selectedCreditCycle,
              let index = creditCycles.firstIndex(of: selectedCreditCycle) else {
            return false
        }
        return index > 0
    }

    func selectOlderCreditCycle() {
        guard let selectedCreditCycle,
              let index = creditCycles.firstIndex(of: selectedCreditCycle),
              creditCycles.indices.contains(index + 1) else {
            return
        }
        selectCreditCycle(creditCycles[index + 1].resetDayMs)
    }

    func selectNewerCreditCycle() {
        guard let selectedCreditCycle,
              let index = creditCycles.firstIndex(of: selectedCreditCycle),
              index > 0 else {
            return
        }
        let newer = creditCycles[index - 1]
        let liveDay = CreditCycleSummary.liveCycleDay(
            currentSample: currentServerUsageSample, cycles: creditCycles
        )
        if newer.resetDayMs == liveDay {
            selectedCreditCycleDayMs = nil
            selectedCreditCycleSamples = creditSamples
            selectedHistoricalBudgetUSD = nil
            updateCreditCycleView()
        } else {
            selectCreditCycle(newer.resetDayMs)
        }
    }

    @discardableResult
    func selectCreditCycle(containingUTCDate date: Date) -> Bool {
        guard !isLoadingCreditCycle,
              let target = CreditCycleSummary.cycle(
                  containingUTCDate: date, in: creditCycles
              ) else {
            return false
        }
        let liveDay = CreditCycleSummary.liveCycleDay(
            currentSample: currentServerUsageSample, cycles: creditCycles
        )
        if target.resetDayMs == liveDay {
            resetCreditCycleSelection()
            updateCreditCycleView()
        } else {
            selectCreditCycle(target.resetDayMs)
        }
        return true
    }

    func loadSpendCalendar(containing month: Date) {
        spendCalendarLoadGeneration += 1
        let loadGeneration = spendCalendarLoadGeneration
        let serverGeneration = serverUsageGeneration
        let account = serverUsageAccountFingerprint
        let monthKey = CreditCycleSummary.utcMonthKey(for: month)
        let cycles = creditCycles.filter {
            CreditCycleSummary.overlapsUTCMonth($0, containing: month)
        }
        spendCalendarDailyCredits = [:]
        spendCalendarMonthKey = nil
        guard serverUsageEnabled, !cycles.isEmpty else {
            isLoadingSpendCalendar = false
            return
        }
        isLoadingSpendCalendar = true
        Task {
            let stored = await Task.detached(priority: .utility) {
                cycles.map { cycle in
                    (
                        cycle,
                        CreditSampleStore.loadCycle(
                            resetDayMs: cycle.resetDayMs, account: account
                        )
                    )
                }
            }.value
            guard serverUsageEnabled,
                  serverGeneration == serverUsageGeneration,
                  account == serverUsageAccountFingerprint,
                  loadGeneration == spendCalendarLoadGeneration else {
                if loadGeneration == spendCalendarLoadGeneration {
                    isLoadingSpendCalendar = false
                }
                return
            }

            let remotes = syncEnabled ? currentRemoteAggregates() : []
            var samplesByCycle: [[CreditSample]] = []
            for (cycle, local) in stored {
                let samples: [CreditSample]
                if let account {
                    samples = SyncAggregate.mergedCreditSamples(
                        local: local, remotes: remotes,
                        resetAtMs: cycle.resetAtMs,
                        accountFingerprint: account
                    )
                } else {
                    samples = local
                }
                samplesByCycle.append(samples)
            }
            spendCalendarDailyCredits = CreditTimeline.combinedDaily(
                samplesByCycle: samplesByCycle, monthKey: monthKey
            )
            spendCalendarMonthKey = monthKey
            isLoadingSpendCalendar = false
        }
    }

    private func selectCreditCycle(_ resetDayMs: Int64) {
        let liveDay = CreditCycleSummary.liveCycleDay(
            currentSample: currentServerUsageSample, cycles: creditCycles
        )
        guard resetDayMs != liveDay,
              !isLoadingCreditCycle else {
            return
        }
        let account = serverUsageAccountFingerprint
        let generation = serverUsageGeneration
        creditCycleLoadGeneration += 1
        let loadGeneration = creditCycleLoadGeneration
        isLoadingCreditCycle = true
        Task {
            let stored = await Task.detached(priority: .utility) {
                (
                    CreditSampleStore.loadCycle(
                        resetDayMs: resetDayMs, account: account
                    ),
                    CreditSampleStore.cycleBudgetSnapshot(
                        resetDayMs: resetDayMs, account: account
                    )
                )
            }.value
            guard generation == serverUsageGeneration,
                  account == serverUsageAccountFingerprint,
                  loadGeneration == creditCycleLoadGeneration else {
                if loadGeneration == creditCycleLoadGeneration {
                    isLoadingCreditCycle = false
                }
                return
            }
            selectedCreditCycleDayMs = resetDayMs
            selectedCreditCycleSamples = stored.0
            if let budget = stored.1 {
                upsertLocalCycleBudget(
                    resetDayMs: resetDayMs, budgetUSD: budget.budgetUSD,
                    updatedAtMs: budget.updatedAtMs
                )
            }
            selectedHistoricalBudgetUSD = stored.1?.budgetUSD
            updateCreditCycleView()
            isLoadingCreditCycle = false
        }
    }

    /// Built in `recompute()` rather than derived per access: with sync on this
    /// opens SQLite and JSON-decodes every remote payload, and the dashboard
    /// reads it several times per body evaluation on the main actor.
    private func updateCreditCycleView() {
        guard let selected = selectedCreditCycle else {
            creditTimeline = .empty
            selectedHistoricalTotalCredits = nil
            selectedHistoricalBudgetUSD = nil
            return
        }
        let local = selectedCreditCycleDayMs == nil
            ? creditSamples : selectedCreditCycleSamples
        let samples: [CreditSample]
        if let accountFingerprint = serverUsageAccountFingerprint {
            let remotes = syncEnabled ? currentRemoteAggregates() : []
            samples = SyncAggregate.mergedCreditSamples(
                local: local, remotes: remotes,
                resetAtMs: selected.resetAtMs,
                accountFingerprint: accountFingerprint
            )
        } else {
            samples = local.filter {
                CreditCycleSummary.dayStart(for: $0.resetAtMs)
                    == selected.resetDayMs
            }
        }
        creditTimeline = CreditTimeline.build(samples: samples)
        selectedHistoricalTotalCredits = selectedCreditCycleDayMs == nil ? nil
            : samples.max {
                let lhs = $0.serverAtMs ?? $0.capturedAtMs
                let rhs = $1.serverAtMs ?? $1.capturedAtMs
                return lhs == rhs
                    ? $0.capturedAtMs < $1.capturedAtMs
                    : lhs < rhs
            }?.creditsUsed
        if let selectedCreditCycleDayMs,
           let accountFingerprint = serverUsageAccountFingerprint {
            selectedHistoricalBudgetUSD = SyncAggregate.cycleBudget(
                resetDayMs: selectedCreditCycleDayMs,
                local: syncCycleBudgets,
                localMachineId: Self.machineId,
                remotes: syncEnabled ? currentRemoteAggregates() : [],
                accountFingerprint: accountFingerprint
            )?.budgetUSD
        }
    }

    private func countCounterSyncMachines() -> Int {
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
        guard let observedAt = currentServerUsageObservedAt else { return false }
        return Date().timeIntervalSince(observedAt) > 5 * 60
    }

    /// A failed direct poll is not a dashboard failure when a fresh matching Mac
    /// supplied the same authoritative account counter through sync.
    var serverUsageStatusIsError: Bool {
        serverUsageError != nil
            && !(currentServerUsageSampleIsRemote && !serverUsageIsStale)
    }

    var serverUsageStatusLabel: String {
        guard serverUsageEnabled else {
            return serverUsageError == nil ? "GitHub · disconnected" : "GitHub · reconnect required"
        }
        if serverUsageStatusIsError { return "GitHub · error" }
        if currentServerUsageSample == nil && serverUsageSample == nil {
            return "GitHub · connecting"
        }
        if currentServerUsageSample == nil { return "GitHub · awaiting cycle" }
        if serverUsageIsStale {
            return currentServerUsageSampleIsRemote
                ? "GitHub · synced data stale" : "GitHub · stale"
        }
        if currentServerUsageSampleIsRemote {
            return "GitHub · via sync"
        }
        return "GitHub · connected"
    }

    private func onPeriodChanged() {
        UserDefaults.standard.set(periodKind.rawValue, forKey: Self.periodKey)
        recompute()
    }

    private func persistBudget(previousValue: Double) {
        UserDefaults.standard.set(monthlyBudget, forKey: Self.budgetKey)
        guard monthlyBudget != previousValue else { return }
        budgetUpdatedAtMs = max(
            budgetUpdatedAtMs + 1,
            Int64(Date().timeIntervalSince1970 * 1_000)
        )
        UserDefaults.standard.set(
            budgetUpdatedAtMs, forKey: Self.budgetUpdatedAtKey
        )
        budgetPersistenceError = nil
        guard serverUsageEnabled, let sample = currentServerUsageSample else {
            return
        }
        let resetDayMs = CreditCycleSummary.dayStart(for: sample.resetAtMs)
        let account = serverUsageAccountFingerprint
        let accountGeneration = serverUsageGeneration
        let budgetUSD = monthlyBudget
        let updatedAtMs = budgetUpdatedAtMs
        budgetWriteRevision += 1
        let revision = budgetWriteRevision
        let writer = cycleBudgetWriter
        let task = Task { [weak self] in
            let saved = await writer.persist(
                revision: revision,
                resetDayMs: resetDayMs,
                account: account,
                budgetUSD: budgetUSD,
                updatedAtMs: updatedAtMs
            )
            guard let self, revision == self.budgetWriteRevision else { return }
            self.budgetPersistenceTask = nil
            guard BudgetPersistenceCompletionPolicy.shouldApply(
                revision: revision,
                latestRevision: self.budgetWriteRevision,
                accountGeneration: accountGeneration,
                currentAccountGeneration: self.serverUsageGeneration,
                account: account,
                currentAccount: self.serverUsageAccountFingerprint
            ) else { return }
            if !saved {
                self.budgetPersistenceError =
                    "The target is saved for this Mac, but the billing-cycle snapshot couldn’t be updated."
                DiagLog.write("budget: cycle snapshot persist failed")
            } else {
                self.upsertLocalCycleBudget(
                    resetDayMs: resetDayMs, budgetUSD: budgetUSD,
                    updatedAtMs: updatedAtMs
                )
                self.localCreditHistory = nil
                if self.syncEnabled {
                    Task { [weak self] in await self?.syncNow() }
                }
            }
        }
        budgetPersistenceTask = task
    }

    private func upsertLocalCycleBudget(
        resetDayMs: Int64, budgetUSD: Double, updatedAtMs: Int64
    ) {
        syncCycleBudgets.append(SyncedCycleBudget(
            resetDayMs: resetDayMs, budgetUSD: budgetUSD,
            updatedAtMs: updatedAtMs
        ))
        syncCycleBudgets = SyncAggregate.compactCycleBudgets(syncCycleBudgets)
    }

    var hasPendingBudgetPersistence: Bool { budgetPersistenceTask != nil }

    func flushPendingBudgetPersistence() async {
        await budgetPersistenceTask?.value
    }

    private func persistCurrency() {
        UserDefaults.standard.set(displayCurrency.rawValue, forKey: Self.currencyKey)
    }

    /// Fetch the latest USD→AUD rate, cache it, and refresh the UI on success.
    func refreshRate() async {
        guard let snapshot = await ExchangeRate.fetchUSDToAUD() else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.rateDateKey)
        let changed = adoptNewestExchangeRate(from: [snapshot])
        // reload() owns the initial sync. If the network wins the launch race,
        // publishing here would replace this machine's gist rows with an empty set.
        if changed, syncEnabled, lastUpdated != nil { await syncNow() }
    }

    @discardableResult
    private func adoptNewestExchangeRate(from payloads: [MachineSyncPayload]) -> Bool {
        adoptNewestExchangeRate(from: payloads.map(\.exchangeRateSnapshot))
    }

    @discardableResult
    private func adoptNewestExchangeRate(from candidates: [ExchangeRateSnapshot?]) -> Bool {
        guard let newest = ExchangeRateSnapshot.newestValid(
            [exchangeRateSnapshot] + candidates
        ), newest.providerUpdatedAtUnix != exchangeRateSnapshot?.providerUpdatedAtUnix
        else { return false }
        exchangeRateSnapshot = newest
        usdToAUD = newest.usdToAUD
        UserDefaults.standard.set(newest.usdToAUD, forKey: Self.rateKey)
        UserDefaults.standard.set(
            Double(newest.providerUpdatedAtUnix), forKey: Self.rateProviderUpdatedKey
        )
        if let next = newest.providerNextUpdateAtUnix {
            UserDefaults.standard.set(Double(next), forKey: Self.rateProviderNextKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.rateProviderNextKey)
        }
        recompute()
        return true
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

    func displayCostString(credits: Double) -> String {
        costString(credits: credits)
    }

    /// Numeric cost in the display currency, for callers that need to plot or
    /// compare it rather than print it (the daily chart). Kept alongside
    /// `costString(credits:)` so a chart bar and its label can never disagree
    /// about the rate: both go through `toDisplay`.
    func displayCost(credits: Double) -> Double {
        toDisplay(credits / 100.0)
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
                                monthlyBudgetUSD: monthlyBudget, now: Date(),
                                excludeWeekends: excludeWeekendsFromProjection)
    }

    var compactSpendProjection: SpendProjection? {
        guard isViewingCurrentCreditCycle,
              let cycle = selectedCreditCycle,
              let startAt = cycle.startAt else { return nil }
        return SpendProjection.computeBillingCycle(
            totalCredits: currentCompactTotalCredits,
            monthlyBudgetUSD: monthlyBudget,
            startAt: startAt,
            resetAt: cycle.resetAt,
            now: Date(),
            calendar: Self.utcCalendar,
            excludeWeekends: excludeWeekendsFromProjection)
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
}
