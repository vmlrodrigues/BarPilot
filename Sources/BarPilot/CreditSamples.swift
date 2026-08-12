import Foundation
import SQLite3

// ---------------------------------------------------------------------------
// CreditSampleStore — cumulative server-counter observations.
//
// Samples live beside the legacy span cache but in their own durable table. The
// database remains after telemetry retirement. Poll failures are never written,
// and reconciliation never diffs across a reset or decrease.
// ---------------------------------------------------------------------------

enum CreditSampleStore {
    private static func open() -> OpaquePointer? {
        let path = SpanCache.path
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return nil
        }
        sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
        sqlite3_exec(db, """
        CREATE TABLE IF NOT EXISTS credit_samples (
            captured_at_ms INTEGER PRIMARY KEY,
            server_at_ms   INTEGER,
            reset_at_ms    INTEGER NOT NULL,
            credits_used   REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_credit_samples_reset
            ON credit_samples(reset_at_ms, captured_at_ms);
        """, nil, nil, nil)
        return db
    }

    @discardableResult
    static func save(_ sample: CreditSample) -> Bool {
        guard let db = open() else { return false }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = """
        INSERT OR REPLACE INTO credit_samples
            (captured_at_ms, server_at_ms, reset_at_ms, credits_used)
        VALUES (?,?,?,?)
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, sample.capturedAtMs)
        if let serverAtMs = sample.serverAtMs { sqlite3_bind_int64(stmt, 2, serverAtMs) }
        else { sqlite3_bind_null(stmt, 2) }
        sqlite3_bind_int64(stmt, 3, sample.resetAtMs)
        sqlite3_bind_double(stmt, 4, sample.creditsUsed)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    static func latest() -> CreditSample? {
        load(whereClause: "", limit: 1).first
    }

    static func latest(from capturedAtMs: Int64) -> CreditSample? {
        load(whereClause: "WHERE captured_at_ms >= \(capturedAtMs)", limit: 1).first
    }

    static func load(resetAtMs: Int64, from capturedAtMs: Int64) -> [CreditSample] {
        Array(load(
            whereClause: "WHERE reset_at_ms = \(resetAtMs) AND captured_at_ms >= \(capturedAtMs)",
            limit: nil
        ).reversed())
    }

    static func count() -> Int {
        guard let db = open() else { return 0 }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM credit_samples", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    static func prune(keepingMonths months: Int = 13) {
        guard let db = open() else { return }
        defer { sqlite3_close(db) }
        let cutoff = Int64(Date().timeIntervalSince1970 * 1000)
                   - Int64(months) * 31 * 24 * 60 * 60 * 1000
        sqlite3_exec(db, "DELETE FROM credit_samples WHERE captured_at_ms < \(cutoff)", nil, nil, nil)
    }

    private static func load(whereClause: String, limit: Int?) -> [CreditSample] {
        guard let db = open() else { return [] }
        defer { sqlite3_close(db) }
        let limitSQL = limit.map { " LIMIT \($0)" } ?? ""
        let sql = """
        SELECT captured_at_ms, server_at_ms, reset_at_ms, credits_used
        FROM credit_samples
        \(whereClause)
        ORDER BY captured_at_ms DESC\(limitSQL)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [CreditSample] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(CreditSample(
                capturedAtMs: sqlite3_column_int64(stmt, 0),
                serverAtMs: sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 1),
                resetAtMs: sqlite3_column_int64(stmt, 2),
                creditsUsed: sqlite3_column_double(stmt, 3)
            ))
        }
        return out
    }
}
