import Foundation
import CryptoKit

// ---------------------------------------------------------------------------
// SyncAggregate — the versioned per-machine payload used for multi-Mac sync.
//
// Counter observations are account-wide and are merged, never summed. Legacy
// telemetry aggregates remain in the schema only while the old interface is
// available. No raw spans, prompts, or content are synced.
//
// This file is transport-agnostic: it computes and serializes the payload.
// Pushing/pulling it lives behind SyncBackend (added later).
// ---------------------------------------------------------------------------

/// One (UTC-day, model, reasoning-level) bucket with regression cross-products.
struct AggregateRow: Codable, Sendable {
    var utcDay: String        // "YYYY-MM-DD", UTC
    var model: String         // normalized (Aggregator.normaliseModel)
    var level: String?        // normalized reasoning level; nil = none
    var calls: Int
    var credits: Double
    var inTok: Int
    var outTok: Int
    var sii: Double, soo: Double, sio: Double, sic: Double, soc: Double, scc: Double
}

struct SyncedCreditSample: Codable, Equatable, Sendable {
    var capturedAtMs: Int64
    var serverAtMs: Int64?
    var resetAtMs: Int64
    var creditsUsed: Double

    init(_ sample: CreditSample) {
        capturedAtMs = sample.capturedAtMs
        serverAtMs = sample.serverAtMs
        resetAtMs = sample.resetAtMs
        creditsUsed = sample.creditsUsed
    }

    var creditSample: CreditSample {
        CreditSample(
            capturedAtMs: capturedAtMs, serverAtMs: serverAtMs,
            resetAtMs: resetAtMs, creditsUsed: creditsUsed
        )
    }
}

/// The target that was in force for one billing cycle. Keeping it separate
/// from the compacted observations avoids repeating the same value thousands
/// of times while still making historical comparisons recoverable.
struct SyncedCycleBudget: Codable, Equatable, Sendable {
    var resetDayMs: Int64
    var budgetUSD: Double
    /// Wall-clock time at which the target was actually changed. It must not be
    /// advanced by routine credit polling.
    var updatedAtMs: Int64
    /// Used only to make simultaneous cross-Mac edits converge deterministically.
    /// Older v3 payloads omit it and are attributed to their enclosing machine.
    var sourceMachineId: String? = nil

    /// Keep the v3 wire key readable by already-running development builds while
    /// giving the in-process value its accurate meaning.
    enum CodingKeys: String, CodingKey {
        case resetDayMs, budgetUSD, sourceMachineId
        case updatedAtMs = "capturedAtMs"
    }
}

struct CurrentCreditObservation: Equatable {
    let sample: CreditSample
    let cameFromRemote: Bool
}

/// One machine's complete versioned payload (one file per machine).
struct MachineSyncPayload: Codable, Sendable {
    var schemaVersion: Int
    var machineId: String
    var machineLabel: String?
    var updatedAt: String     // ISO8601 UTC
    var rows: [AggregateRow]
    var accountFingerprint: String? = nil
    var creditSamples: [SyncedCreditSample]? = nil
    var cycleBudgets: [SyncedCycleBudget]? = nil
    var exchangeRateSnapshot: ExchangeRateSnapshot? = nil
}

enum SyncAggregate {
    static let schemaVersion = 3
    /// A detailed 31-day cycle plus twelve correction-heavy completed cycles can
    /// exceed 4,096 rows when resets occur away from UTC midnight. Keep enough
    /// headroom for that valid history while still bounding malformed payloads.
    static let maximumSyncedCreditSamples = 6_144
    static let maximumPayloadBytes = 8 * 1_024 * 1_024
    /// Bounds the complete peer snapshot as well as each individual payload.
    /// Together with the per-row limits below, this keeps every combined integer
    /// accumulation inside a signed 64-bit `Int` on supported Macs.
    static let maximumMachinePayloads = 64
    private static let maximumAggregateRows = 50_000
    // Copilot did not exist before this range, and no retained observation needs
    // to claim a date beyond it. Besides rejecting corrupt clocks, the upper
    // bound leaves a full day of arithmetic headroom wherever a cycle range is
    // formed with `resetDayMs + dayMs`.
    private static let earliestTimestampMs: Int64 = 946_684_800_000 // 2000-01-01
    private static let latestTimestampMs: Int64 = 4_102_444_800_000 // 2100-01-01
    // Aggregate values are summed across rows and machines. These ceilings are
    // many orders above plausible personal usage while keeping every integer
    // accumulation safely inside 64-bit `Int` for the bounded payload shape.
    private static let maximumIntegerAggregate = 1_000_000_000_000
    private static let maximumCreditAggregate = 1_000_000_000_000.0
    private static let maximumRegressionAggregate = 1.0e30

    /// Decode only payload versions whose semantics this build understands.
    /// Both network pulls and the durable cache use this single gate so a
    /// downgrade cannot accidentally consume a future schema from disk.
    static func decodeSupportedPayload(_ data: Data) -> MachineSyncPayload? {
        guard data.count <= maximumPayloadBytes,
              var payload = try? JSONDecoder().decode(
            MachineSyncPayload.self, from: data
        ), isValidPayload(payload, encodedByteCount: data.count) else {
            return nil
        }
        // The enclosing machine file is authoritative for budget provenance;
        // never allow a malformed payload to impersonate another tie-breaker.
        payload.cycleBudgets = payload.cycleBudgets?.map {
            var budget = $0
            budget.sourceMachineId = payload.machineId
            return budget
        }
        return payload
    }

    /// The single publication contract. Outgoing content is encoded and checked
    /// against exactly the same limits that a later pull will enforce.
    static func encodeSupportedPayload(_ payload: MachineSyncPayload) -> Data? {
        guard isValidPayload(payload, encodedByteCount: 0),
              let data = try? JSONEncoder().encode(payload),
              isValidPayload(payload, encodedByteCount: data.count) else {
            return nil
        }
        return data
    }

    private static func isValidPayload(
        _ payload: MachineSyncPayload, encodedByteCount: Int
    ) -> Bool {
        encodedByteCount <= maximumPayloadBytes
            && (1...schemaVersion).contains(payload.schemaVersion)
            && !payload.machineId.isEmpty && payload.machineId.count <= 128
            && (payload.machineLabel?.count ?? 0) <= 256
            && (payload.accountFingerprint?.count ?? 0) <= 256
            && payload.rows.count <= maximumAggregateRows
            && payload.rows.allSatisfy(isValidAggregateRow)
            && (payload.creditSamples ?? []).count <= maximumSyncedCreditSamples
            && (payload.creditSamples ?? []).allSatisfy(isValidCreditSample)
            && (payload.cycleBudgets ?? []).count <= 64
            && (payload.cycleBudgets ?? []).allSatisfy {
                isValidTimestamp($0.resetDayMs)
                    && $0.resetDayMs % CreditCycleSummary.dayMs == 0
                    && isValidTimestamp($0.updatedAtMs)
                    && $0.budgetUSD.isFinite && $0.budgetUSD >= 0
                    && ($0.budgetUSD == 0
                        || $0.budgetUSD >= BudgetInput.minimumNonZero)
                    && $0.budgetUSD <= BudgetInput.maximum
                    && ($0.sourceMachineId?.count ?? 0) <= 128
            }
    }

    private static func isValidCreditSample(_ sample: SyncedCreditSample) -> Bool {
        CreditUsageAPI.isPlausible(sample.creditSample)
            && sample.creditsUsed <= maximumCreditAggregate
    }

