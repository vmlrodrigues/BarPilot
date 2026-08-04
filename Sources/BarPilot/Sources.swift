import Foundation
import SQLite3

// ---------------------------------------------------------------------------
// Data-source loaders.
//
// Two sources, read directly with no network calls:
//   1. VS Code Copilot Chat  → SQLite (agent-traces.db)
//   2. GitHub Copilot Mac App → JSONL (agent-traces.jsonl)
//
// A missing source file is silently skipped. These run off the main actor.
// ---------------------------------------------------------------------------

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum DataSources {
    static func vscodeDBPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/Library/Application Support/Code/User/globalStorage/github.copilot-chat/agent-traces.db"
    }

    static func macAppJSONLPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/Library/Application Support/com.github.githubapp/agent-traces.jsonl"
    }

    /// Load every usage record from all available sources, plus a status report.
    /// Live records are merged into the local cache on every call; the full cache
    /// is returned so data survives source-file wipes caused by extension updates.
    static func loadAll() -> (records: [UsageRecord], status: SourcesStatus) {
        var status = SourcesStatus()
        var liveRecords: [UsageRecord] = []

        let dbPath = vscodeDBPath()
        if FileManager.default.fileExists(atPath: dbPath) {
            let recs = loadSQLite(path: dbPath)
            status.vscodeFound = true
            status.vscodeCount = recs.count
            liveRecords.append(contentsOf: recs)
        }

        let jsonlPath = macAppJSONLPath()
        var jsonlBytesScanned: Int64 = 0
        var pendingOffset: (stored: Int64, new: Int64)?
        if FileManager.default.fileExists(atPath: jsonlPath) {
            // Incremental: resume from the stored byte offset instead of re-reading
            // the whole (multi-GB) file on every reload. (#24)
            let stored = Int64(SpanCache.getMeta(Self.jsonlOffsetKey) ?? "") ?? 0
            let r = loadJSONL(path: jsonlPath, from: stored)
            pendingOffset = (stored, r.newOffset)   // persisted only after a successful merge (#28)
            jsonlBytesScanned = r.bytesScanned
            status.macAppFound = true
            liveRecords.append(contentsOf: r.records)
        }

        status.vscodeConfigured = isVSCodeTelemetryConfigured()
        status.macAppConfigured = isMacAppTelemetryConfigured()

        // Advance the JSONL offset ONLY once the records are committed. A failed
        // merge leaves the offset put, so the same bytes are re-read next time
        // (harmless — dedup is INSERT OR IGNORE) instead of being skipped
        // forever. Ordering matters here; don't move this back above. (#28)
        if SpanCache.merge(liveRecords) {
            if let (stored, new) = pendingOffset, new != stored {
                SpanCache.setMeta(Self.jsonlOffsetKey, "\(new)")
            }
        } else {
            DiagLog.write("WARNING: cache merge failed — keeping JSONL offset so \(liveRecords.count) record(s) are re-read next reload")
        }
        ReasoningLevelBackfill.run(liveRecords: liveRecords)  // one-time, gated: fill levels on already-cached spans
        ChatBackfill.run()   // one-time, gated: recover pre-OTel June history from chat files

        let cached = SpanCache.load()
        // Has each source EVER captured usage? The cache survives extension wipes,
        // so this is the reliable signal — not the live count. VS Code includes its
        // chat backfill. Used to suppress the restart nudge for a working source
        // whose live DB is momentarily empty (#21).
        let present = Set(cached.map(\.source))
        status.vscodeEverCaptured = present.contains(.vscode) || present.contains(.chatBackfill)
        status.macAppEverCaptured = present.contains(.macApp)

        // Badge counts come from the CACHE, not this reload's live read: with
        // incremental loading a reload normally sees 0 new records, and the cache
        // is what actually backs the totals. Also makes both badges consistent —
        // previously a wiped live DB showed "VS Code · 0" despite cached history.
        let counts = SpanCache.countsBySource()
        status.vscodeCount = (counts[SourceKind.vscode.rawValue] ?? 0) + (counts[SourceKind.chatBackfill.rawValue] ?? 0)
        status.macAppCount = counts[SourceKind.macApp.rawValue] ?? 0

        // Staleness inputs (#27): newest usage per source + when each source file
        // last changed. A source that has captured before but has gone quiet is
        // the shape of "the app stopped exporting".
        let newest = SpanCache.newestBySource()
        status.vscodeNewestMs = [newest[SourceKind.vscode.rawValue], newest[SourceKind.chatBackfill.rawValue]]
            .compactMap { $0 }.max()
        status.macAppNewestMs = newest[SourceKind.macApp.rawValue]
        func modified(_ p: String) -> Date? {
            (try? FileManager.default.attributesOfItem(atPath: p)[.modificationDate] as? Date).flatMap { $0 }
        }
        status.vscodeFileModified = modified(dbPath)
        status.macAppFileModified = modified(jsonlPath)

        // Exporter watchdog inputs (#27): has the JSONL grown since we last
        // looked? The Copilot app heartbeats into it every ~10s regardless of
        // user activity, so "running but not growing" means the exporter is dead.
        // Persisted in meta so restarting BarPilot doesn't erase the evidence.
        let now = Date().timeIntervalSince1970
        if status.macAppFound {
            let size = (try? FileManager.default.attributesOfItem(atPath: jsonlPath)[.size] as? Int64).flatMap { $0 } ?? 0
            let lastSize = Int64(SpanCache.getMeta(Self.jsonlSizeKey) ?? "") ?? -1
            let lastGrowth = Double(SpanCache.getMeta(Self.jsonlGrowthAtKey) ?? "") ?? now
            if size != lastSize {
                SpanCache.setMeta(Self.jsonlSizeKey, "\(size)")
                SpanCache.setMeta(Self.jsonlGrowthAtKey, "\(now)")
                status.macAppSecondsSinceGrowth = 0
            } else {
                status.macAppSecondsSinceGrowth = max(0, now - lastGrowth)
            }
        }
        if let last = Double(SpanCache.getMeta(Self.lastCheckAtKey) ?? "") {
            status.gapSinceLastCheck = max(0, now - last)
        }
        SpanCache.setMeta(Self.lastCheckAtKey, "\(now)")

        status.newRecords = liveRecords.count
        status.jsonlBytesScanned = jsonlBytesScanned
        status.jsonlOffset = Int64(SpanCache.getMeta(Self.jsonlOffsetKey) ?? "") ?? 0
        return (cached, status)
    }

    /// Meta key for the JSONL read offset (#24).
    static let jsonlOffsetKey = "macAppJSONLOffset"
    /// Exporter-watchdog bookkeeping (#27).
    static let jsonlSizeKey = "macAppJSONLLastSize"
    static let jsonlGrowthAtKey = "macAppJSONLLastGrowthAt"
    static let lastCheckAtKey = "lastSourceCheckAt"

    // -----------------------------------------------------------------------
    // Incremental-read verifier (--verify-incremental).
    //
    // The offset logic is the one risky part of #24: advancing past a partially
    // written line would drop that usage record permanently. This builds a
    // synthetic JSONL in a temp dir and proves, on a fixed fixture, that
    // incremental reads never lose or double-count a record and that a truncated
    // file falls back to a full re-scan.
    // -----------------------------------------------------------------------
    static func verifyIncremental() {
        let err = FileHandle.standardError
        var pass = 0, fail = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { pass += 1 } else { fail += 1 }
            err.write(Data("  [\(ok ? "OK" : "XX")] \(name)\(detail.isEmpty ? "" : " — \(detail)")\n".utf8))
        }
        func span(_ id: String, aiu: Double) -> String {
            """
            {"spanId":"\(id)","name":"chat","attributes":{"github.copilot.aiu":\(aiu),\
            "gen_ai.response.model":"claude-sonnet-4-6","gen_ai.usage.input_tokens":10,\
            "gen_ai.usage.output_tokens":5},"startTimeUnixNano":1750000000000000000}
            """
        }
        let dir = NSTemporaryDirectory() + "barpilot-verify-\(ProcessInfo.processInfo.processIdentifier)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/t.jsonl"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        func write(_ s: String) { try? s.write(toFile: path, atomically: false, encoding: .utf8) }

        // 1. Full scan of two complete lines + an unrelated (no-aiu) line.
        let first = span("a", aiu: 1e9) + "\n" + #"{"spanId":"noise","name":"x"}"# + "\n" + span("b", aiu: 2e9) + "\n"
        write(first)
        let r1 = loadJSONL(path: path, from: 0)
        check("full scan finds both usage spans", r1.records.count == 2, "got \(r1.records.count)")
        check("offset lands at EOF on a newline-terminated file", r1.newOffset == Int64(first.utf8.count))

        // 2. Nothing appended → no work, no records, offset unchanged.
        let r2 = loadJSONL(path: path, from: r1.newOffset)
        check("no-op when nothing appended", r2.records.isEmpty && r2.newOffset == r1.newOffset)

        // 3. Append one complete line + a PARTIAL line (mid-write flush).
        let partial = span("c", aiu: 3e9) + "\n" + String(span("d", aiu: 4e9).prefix(40))
        write(first + partial)
        let r3 = loadJSONL(path: path, from: r2.newOffset)
        check("incremental picks up the complete appended span", r3.records.count == 1 && r3.records.first?.spanId == "c")
        check("offset stops BEFORE the partial line (no data loss)",
              r3.newOffset == Int64((first + span("c", aiu: 3e9) + "\n").utf8.count))

        // 4. The partial line is completed → its record is still found.
        write(first + span("c", aiu: 3e9) + "\n" + span("d", aiu: 4e9) + "\n")
        let r4 = loadJSONL(path: path, from: r3.newOffset)
        check("completed line is recovered on the next read", r4.records.count == 1 && r4.records.first?.spanId == "d")

        // 5. Totals match a single full scan of the final file — no loss, no dupes.
        let full = loadJSONL(path: path, from: 0)
        let incrementalIds = Set((r1.records + r3.records + r4.records).map(\.spanId))
        check("incremental union == full scan", incrementalIds == Set(full.records.map(\.spanId)),
              "\(incrementalIds.count) vs \(full.records.count)")
        let incCredits = (r1.records + r3.records + r4.records).reduce(0.0) { $0 + $1.credits }
        check("credits match full scan", abs(incCredits - full.records.reduce(0.0) { $0 + $1.credits }) < 1e-9)

        // 6. Rotation / truncation: stored offset beyond EOF → full re-scan.
        write(span("z", aiu: 5e9) + "\n")
        let rot = loadJSONL(path: path, from: 999_999)
        check("truncated file re-scans from 0", rot.records.count == 1 && rot.records.first?.spanId == "z")

        err.write(Data("verify-incremental: \(fail == 0 ? "PASS" : "FAIL") — \(pass) ok, \(fail) failed\n".utf8))
    }

    // -----------------------------------------------------------------------
    // Telemetry-configuration detection (read-only).
    //
    // Detects whether OTel tracing was ever enabled, so the app can warn when a
    // source isn't producing data because telemetry was never turned on.
    // -----------------------------------------------------------------------

    /// VS Code settings.json must enable the three OTel keys.
    static func isVSCodeTelemetryConfigured() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = home + "/Library/Application Support/Code/User/settings.json"
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        let keys = [
            "github.copilot.chat.otel.enabled",
            "github.copilot.chat.otel.dbSpanExporter.enabled",
            "github.copilot.chat.otel.captureContent",
        ]
        // JSONC-tolerant: look for `"key" : true` (ignoring whitespace).
        return keys.allSatisfy { key in
            let escaped = NSRegularExpression.escapedPattern(for: key)
            let pattern = "\"\(escaped)\"\\s*:\\s*true"
            return content.range(of: pattern, options: .regularExpression) != nil
        }
    }

    /// The Mac App's OTel LaunchAgent + helper script must be installed.
    static func isMacAppTelemetryConfigured() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let plist = home + "/Library/LaunchAgents/com.github.githubapp.otel-env.plist"
        let helper = home + "/Library/Application Support/com.github.githubapp/copilot-otel-env"
        let fm = FileManager.default
        return fm.fileExists(atPath: plist) && fm.fileExists(atPath: helper)
    }
}

