import Foundation

// ---------------------------------------------------------------------------
// SyncAggregate — the compact per-(UTC-day, model, level) projection of this
// machine's raw cache that gets synced between machines. NEVER raw spans.
//
// Each row carries the regression cross-products (sii…scc) alongside the totals,
// so summing rows — across days, levels, or machines — reconstructs the
// Models-tab effective-rate fit exactly (summation is associative; the fit is a
// pure function of those sums). Bucketing by (day, model, level) preserves the
// 0.6.0 reasoning-level breakdown in the combined multi-machine view.
//
// This file is transport-agnostic: it computes and (de)serializes the aggregate.
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

/// One machine's full aggregate (one file per machine on the sync backend).
struct MachineAggregate: Codable {
    var schemaVersion: Int
    var machineId: String
    var machineLabel: String?
    var updatedAt: String     // ISO8601 UTC
    var rows: [AggregateRow]
}

enum SyncAggregate {
    static let schemaVersion = 1

    /// Project raw records into per-(UTC-day, model, level) aggregate rows.
    static func project(_ records: [UsageRecord],
                        machineId: String, label: String?, updatedAt: String) -> MachineAggregate {
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
        return MachineAggregate(schemaVersion: schemaVersion, machineId: machineId,
                                machineLabel: label, updatedAt: updatedAt, rows: rows)
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
        let agg = project(records, machineId: "self", label: "verify", updatedAt: "")
        let data = try! JSONEncoder().encode(agg)
        let decoded = try! JSONDecoder().decode(MachineAggregate.self, from: data)

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
        let sim = MachineAggregate(schemaVersion: schemaVersion, machineId: "sim-mac-2",
                                   machineLabel: "simulated machine 2", updatedAt: "", rows: local.rows)

        func perModel(_ macs: [MachineAggregate]) -> [String: (calls: Int, credits: Double)] {
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