    private static func isValidAggregateRow(_ row: AggregateRow) -> Bool {
        isValidUTCDay(row.utcDay)
            && !row.model.isEmpty && row.model.count <= 256
            && (row.level?.count ?? 0) <= 64
            && row.calls >= 0 && row.inTok >= 0 && row.outTok >= 0
            && row.calls <= maximumIntegerAggregate
            && row.inTok <= maximumIntegerAggregate
            && row.outTok <= maximumIntegerAggregate
            && row.credits.isFinite && row.credits >= 0
            && row.credits <= maximumCreditAggregate
            && [row.sii, row.soo, row.sio, row.sic, row.soc, row.scc]
                .allSatisfy {
                    $0.isFinite && $0 >= 0
                        && $0 <= maximumRegressionAggregate
                }
    }

    private static func isValidTimestamp(_ value: Int64) -> Bool {
        value >= earliestTimestampMs && value <= latestTimestampMs
    }

    private static func isValidUTCDay(_ value: String) -> Bool {
        guard value.count == 10 else { return false }
        let timestamp = Aggregator.utcMidnightMs(value)
        return isValidTimestamp(timestamp)
            && Aggregator.utcDayStr(timestamp) == value
    }

    /// Project local-only data into the payload for this machine. Re-publishing
    /// pulled observations would create feedback loops, so callers must never pass
    /// remote samples here.
    static func project(_ records: [UsageRecord], creditSamples: [CreditSample] = [],
                        cycleBudgets: [SyncedCycleBudget] = [],
                        accountFingerprint: String? = nil,
                        exchangeRateSnapshot: ExchangeRateSnapshot? = nil,
                        machineId: String, label: String?, updatedAt: String) -> MachineSyncPayload {
        struct Key: Hashable { let day: String; let model: String; let level: String? }
        struct Acc {
            var calls = 0; var credits = 0.0; var inTok = 0; var outTok = 0
            var sii = 0.0, soo = 0.0, sio = 0.0, sic = 0.0, soc = 0.0, scc = 0.0
        }
        var acc: [Key: Acc] = [:]
        for r in records {
            let k = Key(day: Aggregator.utcDayStr(r.startMs),
                        model: Aggregator.normaliseModel(r.model ?? "unknown"),
                        level: Aggregator.normaliseLevel(r.reasoningLevel))
            let i = Double(r.inputTokens), o = Double(r.outputTokens), c = r.credits
            var a = acc[k] ?? Acc()
            a.calls += 1; a.credits += c; a.inTok += r.inputTokens; a.outTok += r.outputTokens
            a.sii += i*i; a.soo += o*o; a.sio += i*o; a.sic += i*c; a.soc += o*c; a.scc += c*c
            acc[k] = a
        }
        let rows = acc.map { k, a in
            AggregateRow(utcDay: k.day, model: k.model, level: k.level,
                         calls: a.calls, credits: a.credits, inTok: a.inTok, outTok: a.outTok,
                         sii: a.sii, soo: a.soo, sio: a.sio, sic: a.sic, soc: a.soc, scc: a.scc)
        }.sorted {
            if $0.utcDay != $1.utcDay { return $0.utcDay < $1.utcDay }
            if $0.model != $1.model { return $0.model < $1.model }
            return ($0.level ?? "") < ($1.level ?? "")
        }
        return MachineSyncPayload(
            schemaVersion: schemaVersion, machineId: machineId,
            machineLabel: label, updatedAt: updatedAt, rows: rows,
            accountFingerprint: accountFingerprint,
            creditSamples: accountFingerprint == nil
                ? nil
                : compactCreditSamples(creditSamples).map(SyncedCreditSample.init),
            cycleBudgets: accountFingerprint == nil ? nil : compactCycleBudgets(
                cycleBudgets.map {
                    var budget = $0
                    budget.sourceMachineId = machineId
                    return budget
                }
            ),
            exchangeRateSnapshot: exchangeRateSnapshot
        )
    }

    /// Reconcile this machine's newly projected payload with its last supported
    /// remote copy before overwriting that file. Remote observations here are not
    /// peer data: they were captured by this same stable machine id and are the
    /// recovery source when the local SQLite database has been recreated.
    static func reconciledSelfPayload(
        local: MachineSyncPayload,
        remote: MachineSyncPayload?,
        recoverRemoteHistory: Bool
    ) -> MachineSyncPayload {
        guard recoverRemoteHistory,
              let remote,
              remote.machineId == local.machineId,
              (1...schemaVersion).contains(remote.schemaVersion) else {
            return local
        }

        struct RowKey: Hashable {
            let day: String
            let model: String
            let level: String?
        }
        var rows: [RowKey: AggregateRow] = [:]
        for row in remote.rows {
            rows[RowKey(day: row.utcDay, model: row.model, level: row.level)] = row
        }
        // A local projection is the current view of a bucket. The remote copy is
        // retained only for buckets no longer present locally after cache loss.
        for row in local.rows {
            rows[RowKey(day: row.utcDay, model: row.model, level: row.level)] = row
        }

        var result = local
        result.rows = rows.values.sorted {
            if $0.utcDay != $1.utcDay { return $0.utcDay < $1.utcDay }
            if $0.model != $1.model { return $0.model < $1.model }
            return ($0.level ?? "") < ($1.level ?? "")
        }
        result.exchangeRateSnapshot = local.exchangeRateSnapshot
            ?? remote.exchangeRateSnapshot

        let recoveredFingerprint: String?
        if let localFingerprint = local.accountFingerprint {
            recoveredFingerprint = remote.accountFingerprint == localFingerprint
                ? localFingerprint : nil
        } else {
            // Disconnected account usage deliberately leaves sync enabled. If
            // local preferences lost the fingerprint, preserve this machine's
            // already-published identity and history rather than erasing them.
            recoveredFingerprint = remote.accountFingerprint
        }
        if let recoveredFingerprint {
            let localSamples = local.accountFingerprint == recoveredFingerprint
                ? (local.creditSamples ?? []).map(\.creditSample) : []
            let remoteSamples = remote.accountFingerprint == recoveredFingerprint
                ? (remote.creditSamples ?? []).map(\.creditSample) : []
            result.accountFingerprint = recoveredFingerprint
            result.creditSamples = compactCreditSamples(localSamples + remoteSamples)
                .map(SyncedCreditSample.init)
            let localBudgets = local.accountFingerprint == recoveredFingerprint
                ? (local.cycleBudgets ?? []) : []
            let remoteBudgets = remote.accountFingerprint == recoveredFingerprint
                ? (remote.cycleBudgets ?? []) : []
            result.cycleBudgets = compactCycleBudgets(
                localBudgets + remoteBudgets
            )
        }
        return result
    }