// ---------------------------------------------------------------------------
// SQLite source (VS Code Copilot Chat)
// ---------------------------------------------------------------------------

private func loadSQLite(path: String) -> [UsageRecord] {
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        if let db { sqlite3_close(db) }
        return []
    }
    defer { sqlite3_close(db) }

    let sql = """
    SELECT s.span_id, s.response_model, s.start_time_ms,
           s.input_tokens, s.output_tokens, s.conversation_id, s.chat_session_id,
           s.operation_name, sa.value,
           (SELECT value FROM span_attributes o
             WHERE o.span_id = s.span_id AND o.key = 'copilot_chat.request.options')
    FROM spans s
    JOIN span_attributes sa ON s.span_id = sa.span_id
    WHERE sa.key = 'copilot_chat.copilot_usage_nano_aiu'
    """

    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(stmt) }

    func text(_ i: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: c)
    }

    var out: [UsageRecord] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        let valStr = text(8) ?? "0"
        let nano = Double(valStr) ?? 0
        if nano == 0 { continue }

        out.append(UsageRecord(
            source: .vscode,
            spanId: text(0) ?? "",
            model: text(1),
            startMs: sqlite3_column_int64(stmt, 2),
            credits: nano / 1_000_000_000.0,
            inputTokens: Int(sqlite3_column_int64(stmt, 3)),
            outputTokens: Int(sqlite3_column_int64(stmt, 4)),
            conversationId: text(5),
            chatSessionId: text(6),
            operationName: text(7) ?? "",
            reasoningLevel: reasoningEffort(fromOptionsJSON: text(9))
        ))
    }
    return out
}

