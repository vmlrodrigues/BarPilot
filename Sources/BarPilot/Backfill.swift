import Foundation

// ---------------------------------------------------------------------------
// ChatBackfill — one-time recovery of pre-OTel usage history.
//
// GitHub usage-based billing began 2026-06-01; from then on the VS Code Copilot
// chat session files record the exact per-request credit ("<Model> • N credits").
// But OTel's agent-traces.db only retains ~7 days, so on install the window
// [2026-06-01 → earliest OTel span] is missing. This reads the chat files and
// backfills that window EXACTLY — recorded credits only, NO estimation.
//
// Runs at most once (gated by an in-DB `backfill_version`), is fully additive
// (INSERT OR IGNORE), tags its rows `source = chatBackfill` (so it's reversible),
// and takes a one-time cache backup before its first run.
// ---------------------------------------------------------------------------

enum ChatBackfill {
    /// Bump to force a one-time re-run for everyone (e.g. parser fix / wider floor).
    static let version = 1
    /// Usage-based billing start; no recorded credit exists before it.
    static let floorDate = "2026-06-01"

    private struct Acc {
        var credit = 0.0
        var ts: Int64?
        var model: String?
        var inTok = 0
        var outTok = 0
        var session = ""
    }

    // -----------------------------------------------------------------------
    // Orchestration — gated, once-only, atomic, with a one-time backup.
    // -----------------------------------------------------------------------
    static func run() {
        let stored = Int(SpanCache.getMeta("backfill_version") ?? "0") ?? 0
        guard stored < version else { return }   // already done — the scan never runs again

        SpanCache.backupOnce(tag: "pre-backfill-v\(version)")

        let floorMs = Aggregator.utcMidnightMs(floorDate)
        // Date-partition dedup: fill only dates strictly before the earliest OTel
        // span already cached; OTel owns everything from there forward. With no
        // OTel data at all, fill right up to now.
        let boundary = SpanCache.earliestOTelMs() ?? Int64(Date().timeIntervalSince1970 * 1000)
        let recs = (boundary > floorMs) ? loadRecords(floorMs: floorMs, upToMs: boundary) : []
        SpanCache.mergeBackfill(recs, version: version)   // insert + version, one transaction
    }

    // -----------------------------------------------------------------------
    // Parser — recorded-credit requests in [floorMs, upToMs), deduped by responseId.
    // -----------------------------------------------------------------------
    static func loadRecords(floorMs: Int64, upToMs: Int64) -> [UsageRecord] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let wsRoot = home + "/Library/Application Support/Code/User/workspaceStorage"
        guard let hashes = try? fm.contentsOfDirectory(atPath: wsRoot) else { return [] }

        var seen: [String: Acc] = [:]
        let creditsNeedle = Data("credits".utf8)