    /// Stable digest of every publishable value. `updatedAt` is deliberately
    /// excluded so an unchanged payload does not upload every minute.
    static func contentFingerprint(_ payload: MachineSyncPayload) -> String? {
        var canonical = payload
        canonical.updatedAt = ""
        canonical.rows.sort {
            if $0.utcDay != $1.utcDay { return $0.utcDay < $1.utcDay }
            if $0.model != $1.model { return $0.model < $1.model }
            return ($0.level ?? "") < ($1.level ?? "")
        }
        canonical.creditSamples?.sort {
            let lhs = $0.serverAtMs ?? $0.capturedAtMs
            let rhs = $1.serverAtMs ?? $1.capturedAtMs
            if lhs != rhs { return lhs < rhs }
            if $0.capturedAtMs != $1.capturedAtMs {
                return $0.capturedAtMs < $1.capturedAtMs
            }
            if $0.resetAtMs != $1.resetAtMs {
                return $0.resetAtMs < $1.resetAtMs
            }
            return $0.creditsUsed.bitPattern < $1.creditsUsed.bitPattern
        }
        canonical.cycleBudgets = compactCycleBudgets(
            canonical.cycleBudgets ?? []
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard isValidPayload(canonical, encodedByteCount: 0),
              let data = try? encoder.encode(canonical),
              isValidPayload(canonical, encodedByteCount: data.count) else {
            return nil
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }
            .joined()
    }

    /// One deterministic latest edit per reset day. Exact timestamp ties use the
    /// stable source machine id and finally the value's bit pattern, so input or
    /// Gist dictionary order can never change the winner.
    static func compactCycleBudgets(
        _ budgets: [SyncedCycleBudget]
    ) -> [SyncedCycleBudget] {
        var byCycle: [Int64: SyncedCycleBudget] = [:]
        for budget in budgets where isValidTimestamp(budget.resetDayMs)
            && budget.resetDayMs % CreditCycleSummary.dayMs == 0
            && isValidTimestamp(budget.updatedAtMs)
            && budget.budgetUSD.isFinite && budget.budgetUSD >= 0
            && (budget.budgetUSD == 0
                || budget.budgetUSD >= BudgetInput.minimumNonZero)
            && budget.budgetUSD <= BudgetInput.maximum
            && (budget.sourceMachineId?.count ?? 0) <= 128 {
            if let current = byCycle[budget.resetDayMs],
               !budgetWins(budget, over: current) {
                continue
            } else {
                byCycle[budget.resetDayMs] = budget
            }
        }
        return byCycle.values.sorted { $0.resetDayMs > $1.resetDayMs }
    }

    private static func budgetWins(
        _ candidate: SyncedCycleBudget, over current: SyncedCycleBudget
    ) -> Bool {
        if candidate.updatedAtMs != current.updatedAtMs {
            return candidate.updatedAtMs > current.updatedAtMs
        }
        let candidateSource = candidate.sourceMachineId ?? ""
        let currentSource = current.sourceMachineId ?? ""
        if candidateSource != currentSource {
            return candidateSource > currentSource
        }
        return candidate.budgetUSD.bitPattern > current.budgetUSD.bitPattern
    }

    static func cycleBudget(
        resetDayMs: Int64,
        local: [SyncedCycleBudget],
        localMachineId: String,
        remotes: [MachineSyncPayload],
        accountFingerprint: String
    ) -> SyncedCycleBudget? {
        let localBudgets = local.map {
            var budget = $0
            budget.sourceMachineId = localMachineId
            return budget
        }
        let remoteBudgets = remotes
            .filter { $0.accountFingerprint == accountFingerprint }
            .flatMap { payload in
                (payload.cycleBudgets ?? []).map {
                    var budget = $0
                    budget.sourceMachineId = payload.machineId
                    return budget
                }
            }
        return compactCycleBudgets(localBudgets + remoteBudgets)
            .first { $0.resetDayMs == resetDayMs }
    }

    /// Keep 15-minute bucket starts plus the moving final observation for the
    /// newest (live) cycle. Completed cycles retain the first, high-water and
    /// last sample of each UTC day: that preserves correction-aware attribution
    /// while reducing a year of history from ~39,000 rows to hundreds.
    /// Reset-time variants on the same UTC day belong to the same cycle.
    static func compactCreditSamples(_ samples: [CreditSample]) -> [CreditSample] {
        struct Bucket: Hashable {
            var resetDayMs: Int64
            var interval: Int64
        }
        struct RetainedKey: Hashable {
            var capturedAtMs: Int64
            var serverAtMs: Int64?
            var resetAtMs: Int64
            var creditsBits: UInt64
        }
        func effectiveAt(_ sample: CreditSample) -> Int64 {
            sample.serverAtMs ?? sample.capturedAtMs
        }
        let ordered = samples.sorted {
            let lhs = effectiveAt($0)
            let rhs = effectiveAt($1)
            return lhs == rhs ? $0.capturedAtMs < $1.capturedAtMs : lhs < rhs
        }
        let detailedCycle = ordered.map {
            CreditCycleSummary.dayStart(for: $0.resetAtMs)
        }.max()
        var firstByBucket: [Bucket: CreditSample] = [:]
        var lastByCompletedDay: [Bucket: CreditSample] = [:]
        var peakByCompletedDay: [Bucket: CreditSample] = [:]
        var lastByCycle: [Int64: CreditSample] = [:]
        for sample in ordered {
            let resetDay = CreditCycleSummary.dayStart(for: sample.resetAtMs)
            let bucketWidth = resetDay == detailedCycle
                ? Int64(15 * 60 * 1000)
                : CreditCycleSummary.dayMs
            let bucket = Bucket(
                resetDayMs: resetDay,
                interval: effectiveAt(sample) / bucketWidth
            )
            if firstByBucket[bucket] == nil {
                firstByBucket[bucket] = sample
            }
            if resetDay != detailedCycle {
                lastByCompletedDay[bucket] = sample
                if sample.creditsUsed >= (peakByCompletedDay[bucket]?.creditsUsed ?? -.infinity) {
                    peakByCompletedDay[bucket] = sample
                }
            }
            lastByCycle[resetDay] = sample
        }
        var retained: [RetainedKey: CreditSample] = [:]
        for group in [
            Array(firstByBucket.values), Array(peakByCompletedDay.values),
            Array(lastByCompletedDay.values), Array(lastByCycle.values)
        ] {
            for sample in group {
                retained[RetainedKey(
                    capturedAtMs: sample.capturedAtMs,
                    serverAtMs: sample.serverAtMs,
                    resetAtMs: sample.resetAtMs,
                    creditsBits: sample.creditsUsed.bitPattern
                )] = sample
            }
        }
        let compacted = retained.values
            .sorted {
                let lhs = effectiveAt($0)
                let rhs = effectiveAt($1)
                return lhs == rhs ? $0.capturedAtMs < $1.capturedAtMs : lhs < rhs
            }
        // Malformed or unexpectedly long cycles must not produce an unbounded
        // gist. Prefer the newest observations if the defensive cap is reached.
        return Array(compacted.suffix(maximumSyncedCreditSamples))
    }

    /// Merge the same account-wide counter as observed by several machines.
    /// Exact duplicate observations collapse; values are never added together.
    static func mergedCreditSamples(
        local: [CreditSample], remotes: [MachineSyncPayload],
        resetAtMs: Int64, accountFingerprint: String
    ) -> [CreditSample] {
        struct Key: Hashable {
            let capturedAtMs: Int64
            let serverAtMs: Int64?
            let resetAtMs: Int64
            let creditsBits: UInt64
        }
        let remote = remotes
            .filter { $0.accountFingerprint == accountFingerprint }
            .flatMap { $0.creditSamples ?? [] }
            .map(\.creditSample)
        let resetDay = CreditCycleSummary.dayStart(for: resetAtMs)
        var seen: Set<Key> = []
        return (local + remote)
            .filter {
                CreditCycleSummary.dayStart(for: $0.resetAtMs) == resetDay
            }
            .filter { sample in
                seen.insert(Key(
                    capturedAtMs: sample.capturedAtMs,
                    serverAtMs: sample.serverAtMs,
                    resetAtMs: sample.resetAtMs,
                    creditsBits: sample.creditsUsed.bitPattern
                )).inserted
            }
            .sorted {
                let lhs = $0.serverAtMs ?? $0.capturedAtMs
                let rhs = $1.serverAtMs ?? $1.capturedAtMs
                return lhs == rhs ? $0.capturedAtMs < $1.capturedAtMs : lhs < rhs
            }
    }

    /// Extend locally known cycle summaries with samples observed only on other
    /// Macs. The newest server observation owns each reset-day summary; local
    /// capture time only breaks a tie or substitutes when server time is absent.
    static func mergedCreditCycles(
        local: [CreditCycleSummary],
        additionalSamples: [CreditSample]
    ) -> [CreditCycleSummary] {
        var latestByDay = Dictionary(
            uniqueKeysWithValues: local.map {
                ($0.resetDayMs, $0.latestSample)
            }
        )
        for sample in additionalSamples {
            let day = CreditCycleSummary.dayStart(for: sample.resetAtMs)
            let sampleAt = sample.serverAtMs ?? sample.capturedAtMs
            let previous = latestByDay[day]
            let previousAt = previous.map {
                $0.serverAtMs ?? $0.capturedAtMs
            } ?? .min
            if sampleAt > previousAt
                || (sampleAt == previousAt
                    && sample.capturedAtMs >= (previous?.capturedAtMs ?? .min)) {
                latestByDay[day] = sample
            }
        }
        return latestByDay.values
            .map { CreditCycleSummary(latestSample: $0) }
            .sorted { $0.resetDayMs > $1.resetDayMs }
    }

    /// Select the newest valid account-counter observation available to this
    /// dashboard. A peer can be the only machine to observe a cycle rollover, so
    /// requiring a local sample would discard precisely the gap sync should fill.
    static func currentCreditObservation(
        local: CreditSample?,
        remotes: [MachineSyncPayload],
        accountFingerprint: String?,
        now: Date = Date()
    ) -> CurrentCreditObservation? {
        var candidates: [CurrentCreditObservation] = []
        if let local, CreditReconciliation.isCurrentCycle(local, now: now) {
            candidates.append(CurrentCreditObservation(
                sample: local, cameFromRemote: false
            ))
        }
        if let accountFingerprint {
            candidates += remotes
                .filter { $0.accountFingerprint == accountFingerprint }
                .flatMap { $0.creditSamples ?? [] }
                .map(\.creditSample)
                .filter { CreditReconciliation.isCurrentCycle($0, now: now) }
                .map { CurrentCreditObservation(sample: $0, cameFromRemote: true) }
        }
        return candidates.max {
            let lhs = $0.sample.serverAtMs ?? $0.sample.capturedAtMs
            let rhs = $1.sample.serverAtMs ?? $1.sample.capturedAtMs
            if lhs != rhs { return lhs < rhs }
            // Prefer the direct local observation on an exact timestamp tie.
            if $0.cameFromRemote != $1.cameFromRemote {
                return $0.cameFromRemote && !$1.cameFromRemote
            }
            return $0.sample.capturedAtMs < $1.sample.capturedAtMs
        }
    }

    // -----------------------------------------------------------------------
    // Self-consistency check (--verify-sync): projecting the raw cache, then
    // JSON round-tripping and summing back per model, must reproduce the raw
    // Models-tab fit exactly. Proves the core claim before any transport exists.
    // -----------------------------------------------------------------------
    static func verifySelfConsistency() {
        CreditHistoryLoadPolicy.verify()
        CreditHistoryMergePolicy.verify()
        RemoteCacheApplicationPolicy.verify()
        BudgetPersistenceCompletionPolicy.verify()
        SyncPublishPolicy.verify()
        GitHubBackend.verifyDiscoveryPolicy()
        let (records, _) = DataSources.loadAll()
        let today = PeriodResolver.todayStr()
        let range = PeriodResolver.range(kind: .allTime, customFrom: Date(), customTo: Date())
        let raw = Aggregator.build(records: records, fromStr: range.from, toStr: range.to, todayStr: today)

        // Project, then round-trip through JSON to also exercise Codable + size.
        let sampleStart = Aggregator.utcMidnightMs("2030-01-10")
        let reset = Aggregator.utcMidnightMs("2030-02-01")
        let sampleFixture = [
            CreditSample(capturedAtMs: sampleStart, serverAtMs: nil, resetAtMs: reset, creditsUsed: 100),
            CreditSample(capturedAtMs: sampleStart + 60_000, serverAtMs: nil, resetAtMs: reset, creditsUsed: 100),
            CreditSample(capturedAtMs: sampleStart + 3_600_000, serverAtMs: nil, resetAtMs: reset, creditsUsed: 100),
            CreditSample(capturedAtMs: sampleStart + 3_660_000, serverAtMs: nil, resetAtMs: reset, creditsUsed: 110)
        ]
        let rateFixture = ExchangeRateSnapshot(
            usdToAUD: 1.405035,
            providerUpdatedAtUnix: 1_900_000_000,
            providerNextUpdateAtUnix: 1_900_086_400
        )
        let budgetFixture = SyncedCycleBudget(
            resetDayMs: reset, budgetUSD: 150,
            updatedAtMs: sampleStart + 3_660_000,
            sourceMachineId: "self"
        )
        let agg = project(
            records, creditSamples: sampleFixture,
            cycleBudgets: [budgetFixture],
            accountFingerprint: "same-account",
            exchangeRateSnapshot: rateFixture,
            machineId: "self", label: nil, updatedAt: ""
        )
        let data = try! JSONEncoder().encode(agg)
        let decoded = try! JSONDecoder().decode(MachineSyncPayload.self, from: data)
        precondition(decoded.schemaVersion == 3
                     && decoded.creditSamples?.count == 3
                     && decoded.cycleBudgets == [budgetFixture]
                     && decoded.exchangeRateSnapshot == rateFixture,
                     "sync v3 must retain counter history, cycle budgets, and the exchange-rate snapshot")
        let originalFingerprint = contentFingerprint(agg)
        var timestampOnlyChange = agg
        timestampOnlyChange.updatedAt = "later"
        precondition(
            originalFingerprint == contentFingerprint(timestampOnlyChange),
            "sync timestamps alone must not force a payload upload"
        )
        var reordered = agg
        reordered.rows.reverse()
        reordered.creditSamples?.reverse()
        reordered.cycleBudgets?.reverse()
        precondition(
            originalFingerprint == contentFingerprint(reordered),
            "equivalent payload ordering must keep a stable sync fingerprint"
        )
        var materialChange = agg
        materialChange.machineLabel = "Renamed Mac"
        precondition(
            originalFingerprint != contentFingerprint(materialChange),
            "the sync fingerprint must cover complete payload content"
        )
        precondition(
            try! GitHubBackend.decodeMachinePayload(
                data, excluding: "another-machine"
            )?.machineId == agg.machineId,
            "a valid machine file must decode during a pull"
        )
        precondition(
            try! GitHubBackend.decodeMachinePayload(
                data, excluding: agg.machineId
            ) == nil,
            "a pull must exclude this machine's own payload"
        )
        do {
            _ = try GitHubBackend.decodeMachinePayload(
                Data("{malformed".utf8), excluding: "self"
            )
            preconditionFailure("an unreadable machine file must fail the whole pull")
        } catch SyncError.encoding {
            // Expected: the caller will retain every last-known-good machine.
        } catch {
            preconditionFailure("an unreadable machine file returned the wrong error")
        }
        var futureSchema = agg
        futureSchema.schemaVersion = schemaVersion + 1
        let futureData = try! JSONEncoder().encode(futureSchema)
        do {
            _ = try GitHubBackend.decodeMachinePayload(
                futureData, excluding: "self"
            )
            preconditionFailure("an unsupported future schema must retain the last-good cache")
        } catch SyncError.encoding {
            // Expected until this app version knows the newer contract.
        } catch {
            preconditionFailure("an unsupported schema returned the wrong error")
        }
        var invalidSamplePayload = agg
        invalidSamplePayload.creditSamples = [SyncedCreditSample(CreditSample(
            capturedAtMs: sampleStart, serverAtMs: nil,
            resetAtMs: reset, creditsUsed: -1
        ))]
        precondition(
            decodeSupportedPayload(try! JSONEncoder().encode(invalidSamplePayload)) == nil,
            "negative incoming counter observations must be rejected"
        )
        var implausibleClockPayload = agg
        implausibleClockPayload.creditSamples = [SyncedCreditSample(CreditSample(
            capturedAtMs: Aggregator.utcMidnightMs("2099-01-01"),
            serverAtMs: nil,
            resetAtMs: reset,
            creditsUsed: 1
        ))]
        precondition(
            encodeSupportedPayload(implausibleClockPayload) == nil
                && decodeSupportedPayload(
                    try! JSONEncoder().encode(implausibleClockPayload)
                ) == nil,
            "semantically impossible synced timestamps must be rejected"
        )
        var oversizedIncomingPayload = agg
        oversizedIncomingPayload.creditSamples = (0...maximumSyncedCreditSamples).map {
            SyncedCreditSample(CreditSample(
                capturedAtMs: sampleStart + Int64($0), serverAtMs: nil,
                resetAtMs: reset, creditsUsed: Double($0)
            ))
        }
        precondition(
            decodeSupportedPayload(try! JSONEncoder().encode(oversizedIncomingPayload)) == nil,
            "incoming counter observations must respect the payload ceiling"
        )
        let validRow = AggregateRow(
            utcDay: "2030-01-10", model: "test", level: nil,
            calls: 1, credits: 1, inTok: 1, outTok: 1,
            sii: 1, soo: 1, sio: 1, sic: 1, soc: 1, scc: 1
        )
        var unsafeIntegerPayload = agg
        var unsafeIntegerRow = validRow
        unsafeIntegerRow.calls = .max
        unsafeIntegerPayload.rows = [unsafeIntegerRow, unsafeIntegerRow]
        precondition(
            encodeSupportedPayload(unsafeIntegerPayload) == nil
                && decodeSupportedPayload(
                    try! JSONEncoder().encode(unsafeIntegerPayload)
                ) == nil,
            "integer aggregates capable of overflowing combined reports must be rejected"
        )
        var invalidDatePayload = agg
        var invalidDateRow = validRow
        invalidDateRow.utcDay = "2030-02-30"
        invalidDatePayload.rows = [invalidDateRow]
        precondition(
            encodeSupportedPayload(invalidDatePayload) == nil,
            "normalized but nonexistent UTC dates must be rejected"
        )
        var unsafeTimestampPayload = agg
        unsafeTimestampPayload.creditSamples = [SyncedCreditSample(CreditSample(
            capturedAtMs: .max, serverAtMs: nil,
            resetAtMs: .max, creditsUsed: 1
        ))]
        unsafeTimestampPayload.cycleBudgets = [SyncedCycleBudget(
            resetDayMs: Int64.max / CreditCycleSummary.dayMs
                * CreditCycleSummary.dayMs,
            budgetUSD: 1, updatedAtMs: .max
        )]
        precondition(
            encodeSupportedPayload(unsafeTimestampPayload) == nil
                && decodeSupportedPayload(
                    try! JSONEncoder().encode(unsafeTimestampPayload)
                ) == nil,
            "timestamps that make cycle-range arithmetic unsafe must be rejected"
        )
        var unsafeBudgetPayload = agg
        unsafeBudgetPayload.cycleBudgets = [SyncedCycleBudget(
            resetDayMs: reset, budgetUSD: 1e-300,
            updatedAtMs: sampleStart
        )]
        precondition(
            encodeSupportedPayload(unsafeBudgetPayload) == nil
                && decodeSupportedPayload(
                    try! JSONEncoder().encode(unsafeBudgetPayload)
                ) == nil,
            "sub-cent targets that make percentage arithmetic unsafe must be rejected"
        )
        var oversizedOutgoingPayload = agg
        oversizedOutgoingPayload.rows = Array(
            repeating: validRow, count: maximumAggregateRows + 1
        )
        precondition(
            encodeSupportedPayload(oversizedOutgoingPayload) == nil
                && contentFingerprint(oversizedOutgoingPayload) == nil,
            "a payload this build would reject must never be published"
        )
        let olderReset = Aggregator.utcMidnightMs("2030-01-01")
        let olderBudget = SyncedCycleBudget(
            resetDayMs: olderReset, budgetUSD: 125,
            updatedAtMs: sampleStart - 3_600_000,
            sourceMachineId: "self"
        )
        let multiCycle = project(
            [], creditSamples: sampleFixture + [
                CreditSample(
                    capturedAtMs: sampleStart - 3_600_000,
                    serverAtMs: nil,
                    resetAtMs: olderReset,
                    creditsUsed: 75
                )
            ],
            cycleBudgets: [budgetFixture, olderBudget],
            accountFingerprint: "same-account",
            machineId: "self", label: nil, updatedAt: ""
        )
        precondition(
            Set((multiCycle.creditSamples ?? []).map {
                CreditCycleSummary.dayStart(for: $0.resetAtMs)
            }) == Set([olderReset, reset]),
            "a sync payload must retain every locally stored billing cycle"
        )
        let emptySelf = project(
            [], creditSamples: [], accountFingerprint: "same-account",
            machineId: "self", label: nil, updatedAt: "new"
        )
        let recoveredSelf = reconciledSelfPayload(
            local: emptySelf, remote: multiCycle, recoverRemoteHistory: true
        )
        precondition(
            recoveredSelf.creditSamples == multiCycle.creditSamples,
            "a recreated local database must recover this machine's remote history"
        )
        precondition(
            recoveredSelf.cycleBudgets == multiCycle.cycleBudgets,
            "a recreated local database must recover historical cycle budgets"
        )
        precondition(
            cycleBudget(
                resetDayMs: olderReset, local: [], localMachineId: "local",
                remotes: [multiCycle],
                accountFingerprint: "same-account"
            ) == olderBudget,
            "a remote-only cycle must retain the budget it was measured against"
        )
        let tiedBudgetA = SyncedCycleBudget(
            resetDayMs: olderReset, budgetUSD: 200,
            updatedAtMs: sampleStart, sourceMachineId: "machine-a"
        )
        let tiedBudgetZ = SyncedCycleBudget(
            resetDayMs: olderReset, budgetUSD: 100,
            updatedAtMs: sampleStart, sourceMachineId: "machine-z"
        )
        precondition(
            compactCycleBudgets([tiedBudgetA, tiedBudgetZ]).first == tiedBudgetZ
                && compactCycleBudgets([tiedBudgetZ, tiedBudgetA]).first == tiedBudgetZ,
            "simultaneous budget edits must resolve independently of input order"
        )
        let invalidLegacyBudget = SyncedCycleBudget(
            resetDayMs: reset, budgetUSD: 0.001,
            updatedAtMs: sampleStart, sourceMachineId: "self"
        )
        precondition(
            compactCycleBudgets([budgetFixture, invalidLegacyBudget])
                == [budgetFixture],
            "invalid legacy targets must be discarded before publishing"
        )
        let disconnectedSelf = project(
            [], machineId: "self", label: nil, updatedAt: "new"
        )
        precondition(
            reconciledSelfPayload(
                local: disconnectedSelf, remote: multiCycle,
                recoverRemoteHistory: true
            ).accountFingerprint == "same-account",
            "a disconnected install must preserve its published counter identity"
        )
        let switchedAccount = project(
            [], creditSamples: [], accountFingerprint: "different-account",
            machineId: "self", label: nil, updatedAt: "new"
        )
        precondition(
            {
                let recovered = reconciledSelfPayload(
                local: switchedAccount, remote: multiCycle,
                recoverRemoteHistory: true
                )
                return recovered.creditSamples?.isEmpty == true
                    && recovered.cycleBudgets?.isEmpty == true
            }(),
            "self recovery must not import history from a different account"
        )
        precondition(
            {
                let routine = reconciledSelfPayload(
                local: emptySelf, remote: multiCycle,
                recoverRemoteHistory: false
                )
                return routine.creditSamples?.isEmpty == true
                    && routine.cycleBudgets?.isEmpty == true
            }(),
            "routine sync must not resurrect observations removed by retention"
        )
        let completedDayStart = sampleStart - 2 * 86_400_000
        let completedFixture = [
            CreditSample(
                capturedAtMs: completedDayStart, serverAtMs: nil,
                resetAtMs: olderReset, creditsUsed: 10
            ),
            CreditSample(
                capturedAtMs: completedDayStart + 3_600_000, serverAtMs: nil,
                resetAtMs: olderReset, creditsUsed: 20
            ),
            CreditSample(
                capturedAtMs: completedDayStart + 8 * 3_600_000, serverAtMs: nil,
                resetAtMs: olderReset, creditsUsed: 30
            ),
            CreditSample(
                capturedAtMs: completedDayStart + 86_400_000, serverAtMs: nil,
                resetAtMs: olderReset, creditsUsed: 40
            ),
            CreditSample(
                capturedAtMs: completedDayStart + 90_000_000, serverAtMs: nil,
                resetAtMs: olderReset, creditsUsed: 60
            ),
            CreditSample(
                capturedAtMs: completedDayStart + 93_600_000, serverAtMs: nil,
                resetAtMs: olderReset, creditsUsed: 50
            )
        ]
        let completedCompaction = compactCreditSamples(
            sampleFixture + completedFixture
        ).filter {
            CreditCycleSummary.dayStart(for: $0.resetAtMs) == olderReset
        }
        precondition(
            completedCompaction.map(\.creditsUsed) == [10, 30, 40, 60, 50],
            "completed cycles must retain each UTC day's first, peak and last observation"
        )
        let fullCompletedTimeline = CreditTimeline.build(samples: completedFixture)
        let compactedCompletedTimeline = CreditTimeline.build(
            samples: completedCompaction
        )
        precondition(
            fullCompletedTimeline.observedCredits
                == compactedCompletedTimeline.observedCredits
                && Dictionary(uniqueKeysWithValues: fullCompletedTimeline.daily.map {
                    ($0.day, $0.credits)
                }) == Dictionary(uniqueKeysWithValues: compactedCompletedTimeline.daily.map {
                    ($0.day, $0.credits)
                }),
            "daily high-water compaction must preserve correction-aware attribution"
        )
        let clockBoundaryFixture = [
            CreditSample(
                capturedAtMs: completedDayStart + CreditCycleSummary.dayMs + 60_000,
                serverAtMs: completedDayStart + CreditCycleSummary.dayMs - 60_000,
                resetAtMs: olderReset, creditsUsed: 70
            ),
            CreditSample(
                capturedAtMs: completedDayStart + CreditCycleSummary.dayMs + 120_000,
                serverAtMs: completedDayStart + CreditCycleSummary.dayMs - 30_000,
                resetAtMs: olderReset, creditsUsed: 75
            ),
            CreditSample(
                capturedAtMs: completedDayStart + CreditCycleSummary.dayMs + 43_200_000,
                serverAtMs: completedDayStart + CreditCycleSummary.dayMs + 43_200_000,
                resetAtMs: olderReset, creditsUsed: 80
            )
        ]
        let clockBoundaryCompaction = compactCreditSamples(
            sampleFixture + clockBoundaryFixture
        )
        precondition(
            clockBoundaryCompaction.contains(clockBoundaryFixture[1]),
            "server time must own UTC-day compaction across a capture-time boundary"
        )
        // This is a valid upper-shape fixture, not malformed input: non-midnight
        // resets can make each completed cycle touch an extra UTC day, with three
        // distinct correction-aware observations retained for each day.
        let detailedStart = Aggregator.utcMidnightMs("2031-01-01") + 60_000
        let detailedReset = detailedStart + 31 * CreditCycleSummary.dayMs
        var retentionFixture = [CreditSample(
            capturedAtMs: detailedStart, serverAtMs: nil,
            resetAtMs: detailedReset, creditsUsed: 0
        )]
        for index in 1...2_976 {
            retentionFixture.append(CreditSample(
                capturedAtMs: detailedStart - 60_000 + Int64(index) * 900_000,
                serverAtMs: nil, resetAtMs: detailedReset,
                creditsUsed: Double(index)
            ))
        }
        for cycle in 0..<12 {
            let completedReset = detailedReset
                - Int64(cycle + 1) * 31 * CreditCycleSummary.dayMs
            let firstDay = detailedStart
                - Int64(cycle + 2) * 40 * CreditCycleSummary.dayMs
            for day in 0..<32 {
                let start = firstDay + Int64(day) * CreditCycleSummary.dayMs
                retentionFixture += [
                    CreditSample(
                        capturedAtMs: start + 60_000, serverAtMs: nil,
                        resetAtMs: completedReset, creditsUsed: Double(day * 10)
                    ),
                    CreditSample(
                        capturedAtMs: start + 30_000_000, serverAtMs: nil,
                        resetAtMs: completedReset, creditsUsed: Double(day * 10 + 9)
                    ),
                    CreditSample(
                        capturedAtMs: start + 60_000_000, serverAtMs: nil,
                        resetAtMs: completedReset, creditsUsed: Double(day * 10 + 5)
                    )
                ]
            }
        }
        let validRetention = compactCreditSamples(retentionFixture)
        precondition(
            validRetention.count == retentionFixture.count
                && validRetention.count > 4_096,
            "the documented thirteen-cycle retention shape must not hit the ceiling"
        )

        let oversizedFixture = (0..<(maximumSyncedCreditSamples + 104)).map { index in
            CreditSample(
                capturedAtMs: sampleStart + Int64(index) * 900_000,
                serverAtMs: nil, resetAtMs: reset,
                creditsUsed: Double(index)
            )
        }
        precondition(
            compactCreditSamples(oversizedFixture).count
                == maximumSyncedCreditSamples,
            "malformed or oversized counter history must respect the payload ceiling"
        )
        let remoteOnlyReset = Aggregator.utcMidnightMs("2030-03-01")
        let mergedCycles = mergedCreditCycles(
            local: [CreditCycleSummary(latestSample: sampleFixture.last!)],
            additionalSamples: [
                CreditSample(
                    capturedAtMs: sampleStart - 3_600_000,
                    serverAtMs: nil,
                    resetAtMs: olderReset,
                    creditsUsed: 75
                ),
                CreditSample(
                    capturedAtMs: sampleStart + 7_200_000,
                    serverAtMs: nil,
                    resetAtMs: remoteOnlyReset,
                    creditsUsed: 12
                )
            ]
        )
        precondition(
            mergedCycles.map(\.resetDayMs)
                == [remoteOnlyReset, reset, olderReset],
            "a cycle observed only on another Mac must appear in navigation"
        )
        let currentNow = ISO8601DateFormatter().date(
            from: "2030-02-10T12:00:00Z"
        )!
        let remoteCurrentSample = CreditSample(
            capturedAtMs: Int64(currentNow.timeIntervalSince1970 * 1000),
            serverAtMs: Int64(currentNow.timeIntervalSince1970 * 1000),
            resetAtMs: remoteOnlyReset, creditsUsed: 125
        )
        let remoteCurrent = project(
            [], creditSamples: [remoteCurrentSample],
            accountFingerprint: "same-account",
            machineId: "remote", label: nil, updatedAt: ""
        )
        let expiredLocal = CreditSample(
            capturedAtMs: sampleStart, serverAtMs: sampleStart,
            resetAtMs: olderReset, creditsUsed: 500
        )
        let remoteObservation = currentCreditObservation(
            local: expiredLocal, remotes: [remoteCurrent],
            accountFingerprint: "same-account", now: currentNow
        )
        precondition(
            remoteObservation?.sample == remoteCurrentSample
                && remoteObservation?.cameFromRemote == true,
            "a peer's rollover observation must drive the current dashboard"
        )
        let tiedObservation = currentCreditObservation(
            local: remoteCurrentSample, remotes: [remoteCurrent],
            accountFingerprint: "same-account", now: currentNow
        )
        precondition(
            tiedObservation?.cameFromRemote == false,
            "an equally current direct observation must win over its synced copy"
        )
        let skewReset = Aggregator.utcMidnightMs("2030-04-01")
        let serverNewer = CreditSample(
            capturedAtMs: sampleStart,
            serverAtMs: sampleStart + 3_600_000,
            resetAtMs: skewReset,
            creditsUsed: 20
        )
        let clockAheadButOlder = CreditSample(
            capturedAtMs: sampleStart + 7_200_000,
            serverAtMs: sampleStart + 1_800_000,
            resetAtMs: skewReset,
            creditsUsed: 10
        )
        precondition(
            mergedCreditCycles(
                local: [CreditCycleSummary(latestSample: serverNewer)],
                additionalSamples: [clockAheadButOlder]
            ).first?.latestSample == serverNewer,
            "server time must outrank a skewed capture clock when merging cycles"
        )
        let legacyJSON = """
        {"schemaVersion":1,"machineId":"legacy","updatedAt":"","rows":[]}
        """
        let legacy = try! JSONDecoder().decode(
            MachineSyncPayload.self, from: Data(legacyJSON.utf8)
        )
        precondition(legacy.accountFingerprint == nil && legacy.creditSamples == nil
                     && legacy.exchangeRateSnapshot == nil,
                     "schema v1 payloads must remain readable during migration")
        let olderRate = ExchangeRateSnapshot(
            usdToAUD: 1.39,
            providerUpdatedAtUnix: rateFixture.providerUpdatedAtUnix - 86_400,
            providerNextUpdateAtUnix: rateFixture.providerUpdatedAtUnix
        )
        let invalidFutureRate = ExchangeRateSnapshot(
            usdToAUD: 9.99,
            providerUpdatedAtUnix: rateFixture.providerUpdatedAtUnix + 7 * 86_400,
            providerNextUpdateAtUnix: nil
        )
        precondition(
            ExchangeRateSnapshot.newestValid(
                [olderRate, invalidFutureRate, rateFixture],
                nowUnix: rateFixture.providerUpdatedAtUnix + 60
            ) == rateFixture,
            "newest valid provider vintage must win and future-dated quotes must be rejected"
        )
        let providerJSON = """
        {"result":"success","time_last_update_unix":1900000000,
         "time_next_update_unix":1900086400,"rates":{"AUD":1.405035}}
        """
        precondition(
            ExchangeRate.parseUSDToAUD(
                Data(providerJSON.utf8),
                now: Date(timeIntervalSince1970: 1_900_000_060)
            ) == rateFixture,
            "provider response must retain its rate vintage and next-update time"
        )
        let merged = mergedCreditSamples(
            local: sampleFixture,
            remotes: [decoded],
            resetAtMs: reset,
            accountFingerprint: "same-account"
        )
        precondition(merged.count == sampleFixture.count,
                     "remote observations must union with exact local duplicates, not sum")
        let shiftedReset = reset + 8 * 60 * 60 * 1000
        let coalesced = mergedCreditSamples(
            local: sampleFixture + [CreditSample(
                capturedAtMs: sampleStart + 7_200_000, serverAtMs: nil,
                resetAtMs: shiftedReset, creditsUsed: 115
            )],
            remotes: [], resetAtMs: reset,
            accountFingerprint: "same-account"
        )
        precondition(coalesced.count == sampleFixture.count + 1,
                     "same-day reset variants must merge into one synced cycle")
        var otherAccount = decoded
        otherAccount.accountFingerprint = "different-account"
        otherAccount.creditSamples = [
            SyncedCreditSample(CreditSample(
                capturedAtMs: sampleStart + 7_200_000, serverAtMs: nil,
                resetAtMs: reset, creditsUsed: 999
            ))
        ]
        let isolated = mergedCreditSamples(
            local: sampleFixture,
            remotes: [otherAccount],
            resetAtMs: reset,
            accountFingerprint: "same-account"
        )
        precondition(isolated.count == sampleFixture.count,
                     "counter observations from another account must be ignored")

        let gapStart = Aggregator.utcMidnightMs("2030-01-10") + 23 * 3_600_000
        let localGap = [
            CreditSample(capturedAtMs: gapStart, serverAtMs: nil, resetAtMs: reset, creditsUsed: 100),
            CreditSample(capturedAtMs: gapStart + 3 * 3_600_000, serverAtMs: nil, resetAtMs: reset, creditsUsed: 160)
        ]
        let remoteGap = project(
            [], creditSamples: [
                CreditSample(capturedAtMs: gapStart + 3_600_000, serverAtMs: nil, resetAtMs: reset, creditsUsed: 120),
                CreditSample(capturedAtMs: gapStart + 2 * 3_600_000, serverAtMs: nil, resetAtMs: reset, creditsUsed: 150)
            ],
            accountFingerprint: "same-account",
            machineId: "remote", label: nil, updatedAt: ""
        )
        let filledTimeline = CreditTimeline.build(samples: mergedCreditSamples(
            local: localGap, remotes: [remoteGap],
            resetAtMs: reset, accountFingerprint: "same-account"
        ))
        precondition(filledTimeline.observedCredits == 60
                     && filledTimeline.unallocatedCredits == 0,
                     "remote observations must fill a local cross-day sampling gap")

        struct S {
            var calls = 0; var credits = 0.0; var inTok = 0; var outTok = 0
            var sii = 0.0, soo = 0.0, sio = 0.0, sic = 0.0, soc = 0.0, scc = 0.0
        }
        var byModel: [String: S] = [:]
        for r in decoded.rows {
            var s = byModel[r.model] ?? S()
            s.calls += r.calls; s.credits += r.credits; s.inTok += r.inTok; s.outTok += r.outTok
            s.sii += r.sii; s.soo += r.soo; s.sio += r.sio; s.sic += r.sic; s.soc += r.soc; s.scc += r.scc
            byModel[r.model] = s
        }

        func approx(_ a: Double, _ b: Double) -> Bool {
            if a.isNaN && b.isNaN { return true }
            if a.isNaN != b.isNaN { return false }
            return abs(a - b) <= 1e-6 * max(1, abs(a), abs(b))
        }
        func fmtNaN(_ x: Double) -> String { x.isNaN ? "—" : String(format: "%.4f", x) }

        let err = FileHandle.standardError
        err.write(Data("verify-sync: \(range.from) → \(range.to) · \(decoded.rows.count) rows · \(byModel.count) models · \(data.count) bytes JSON\n".utf8))
        var allOK = byModel.count == raw.models.count
        for m in raw.models {
            guard let s = byModel[m.model] else { print("MISS \(m.model)"); allOK = false; continue }
            let f = Aggregator.fitRates(sii: s.sii, soo: s.soo, sio: s.sio, sic: s.sic, soc: s.soc, scc: s.scc)
            let ok = s.calls == m.calls && approx(s.credits, m.credits)
                && approx(f.inRate, m.inRate) && approx(f.outRate, m.outRate) && approx(f.fit, m.fit)
            if !ok { allOK = false }
            print("\(ok ? "OK " : "XX ") \(m.model)  credits raw=\(Fmt.credits4(m.credits)) agg=\(Fmt.credits4(s.credits))  fit raw=\(fmtNaN(m.fit)) agg=\(fmtNaN(f.fit))")
        }
        precondition(allOK,
                     "sync aggregate does not reproduce every raw model")
        err.write(Data(
            "verify-sync: PASS — aggregate reproduces the raw Models fit for every model\n".utf8
        ))

        // Always exercise persistence inside a throwaway database. Keeping the
        // isolation here means every caller—including `make verify` and CI—runs
        // these checks without needing environment-variable ceremony.
        RemoteStore.withTemporaryStore {
            RemoteStore.clear()
            var second = agg
            second.machineId = "second"
            second.updatedAt = "later"
            let initialWrite = RemoteStore.replaceAll([agg, second])
            let initial = RemoteStore.load()
            let replacementWrite = RemoteStore.replaceAll([agg])
            let reloaded = RemoteStore.load()
            let oversizedSnapshotRejected = !RemoteStore.replaceAll(Array(
                repeating: agg, count: maximumMachinePayloads + 1
            ))
            var invalid = agg
            invalid.exchangeRateSnapshot = ExchangeRateSnapshot(
                usdToAUD: .nan,
                providerUpdatedAtUnix: 1,
                providerNextUpdateAtUnix: nil
            )
            let rejectedInvalid = !RemoteStore.replaceAll([invalid])
            let retainedAfterRejection = RemoteStore.load()
            var future = agg
            future.schemaVersion = schemaVersion + 1
            let futureWrite = RemoteStore.replaceAll([future])
            let retainedAfterFutureRejection = RemoteStore.load()
            let restoreWrite = RemoteStore.replaceAll([agg])
            let emptyWrite = RemoteStore.replaceAll([])
            let emptySnapshot = RemoteStore.load()
            let rtOK = initialWrite && replacementWrite
                && oversizedSnapshotRejected && rejectedInvalid
                && !futureWrite && restoreWrite
                && emptyWrite
                && initial?.count == 2
                && Set(initial?.map(\.machineId) ?? [])
                    == Set([agg.machineId, "second"])
                && reloaded?.count == 1
                && reloaded?.first?.machineId == agg.machineId
                && reloaded?.first?.rows.count == agg.rows.count
                && reloaded?.first?.creditSamples?.count
                    == agg.creditSamples?.count
                && reloaded?.first?.cycleBudgets == agg.cycleBudgets
                && reloaded?.first?.exchangeRateSnapshot
                    == agg.exchangeRateSnapshot
                && retainedAfterRejection?.count == 1
                && retainedAfterRejection?.first?.machineId == agg.machineId
                && retainedAfterFutureRejection?.count == 1
                && retainedAfterFutureRejection?.first?.machineId == agg.machineId
                && emptySnapshot?.isEmpty == true
            precondition(rtOK,
                         "remote snapshot persistence verification failed")
            err.write(Data(
                "remote-store: PASS — snapshots replace atomically, reject future schemas and reload intact (\(reloaded?.first?.rows.count ?? 0) rows)\n".utf8
            ))
        }
    }

    // -----------------------------------------------------------------------
    // Combined-view preview (--sync-preview): pool this machine's real aggregate
    // with ONE simulated identical second machine (a mirror), so the combined
    // total is an obvious ×2. Demonstrates the payoff before any UI/transport.
    // -----------------------------------------------------------------------
    static func preview() {
        let (records, _) = DataSources.loadAll()
        let local = project(records, machineId: "this-mac", label: "this machine", updatedAt: "")
        // Real sync pulls each OTHER machine's actual aggregate; here we mirror.
        let sim = MachineSyncPayload(schemaVersion: schemaVersion, machineId: "sim-mac-2",
                                   machineLabel: "simulated machine 2", updatedAt: "", rows: local.rows)

        func perModel(_ macs: [MachineSyncPayload]) -> [String: (calls: Int, credits: Double)] {
            var m: [String: (Int, Double)] = [:]
            for mac in macs { for r in mac.rows {
                var t = m[r.model] ?? (0, 0.0); t.0 += r.calls; t.1 += r.credits; m[r.model] = t
            } }
            return m
        }
        let localM = perModel([local]), combM = perModel([local, sim])
        let localTotal = local.rows.reduce(0.0) { $0 + $1.credits }
        let combTotal = [local, sim].flatMap { $0.rows }.reduce(0.0) { $0 + $1.credits }
        func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }

        let err = FileHandle.standardError
        err.write(Data("sync-preview: simulating ONE identical second machine (a mirror); real sync pulls each other machine's actual aggregate.\n".utf8))
        err.write(Data("Summary / Models / Daily / total combine across machines; Sessions & Top stay per-machine.\n\n".utf8))
        print(pad("model", 24) + pad("this machine", 22) + "combined (2 machines)")
        for model in localM.keys.sorted(by: { (localM[$0]?.credits ?? 0) > (localM[$1]?.credits ?? 0) }) {
            let l = localM[model]!, c = combM[model] ?? (0, 0.0)
            print(pad(model, 24) + pad("\(Fmt.cost(l.credits)) (\(l.calls))", 22) + "\(Fmt.cost(c.credits)) (\(c.calls))")
        }
        print(pad("TOTAL", 24) + pad(Fmt.cost(localTotal), 22) + Fmt.cost(combTotal))
    }
}