/// Pull the reasoning-effort level out of VS Code's `copilot_chat.request.options`
/// JSON blob (shape: `{"reasoning":{"effort":"medium",…}}`). Tolerates a flat
/// `reasoning_effort` too. Returns nil when absent or unparseable — purely
/// additive, so a shape change never disturbs the cost/token data.
private func reasoningEffort(fromOptionsJSON json: String?) -> String? {
    guard let json, let data = json.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    if let reasoning = obj["reasoning"] as? [String: Any], let e = reasoning["effort"] as? String { return e }
    if let e = obj["reasoning_effort"] as? String { return e }
    return nil
}

// ---------------------------------------------------------------------------
// JSONL source (GitHub Copilot Mac App)
//
// The file is large (100MB+) but only a few hundred lines carry usage. We
// memory-map it and, in a single pass, flag lines containing the substring
// "aiu" (present in every usage key), JSON-parsing only those.
// ---------------------------------------------------------------------------

/// Scan a byte buffer of whole-or-partial JSONL, parsing only `aiu` lines.
/// Returns the records plus how many bytes were CONSUMED — always ending on a
/// newline boundary, so a partially-written trailing line is left for next time
/// (parsing half a line would drop that record permanently). (#24)
private func scanJSONLBuffer(_ base: UnsafePointer<UInt8>, _ n: Int,
                             into out: inout [UsageRecord], seen: inout Set<String>) -> Int {
    let NL: UInt8 = 0x0A   // \n
    let A: UInt8 = 0x61, I: UInt8 = 0x69, U: UInt8 = 0x75   // "aiu"

    var lineStart = 0
    var consumed = 0
    var hasAiu = false
    var i = 0
    while i < n {
        let b = base[i]
        if b == NL {
            if hasAiu && i > lineStart {
                parseJSONLLine(base + lineStart, i - lineStart, into: &out, seen: &seen)
            }
            lineStart = i + 1
            consumed = lineStart      // only advance past complete lines
            hasAiu = false
        } else if b == U && i >= lineStart + 2 && base[i - 1] == I && base[i - 2] == A {
            hasAiu = true
        }
        i += 1
    }
    return consumed
}

