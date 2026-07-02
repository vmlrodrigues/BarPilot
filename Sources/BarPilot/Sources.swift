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
        if FileManager.default.fileExists(atPath: jsonlPath) {
            let recs = loadJSONL(path: jsonlPath)
            status.macAppFound = true
            status.macAppCount = recs.count
            liveRecords.append(contentsOf: recs)
        }

        status.vscodeConfigured = isVSCodeTelemetryConfigured()
        status.macAppConfigured = isMacAppTelemetryConfigured()

        SpanCache.merge(liveRecords)
        ReasoningLevelBackfill.run(liveRecords: liveRecords)  // one-time, gated: fill levels on already-cached spans
        ChatBackfill.run()   // one-time, gated: recover pre-OTel June history from chat files
        return (SpanCache.load(), status)
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

private func loadJSONL(path: String) -> [UsageRecord] {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else {
        return []
    }

    var out: [UsageRecord] = []
    var seen = Set<String>()

    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
        let n = raw.count

        let NL: UInt8 = 0x0A   // \n
        let A: UInt8 = 0x61, I: UInt8 = 0x69, U: UInt8 = 0x75   // "aiu"

        var lineStart = 0
        var hasAiu = false
        var i = 0
        while i < n {
            let b = base[i]
            if b == NL {
                if hasAiu && i > lineStart {
                    parseJSONLLine(base + lineStart, i - lineStart, into: &out, seen: &seen)
                }
                lineStart = i + 1
                hasAiu = false
            } else if b == U && i >= lineStart + 2 && base[i - 1] == I && base[i - 2] == A {
                hasAiu = true
            }
            i += 1
        }
        if hasAiu && lineStart < n {
            parseJSONLLine(base + lineStart, n - lineStart, into: &out, seen: &seen)
        }
    }
    return out
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
