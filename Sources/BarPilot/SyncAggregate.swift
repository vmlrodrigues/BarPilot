import Foundation

// ---------------------------------------------------------------------------
// SyncAggregate — the versioned per-machine payload used for multi-Mac sync.
//
// Counter observations are account-wide and are merged, never summed. Legacy
// telemetry aggregates remain in schema v2 only while the old interface is
// available. No raw spans, prompts, or content are synced.
//
// This file is transport-agnostic: it computes and serializes the payload.
// Pushing/pulling it lives behind SyncBackend (added later).
// ---------------------------------------------------------------------------

/// One (UTC-day, model, reasoning-level) bucket with regression cross-products.
struct AggregateRow: Codable {
    var utcDay: String        // "YYYY-MM-DD", UTC
    var model: String         // normalized (Aggregator.normaliseModel)
    var level: String?        // normalized reasoning level; nil = none
    var calls: Int
    var credits: Double
    var inTok: Int
    var outTok: Int
    var sii: Double, soo: Double, sio: Double, sic: Double, soc: Double, scc: Double
}

struct SyncedCreditSample: Codable, Equatable {
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

/// One machine's complete versioned payload (one file per machine).
struct MachineSyncPayload: Codable {
    var schemaVersion: Int
    var machineId: String
    var machineLabel: String?
    var updatedAt: String     // ISO8601 UTC
    var rows: [AggregateRow]
    var accountFingerprint: String? = nil
    var creditSamples: [SyncedCreditSample]? = nil
    var exchangeRateSnapshot: ExchangeRateSnapshot? = nil
}

enum SyncAggregate {
    static let schemaVersion = 2

    /// Project local-only data into the payload for this machine. Re-publishing
    /// pulled observations would create feedback loops, so callers must never pass
    /// remote samples here.
    static func project(_ records: [UsageRecord], creditSamples: [CreditSample] = [],
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
        }
        return MachineSyncPayload(
            schemaVersion: schemaVersion, machineId: machineId,
            machineLabel: label, updatedAt: updatedAt, rows: rows,
            accountFingerprint: accountFingerprint,
            creditSamples: accountFingerprint == nil
                ? nil
                : compactCreditSamples(creditSamples).map(SyncedCreditSample.init),
            exchangeRateSnapshot: exchangeRateSnapshot
        )
    }

    /// Preserve the first local observation in each 15-minute UTC bucket. Local
    /// storage keeps every poll; immutable buckets keep sync to at most four
    /// payload updates per hour and about 3,000 rows per 31-day cycle.
    static func compactCreditSamples(_ samples: [CreditSample]) -> [CreditSample] {
        struct Bucket: Hashable {
            var resetAtMs: Int64
            var quarterHour: Int64
        }
        let ordered = samples.sorted { $0.capturedAtMs < $1.capturedAtMs }
        var firstByBucket: [Bucket: CreditSample] = [:]
        for sample in ordered {
            let bucket = Bucket(
                resetAtMs: sample.resetAtMs,
                quarterHour: sample.capturedAtMs / (15 * 60 * 1000)
            )
            if firstByBucket[bucket] == nil {
                firstByBucket[bucket] = sample
            }
        }
        return firstByBucket.values
            .sorted { $0.capturedAtMs < $1.capturedAtMs }
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
        var seen: Set<Key> = []
        return (local + remote)
            .filter { $0.resetAtMs == resetAtMs }
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

    // -----------------------------------------------------------------------
    // Self-consistency check (--verify-sync): projecting the raw cache, then
    // JSON round-tripping and summing back per model, must reproduce the raw
    // Models-tab fit exactly. Proves the core claim before any transport exists.
    // -----------------------------------------------------------------------
    static func verifySelfConsistency() {
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
        let agg = project(
            records, creditSamples: sampleFixture,
            accountFingerprint: "same-account",
            exchangeRateSnapshot: rateFixture,
            machineId: "self", label: nil, updatedAt: ""
        )
        let data = try! JSONEncoder().encode(agg)
        let decoded = try! JSONDecoder().decode(MachineSyncPayload.self, from: data)
        precondition(decoded.schemaVersion == 2 && decoded.creditSamples?.count == 2
                     && decoded.exchangeRateSnapshot == rateFixture,
                     "sync v2 must round-trip counter observations and the exchange-rate snapshot")
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
        var allOK = true
        for m in raw.models {
            guard let s = byModel[m.model] else { print("MISS \(m.model)"); allOK = false; continue }
            let f = Aggregator.fitRates(sii: s.sii, soo: s.soo, sio: s.sio, sic: s.sic, soc: s.soc, scc: s.scc)
            let ok = s.calls == m.calls && approx(s.credits, m.credits)
                && approx(f.inRate, m.inRate) && approx(f.outRate, m.outRate) && approx(f.fit, m.fit)
            if !ok { allOK = false }
            print("\(ok ? "OK " : "XX ") \(m.model)  credits raw=\(Fmt.credits4(m.credits)) agg=\(Fmt.credits4(s.credits))  fit raw=\(fmtNaN(m.fit)) agg=\(fmtNaN(f.fit))")
        }
        err.write(Data((allOK
            ? "verify-sync: PASS — aggregate reproduces the raw Models fit for every model\n"
            : "verify-sync: FAIL — see mismatches above\n").utf8))

        // RemoteStore round-trip — only when a temp path is set, so a plain
        // `--verify-sync` never mutates the real remote-aggregate cache.
        if ProcessInfo.processInfo.environment["BARPILOT_REMOTE_PATH"] != nil {
            RemoteStore.clear()
            RemoteStore.save(agg)
            let reloaded = RemoteStore.load()
            let rtOK = reloaded.count == 1
                && reloaded.first?.machineId == agg.machineId
                && reloaded.first?.rows.count == agg.rows.count
                && reloaded.first?.creditSamples?.count == agg.creditSamples?.count
                && reloaded.first?.exchangeRateSnapshot == agg.exchangeRateSnapshot
            err.write(Data((rtOK
                ? "remote-store: PASS — aggregate persisted and reloaded intact (\(reloaded.first?.rows.count ?? 0) rows)\n"
                : "remote-store: FAIL — persistence round-trip mismatch\n").utf8))
        } else {
            err.write(Data("remote-store: SKIPPED (set BARPILOT_REMOTE_PATH to a temp file to test it)\n".utf8))
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