/// Read new usage records from the append-only JSONL, starting at `from`.
///
/// The cache already holds every span ever seen, so re-reading history is pure
/// waste: at 1.8 GB a full scan cost ~4.5s of CPU on every 60s reload. Scanning
/// only the appended tail makes it ~O(bytes added). Returns the new offset to
/// store; a shrunken file means rotation/truncation → caller re-scans from 0.
private func loadJSONL(path: String, from offset: Int64) -> (records: [UsageRecord], newOffset: Int64, bytesScanned: Int64) {
    let url = URL(fileURLWithPath: path)
    let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64).flatMap { $0 } ?? 0
    var start = offset
    if start > size { start = 0 }             // rotated / truncated → full re-scan
    guard size > start else { return ([], size, 0) }

    var out: [UsageRecord] = []
    var seen = Set<String>()
    var consumed = 0

    if start == 0 {
        // Full scan: memory-map so a multi-GB file isn't read into the heap.
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return ([], offset, 0) }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            consumed = scanJSONLBuffer(base, raw.count, into: &out, seen: &seen)
        }
    } else {
        // Incremental: read just the tail — normally a few KB.
        guard let fh = try? FileHandle(forReadingFrom: url) else { return ([], offset, 0) }
        defer { try? fh.close() }
        guard (try? fh.seek(toOffset: UInt64(start))) != nil,
              let tail = try? fh.readToEnd(), !tail.isEmpty else { return ([], start, 0) }
        tail.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            consumed = scanJSONLBuffer(base, raw.count, into: &out, seen: &seen)
        }
    }
    return (out, start + Int64(consumed), size - start)
}