        for h in hashes {
            let dir = wsRoot + "/" + h + "/chatSessions"
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for f in files where f.hasSuffix(".json") || f.hasSuffix(".jsonl") {
                let p = dir + "/" + f
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: p)) else { continue }
                // Cheap filter: only fully parse files that contain a recorded credit.
                guard data.range(of: creditsNeedle) != nil else { continue }
                let session = (f as NSString).deletingPathExtension
                for doc in parse(data) { harvest(doc, session: session, into: &seen) }
            }
        }

        var out: [UsageRecord] = []
        for (rid, a) in seen {
            guard let ts = a.ts, a.credit > 0, ts >= floorMs, ts < upToMs else { continue }
            out.append(UsageRecord(
                source: .chatBackfill, spanId: rid,
                model: Aggregator.normaliseModel(a.model ?? "unknown"), startMs: ts,
                credits: a.credit, inputTokens: a.inTok, outputTokens: a.outTok,
                conversationId: nil, chatSessionId: a.session, operationName: "chat"))
        }
        return out
    }

    private static func parse(_ data: Data) -> [Any] {
        if let obj = try? JSONSerialization.jsonObject(with: data) { return [obj] }   // whole-document .json
        guard let s = String(data: data, encoding: .utf8) else { return [] }
        var out: [Any] = []
        for line in s.split(separator: "\n") {                                        // append-log .jsonl
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if let d = t.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) { out.append(o) }
        }
        return out
    }

    private static let creditRe = try! NSRegularExpression(pattern: "([0-9.]+)\\s*credits", options: [.caseInsensitive])

    /// For each request-bearing object (has `responseId`/`requestId`), pull the
    /// recorded credit + newest timestamp + model + tokens from its subtree.
    /// First credit per id wins; an entry gains a timestamp if a later occurrence
    /// carries one (mirrors the validated extractor).
    private static func harvest(_ o: Any, session: String, into seen: inout [String: Acc]) {
        if let arr = o as? [Any] {
            for x in arr { harvest(x, session: session, into: &seen) }
            return
        }
        guard let d = o as? [String: Any] else { return }
        if let rid = (d["responseId"] as? String) ?? (d["requestId"] as? String),
           let credit = subtreeCredit(d) {
            var a = seen[rid] ?? Acc()
            if a.credit == 0 {
                a.credit = credit
                a.model = subtreeModel(d)
                a.inTok = subtreeInt(d, "promptTokens")
                a.outTok = subtreeInt(d, "completionTokens")
                a.session = session
            }
            if a.ts == nil, let t = subtreeTs(d) { a.ts = t }
            seen[rid] = a
        }
        for (_, v) in d { harvest(v, session: session, into: &seen) }
    }

    private static func subtreeCredit(_ o: Any) -> Double? {
        if let arr = o as? [Any] {
            for x in arr { if let c = subtreeCredit(x) { return c } }
        } else if let d = o as? [String: Any] {
            if let det = d["details"] as? String {
                let r = NSRange(det.startIndex..., in: det)
                if let m = creditRe.firstMatch(in: det, range: r), let rr = Range(m.range(at: 1), in: det) {
                    return Double(det[rr])
                }
            }
            for (_, v) in d { if let c = subtreeCredit(v) { return c } }
        }
        return nil
    }

    /// Prefer `resolvedModel` (the API id, e.g. "claude-opus-4-6") found ANYWHERE
    /// in the subtree — it normalises to the same canonical form as the OTel
    /// sources so backfilled rows merge with live data. Fall back to the human
    /// "<Model> • …" prefix only when no resolvedModel exists.
    private static func subtreeModel(_ o: Any) -> String? {
        findResolved(o) ?? findDetailsPrefix(o)
    }

    private static func findResolved(_ o: Any) -> String? {
        if let arr = o as? [Any] {
            for x in arr { if let m = findResolved(x) { return m } }
        } else if let d = o as? [String: Any] {
            if let rm = d["resolvedModel"] as? String, !rm.isEmpty { return rm }
            for (_, v) in d { if let m = findResolved(v) { return m } }
        }
        return nil
    }

    private static func findDetailsPrefix(_ o: Any) -> String? {
        if let arr = o as? [Any] {
            for x in arr { if let m = findDetailsPrefix(x) { return m } }
        } else if let d = o as? [String: Any] {
            if let det = d["details"] as? String, det.contains("•") {
                let pre = det.components(separatedBy: "•").first?.trimmingCharacters(in: .whitespaces)
                if let pre, !pre.isEmpty { return pre }
            }
            for (_, v) in d { if let m = findDetailsPrefix(v) { return m } }
        }
        return nil
    }

    private static func subtreeTs(_ o: Any) -> Int64? {
        var best: Int64?
        func w(_ v: Any) {
            if let arr = v as? [Any] { for x in arr { w(x) } }
            else if let d = v as? [String: Any] {
                for k in ["completedAt", "creationDate", "timestamp"] {
                    if let n = d[k] as? NSNumber {
                        let t = n.doubleValue
                        if t > 1e12 { let ti = Int64(t); if best == nil || ti > best! { best = ti } }
                    }
                }
                for (_, vv) in d { w(vv) }
            }
        }
        w(o); return best
    }

    private static func subtreeInt(_ o: Any, _ key: String) -> Int {
        var found = 0
        func w(_ v: Any) {
            if found > 0 { return }
            if let arr = v as? [Any] { for x in arr { w(x) } }
            else if let d = v as? [String: Any] {
                if let n = d[key] as? NSNumber { found = n.intValue; return }
                for (_, vv) in d { w(vv) }
            }
        }
        w(o); return found
    }
}
