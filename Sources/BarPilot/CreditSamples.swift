import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

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
        // Credit samples are written from a different task than the span
        // merge, so two writers now contend for this file. WAL allows
        // concurrent readers but still only one writer: without a timeout the
        // loser gets SQLITE_BUSY immediately instead of waiting its turn.
        sqlite3_busy_timeout(db, 5000)
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
        // Rows are attributed to the account that observed them. Without this,
        // the only thing keeping one account's counters out of another's history
        // was a mutable "baseline" timestamp, which had to be shoved forward on
        // every reconnect — hiding the whole cycle to protect against an account
        // switch that almost never happens. An unattributed row predates this
        // column; `adoptUnattributed` claims those exactly once.
        sqlite3_exec(db, "ALTER TABLE credit_samples ADD COLUMN account TEXT", nil, nil, nil)
        return db
    }

    /// Claim pre-migration rows for `account`, once. Guarded so a *second*
    /// account connecting later cannot inherit the first account's history.
    @discardableResult
    static func adoptUnattributed(account: String) -> Int {
        guard SpanCache.getMeta(adoptionKey) == nil else { return 0 }
        guard let db = open() else { return 0 }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "UPDATE credit_samples SET account = ? WHERE account IS NULL", -1, &stmt, nil
        ) == SQLITE_OK else { return 0 }
        sqlite3_bind_text(stmt, 1, account, -1, sqliteTransient)
        let ok = sqlite3_step(stmt) == SQLITE_DONE
        sqlite3_finalize(stmt)
        guard ok else { return 0 }
        SpanCache.setMeta(adoptionKey, account)
        return Int(sqlite3_changes(db))
    }

    private static let adoptionKey = "credit_samples_account_adopted"

    /// Run `body` against a throwaway database so verification never touches the
    /// user's real samples. Uses the existing `BARPILOT_CACHE_PATH` override.
    static func withTemporaryStore(_ body: () -> Void) {
        let previous = ProcessInfo.processInfo.environment["BARPILOT_CACHE_PATH"]
        let dir = NSTemporaryDirectory() + "barpilot-verify-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        setenv("BARPILOT_CACHE_PATH", dir + "/spans-cache.db", 1)
        precondition(SpanCache.path.hasPrefix(dir),
                     "verification must not run against the real database")
        body()
        if let previous { setenv("BARPILOT_CACHE_PATH", previous, 1) }
        else { unsetenv("BARPILOT_CACHE_PATH") }
        try? FileManager.default.removeItem(atPath: dir)
    }

    @discardableResult
    static func save(_ sample: CreditSample, account: String?) -> Bool {
        guard let db = open() else { return false }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = """
        INSERT OR REPLACE INTO credit_samples
            (captured_at_ms, server_at_ms, reset_at_ms, credits_used, account)
        VALUES (?,?,?,?,?)
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, sample.capturedAtMs)
        if let serverAtMs = sample.serverAtMs { sqlite3_bind_int64(stmt, 2, serverAtMs) }
        else { sqlite3_bind_null(stmt, 2) }
        sqlite3_bind_int64(stmt, 3, sample.resetAtMs)
        sqlite3_bind_double(stmt, 4, sample.creditsUsed)
        if let account { sqlite3_bind_text(stmt, 5, account, -1, sqliteTransient) }
        else { sqlite3_bind_null(stmt, 5) }
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    static func latest() -> CreditSample? {
        load(whereClause: "", limit: 1).first
    }

    static func latest(from capturedAtMs: Int64) -> CreditSample? {
        load(whereClause: "WHERE captured_at_ms >= \(capturedAtMs)", limit: 1).first
    }

    /// A cycle's samples for one account. Unattributed rows are included: they
    /// predate attribution, and `adoptUnattributed` claims them on the next
    /// connect or poll, after which none remain to be shared with a second
    /// account. Including them is what lets an existing install keep its history
    /// across the upgrade instead of appearing to start from empty.
    static func load(resetAtMs: Int64, account: String?) -> [CreditSample] {
        var clause = "WHERE reset_at_ms = \(resetAtMs)"
        if let account {
            clause += " AND (account IS NULL OR account = '\(escape(account))')"
        }
        return Array(load(whereClause: clause, limit: nil).reversed())
    }

    /// Fingerprints are hex, but never build SQL from unvalidated text.
    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
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