private func parseJSONLLine(
    _ ptr: UnsafePointer<UInt8>,
    _ len: Int,
    into out: inout [UsageRecord],
    seen: inout Set<String>
) {
    let lineData = Data(bytes: ptr, count: len)
    guard let obj = try? JSONSerialization.jsonObject(with: lineData) else { return }

    for span in extractSpans(obj) {
        guard let spanId = span["spanId"] as? String else { continue }
        let attrs = resolveAttrs(span["attributes"])

        // Mac App uses github.copilot.aiu (most models) or github.copilot.nano_aiu
        // (e.g. Opus); the VS Code extension uses copilot_chat.copilot_usage_nano_aiu.
        let nano = attrNumber(attrs, "github.copilot.aiu", "github.copilot.nano_aiu",
                              "copilot_chat.copilot_usage_nano_aiu")
        if nano == 0 { continue }

        // Skip orchestration/agent spans that aggregate child LLM costs — their
        // AIU duplicates the child span's value, so counting them double-counts.
        // Two shapes: (1) no model attribute at all, and (2) `invoke_agent` rollup
        // spans that DO carry a model but whose AIU is the sum of the child chat
        // calls. Both must be excluded.
        guard let model = attrString(attrs, "gen_ai.response.model", "gen_ai.request.model",
                                     "copilot_chat.model") else { continue }
        let op = (span["name"] as? String) ?? attrString(attrs, "gen_ai.operation.name") ?? ""
        if op.hasPrefix("invoke_agent") { continue }

        if seen.contains(spanId) { continue }   // mirrors INSERT OR IGNORE
        seen.insert(spanId)

        let conv = attrString(attrs, "gen_ai.conversation.id", "copilot_chat.conversation_id",
                              "copilot.conversation_id")
        let sess = attrString(attrs, "copilot_chat.session_id", "copilot_chat.chat_session_id")
        let inTok = Int(attrNumber(attrs, "gen_ai.usage.input_tokens", "llm.usage.prompt_tokens",
                                   "gen_ai.usage.prompt_tokens"))
        let outTok = Int(attrNumber(attrs, "gen_ai.usage.output_tokens", "llm.usage.completion_tokens",
                                    "gen_ai.usage.completion_tokens"))
        let level = attrString(attrs, "gen_ai.request.reasoning.level", "gen_ai.request.reasoning_effort")

        out.append(UsageRecord(
            source: .macApp,
            spanId: spanId,
            model: model,
            startMs: spanStartMs(span),
            credits: nano / 1_000_000_000.0,
            inputTokens: inTok,
            outputTokens: outTok,
            conversationId: conv,
            chatSessionId: sess,
            operationName: op,
            reasoningLevel: level
        ))
    }
}

