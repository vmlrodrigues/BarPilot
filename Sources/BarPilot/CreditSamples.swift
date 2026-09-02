import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct CreditCycleSummary: Identifiable, Equatable {
    static let dayMs: Int64 = 24 * 60 * 60 * 1000

    let resetDayMs: Int64
    let latestSample: CreditSample

    init(latestSample: CreditSample) {
        self.resetDayMs = Self.dayStart(for: latestSample.resetAtMs)
        self.latestSample = latestSample
    }

    var id: Int64 { resetDayMs }
    var resetAtMs: Int64 { latestSample.resetAtMs }
    var resetAt: Date { latestSample.resetAt }
    var startAt: Date? { CreditReconciliation.cycleStart(for: latestSample) }

    static func dayStart(for resetAtMs: Int64) -> Int64 {
        resetAtMs / dayMs * dayMs
    }

    static func liveCycleDay(
        currentSample: CreditSample?,
        cycles: [CreditCycleSummary]
    ) -> Int64? {
        currentSample.map { dayStart(for: $0.resetAtMs) }
            ?? cycles.first?.resetDayMs
    }

    /// A UTC calendar day can straddle a non-midnight billing reset. Choose the
    /// cycle owning the largest part of that day; ties prefer the newer cycle
    /// because summaries are ordered newest first.
    static func cycle(
        containingUTCDate date: Date,
        in cycles: [CreditCycleSummary]
    ) -> CreditCycleSummary? {
        let dateMs = Int64(date.timeIntervalSince1970 * 1000)
        let dayStartMs = dayStart(for: dateMs)
        let dayEndMs = dayStartMs + dayMs
        var best: (cycle: CreditCycleSummary, overlap: Int64)?
        for cycle in cycles {
            guard let start = cycle.startAt else { continue }
            let startMs = Int64(start.timeIntervalSince1970 * 1000)
            let endMs = cycle.resetAtMs
            let overlap = max(
                0,
                min(dayEndMs, endMs) - max(dayStartMs, startMs)
            )
            if overlap > (best?.overlap ?? 0) {
                best = (cycle, overlap)
            }
        }
        return best?.cycle
    }

    static func overlapsUTCMonth(
        _ cycle: CreditCycleSummary,
        containing date: Date
    ) -> Bool {
        guard let start = cycle.startAt else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let monthStart = calendar.date(
            from: calendar.dateComponents([.year, .month], from: date)
        ), let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart)
        else { return false }
        return start < monthEnd && cycle.resetAt > monthStart
    }

    static func utcMonthKey(for date: Date) -> String {
        let ms = Int64(date.timeIntervalSince1970 * 1000)
        let day = utcDayString(for: ms)
        return String(day.prefix(7))
    }

    static func utcDayString(for date: Date) -> String {
        utcDayString(for: Int64(date.timeIntervalSince1970 * 1000))
    }

    private static func utcDayString(for ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0
        )
    }
}

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
        sqlite3_exec(db, """
        CREATE INDEX IF NOT EXISTS idx_credit_samples_account_cycle
            ON credit_samples(account, reset_at_ms, captured_at_ms);
        """, nil, nil, nil)
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

    /// Latest row visible to one account. With no fingerprint, only legacy
    /// unattributed rows are safe to hydrate; attributed rows may belong to a
    /// different account and are restored once identity is verified.
    static func latest(account: String?) -> CreditSample? {
        let clause = account.map {
            "WHERE account IS NULL OR account = '\(escape($0))'"
        } ?? "WHERE account IS NULL"
        return load(whereClause: clause, limit: 1).first
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
        } else {
            clause += " AND account IS NULL"
        }
        return Array(load(whereClause: clause, limit: nil).reversed())
    }

    /// Samples whose exact reset timestamps fall on one UTC reset day. GitHub
    /// can expose the same cycle through fields with different times-of-day, so
    /// history navigation coalesces those shapes without rewriting stored rows.
    static func loadCycle(resetDayMs: Int64, account: String?) -> [CreditSample] {
        let end = resetDayMs + CreditCycleSummary.dayMs
        var clause = "WHERE reset_at_ms >= \(resetDayMs) AND reset_at_ms < \(end)"
        if let account {
            clause += " AND (account IS NULL OR account = '\(escape(account))')"
        } else {
            clause += " AND account IS NULL"
        }
        return Array(load(whereClause: clause, limit: nil).reversed())
    }

    /// One latest observation per stored billing cycle, newest cycle first.
    /// Reset instants on the same UTC day are one cycle: the API has several
    /// reset fields and their time-of-day can differ within a real cycle.
    static func cycles(account: String?) -> [CreditCycleSummary] {
        guard let db = open() else { return [] }
        defer { sqlite3_close(db) }
        let accountClause = account.map {
            "(account IS NULL OR account = '\(escape($0))')"
        } ?? "account IS NULL"
        let daysSQL = """
        SELECT DISTINCT (reset_at_ms / \(CreditCycleSummary.dayMs))
        FROM credit_samples
        WHERE \(accountClause)
        ORDER BY 1 DESC
        """
        var daysStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, daysSQL, -1, &daysStmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(daysStmt) }
        var resetDays: [Int64] = []
        while sqlite3_step(daysStmt) == SQLITE_ROW {
            resetDays.append(
                sqlite3_column_int64(daysStmt, 0) * CreditCycleSummary.dayMs
            )
        }

        var out: [CreditCycleSummary] = []
        for resetDay in resetDays {
            let end = resetDay + CreditCycleSummary.dayMs
            let latestSQL = """
            SELECT captured_at_ms, server_at_ms, reset_at_ms, credits_used
            FROM credit_samples
            WHERE reset_at_ms >= \(resetDay) AND reset_at_ms < \(end)
              AND \(accountClause)
            ORDER BY captured_at_ms DESC
            LIMIT 1
            """
            var latestStmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db, latestSQL, -1, &latestStmt, nil
            ) == SQLITE_OK else {
                continue
            }
            if sqlite3_step(latestStmt) == SQLITE_ROW {
                out.append(CreditCycleSummary(latestSample: CreditSample(
                    capturedAtMs: sqlite3_column_int64(latestStmt, 0),
                    serverAtMs: sqlite3_column_type(latestStmt, 1) == SQLITE_NULL
                        ? nil : sqlite3_column_int64(latestStmt, 1),
                    resetAtMs: sqlite3_column_int64(latestStmt, 2),
                    creditsUsed: sqlite3_column_double(latestStmt, 3)
                )))
            }
            sqlite3_finalize(latestStmt)
        }
        return out
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
