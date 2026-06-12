import Foundation
import SQLite3

// ---------------------------------------------------------------------------
// SpanCache — a local SQLite mirror of every UsageRecord BarPilot has ever
// loaded. Survives VS Code / Mac App extension updates that wipe their source
// files. Spans are INSERT OR IGNORE'd by spanId so dedup is free.
//
// Path: ~/Library/Application Support/com.victorrodrigues.barpilot/spans-cache.db
// Pruned to the last 12 months on each app launch.
// ---------------------------------------------------------------------------

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SpanCache {
    static var path: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/Library/Application Support/com.victorrodrigues.barpilot/spans-cache.db"
    }

    private static func open() -> OpaquePointer? {
        let p = path
        try? FileManager.default.createDirectory(
            atPath: (p as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open_v2(p, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return nil
        }
        sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
        sqlite3_exec(db, """
        CREATE TABLE IF NOT EXISTS spans (
            span_id       TEXT PRIMARY KEY,
            source        TEXT NOT NULL,
            model         TEXT,
            start_ms      INTEGER NOT NULL,
            credits       REAL NOT NULL,
            input_tokens  INTEGER NOT NULL,
            output_tokens INTEGER NOT NULL,
            conv_id       TEXT,
            session_id    TEXT,
            op_name       TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_start_ms ON spans(start_ms);
        """, nil, nil, nil)
        return db
    }

    /// Persist new records (existing span_ids are left unchanged).
    static func merge(_ records: [UsageRecord]) {
        guard !records.isEmpty, let db = open() else { return }
        defer { sqlite3_close(db) }
        let sql = """
        INSERT OR IGNORE INTO spans
            (span_id, source, model, start_ms, credits, input_tokens,
             output_tokens, conv_id, session_id, op_name)
        VALUES (?,?,?,?,?,?,?,?,?,?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        for r in records {
            sqlite3_bind_text(stmt, 1, r.spanId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, r.source.rawValue, -1, SQLITE_TRANSIENT)
            if let m = r.model { sqlite3_bind_text(stmt, 3, m, -1, SQLITE_TRANSIENT) }
            else { sqlite3_bind_null(stmt, 3) }
            sqlite3_bind_int64(stmt, 4, r.startMs)
            sqlite3_bind_double(stmt, 5, r.credits)
            sqlite3_bind_int64(stmt, 6, Int64(r.inputTokens))
            sqlite3_bind_int64(stmt, 7, Int64(r.outputTokens))
            if let c = r.conversationId { sqlite3_bind_text(stmt, 8, c, -1, SQLITE_TRANSIENT) }
            else { sqlite3_bind_null(stmt, 8) }
            if let s = r.chatSessionId { sqlite3_bind_text(stmt, 9, s, -1, SQLITE_TRANSIENT) }
            else { sqlite3_bind_null(stmt, 9) }
            sqlite3_bind_text(stmt, 10, r.operationName, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
            sqlite3_reset(stmt)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    /// Load all cached records.
    static func load() -> [UsageRecord] {
        guard let db = open() else { return [] }
        defer { sqlite3_close(db) }
        let sql = """
        SELECT span_id, source, model, start_ms, credits,
               input_tokens, output_tokens, conv_id, session_id, op_name
        FROM spans
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
            out.append(UsageRecord(
                source: SourceKind(rawValue: text(1) ?? "") ?? .vscode,
                spanId: text(0) ?? "",
                model: text(2),
                startMs: sqlite3_column_int64(stmt, 3),
                credits: sqlite3_column_double(stmt, 4),
                inputTokens: Int(sqlite3_column_int64(stmt, 5)),
                outputTokens: Int(sqlite3_column_int64(stmt, 6)),
                conversationId: text(7),
                chatSessionId: text(8),
                operationName: text(9) ?? ""
            ))
        }
        return out
    }

    /// Delete spans older than `months` months and compact. Run once per launch.
    static func prune(keepingMonths months: Int = 12) {
        guard let db = open() else { return }
        defer { sqlite3_close(db) }
        let cutoff = Int64(Date().timeIntervalSince1970 * 1000)
                   - Int64(months) * 30 * 24 * 60 * 60 * 1000
        sqlite3_exec(db, "DELETE FROM spans WHERE start_ms < \(cutoff)", nil, nil, nil)
        sqlite3_exec(db, "VACUUM", nil, nil, nil)
    }
}