// ---------------------------------------------------------------------------
// JSONL shape helpers — handle both the flat Mac App span format and the
// nested OTLP resourceSpans envelope.
// ---------------------------------------------------------------------------

private func extractSpans(_ obj: Any) -> [[String: Any]] {
    guard let dict = obj as? [String: Any] else { return [] }

    if let resourceSpans = dict["resourceSpans"] as? [Any] {
        var out: [[String: Any]] = []
        for rs in resourceSpans {
            guard let rsd = rs as? [String: Any],
                  let scopeSpans = rsd["scopeSpans"] as? [Any] else { continue }
            for ss in scopeSpans {
                guard let ssd = ss as? [String: Any],
                      let spans = ssd["spans"] as? [Any] else { continue }
                for sp in spans {
                    if let spd = sp as? [String: Any] { out.append(spd) }
                }
            }
        }
        return out
    }

    if dict["spanId"] is String { return [dict] }
    return []
}

/// Mac App: attributes is a plain `{key: value}` map. OTLP: an array of
/// `{key, value: {stringValue/intValue/doubleValue}}` — flattened to a map.
private func resolveAttrs(_ raw: Any?) -> [String: Any] {
    if let map = raw as? [String: Any] { return map }
    guard let arr = raw as? [Any] else { return [:] }
    var map: [String: Any] = [:]
    for a in arr {
        guard let ad = a as? [String: Any], let key = ad["key"] as? String else { continue }
        let v = ad["value"] as? [String: Any] ?? [:]
        if let s = v["stringValue"] as? String { map[key] = s }
        else if let iv = v["intValue"] { map[key] = iv }
        else if let dv = v["doubleValue"] { map[key] = dv }
    }
    return map
}

private func attrString(_ attrs: [String: Any], _ keys: String...) -> String? {
    for k in keys {
        if let v = attrs[k] {
            if let s = v as? String { return s }
            return "\(v)"
        }
    }
    return nil
}

private func attrNumber(_ attrs: [String: Any], _ keys: String...) -> Double {
    for k in keys {
        guard let v = attrs[k] else { continue }
        if let n = v as? NSNumber { return n.doubleValue }
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String, let d = Double(s) { return d }
    }
    return 0
}

private func spanStartMs(_ span: [String: Any]) -> Int64 {
    // Mac App: startTime = [seconds, nanoseconds]
    if let st = span["startTime"] as? [Any], st.count == 2 {
        let sec = (st[0] as? NSNumber)?.doubleValue ?? 0
        let nsec = (st[1] as? NSNumber)?.doubleValue ?? 0
        return Int64(sec * 1000 + (nsec / 1_000_000).rounded(.down))
    }
    // OTLP: startTimeUnixNano (string or number)
    if let v = span["startTimeUnixNano"] {
        let d = (v as? NSNumber)?.doubleValue ?? Double("\(v)") ?? 0
        return Int64((d / 1_000_000).rounded())
    }
    return 0
}
