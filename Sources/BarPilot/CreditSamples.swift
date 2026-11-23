import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct CreditCycleSummary: Identifiable, Equatable {
    static let dayMs: Int64 = 24 * 60 * 60 * 1000
    private static let adjacentResetTolerance: TimeInterval = 4 * 86_400

    let resetDayMs: Int64
    let latestSample: CreditSample
    let firstObservedAtMs: Int64

    init(latestSample: CreditSample, firstObservedAtMs: Int64? = nil) {
        self.resetDayMs = Self.dayStart(for: latestSample.resetAtMs)
        self.latestSample = latestSample
        self.firstObservedAtMs = firstObservedAtMs ?? latestSample.observedAtMs
    }

    var id: Int64 { resetDayMs }
    var resetAtMs: Int64 { latestSample.resetAtMs }
    var resetAt: Date { latestSample.resetAt }
    var startAt: Date? { CreditCycle.cycleStart(for: latestSample) }

    func startAt(in cycles: [CreditCycleSummary]) -> Date? {
        let preceding = cycles.first { $0.resetDayMs < resetDayMs }
        return preceding.flatMap { startAt(after: $0) } ?? startAt
    }

    func endAt(in cycles: [CreditCycleSummary]) -> Date {
        let following = cycles.last { $0.resetDayMs > resetDayMs }
        return following.flatMap { $0.startAt(after: self) } ?? resetAt
    }

    private func startAt(after preceding: CreditCycleSummary) -> Date? {
        // Monthly date arithmetic can clamp to a shorter month's last day.
        // Use the preceding cycle's reported reset when it fits the cadence.
        // Three days cover the difference in month lengths. The extra day
        // allows the API's reset fields to differ in time-of-day.
        guard let estimate = startAt,
              abs(preceding.resetAt.timeIntervalSince(estimate)) < Self.adjacentResetTolerance
        else { return nil }

        // An accepted new-cycle observation can establish an earlier boundary.
        // Use the same instant as the preceding cycle's exclusive end.
        let observed = Date(timeIntervalSince1970: Double(firstObservedAtMs) / 1_000)
        if observed < preceding.resetAt,
           preceding.resetAt.timeIntervalSince(observed) < Self.adjacentResetTolerance {
            return observed
        }
        return preceding.resetAt <= latestSample.capturedAt ? preceding.resetAt : nil
    }

    static func dayStart(for resetAtMs: Int64) -> Int64 {
        resetAtMs / dayMs * dayMs
    }

    /// A UTC calendar day can straddle a non-midnight billing reset. Choose the
    /// cycle owning the largest part of that day; ties prefer the newer cycle
    /// because summaries are ordered newest first.
    static func cycle(
        containingUTCDate date: Date,
        in cycles: [CreditCycleSummary]
    ) -> CreditCycleSummary? {
        var best: (cycle: CreditCycleSummary, overlap: Int64)?
        for cycle in cycles {
            let overlap = cycle.overlapOnUTCDay(date, in: cycles)
            if overlap > (best?.overlap ?? 0) {
                best = (cycle, overlap)
            }
        }
        return best?.cycle
    }

    func overlapOnUTCDay(_ date: Date, in cycles: [CreditCycleSummary]) -> Int64 {
        guard let start = startAt(in: cycles) else { return 0 }
        let dateMs = Int64(date.timeIntervalSince1970 * 1000)
        let dayStartMs = Self.dayStart(for: dateMs)
        let dayEndMs = dayStartMs + Self.dayMs
        let startMs = Int64((start.timeIntervalSince1970 * 1000).rounded())
        let endMs = Int64((endAt(in: cycles).timeIntervalSince1970 * 1000).rounded())
        return max(0, min(dayEndMs, endMs) - max(dayStartMs, startMs))
    }

    static func overlapsUTCMonth(
        _ cycle: CreditCycleSummary,
        containing date: Date,
        in cycles: [CreditCycleSummary]
    ) -> Bool {
        guard let start = cycle.startAt(in: cycles) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let monthStart = calendar.date(
            from: calendar.dateComponents([.year, .month], from: date)
        ), let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart)
        else { return false }
        return start < monthEnd && cycle.endAt(in: cycles) > monthStart
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

struct CreditCycleNavigation {
    let older: CreditCycleSummary?
    let newer: CreditCycleSummary?
    let canReturnToCurrent: Bool

    init(cycles: [CreditCycleSummary], selectedDay: Int64?, liveDay: Int64? = nil, now: Date = Date()) {
        let completed = cycles.filter { Self.isCompleted($0, in: cycles, liveDay: liveDay, now: now) }
        if let selectedDay {
            older = completed.first { $0.resetDayMs < selectedDay }
            newer = completed.last { $0.resetDayMs > selectedDay }
            canReturnToCurrent = newer == nil
        } else {
            older = completed.first
            newer = nil
            canReturnToCurrent = false
        }
    }

    static func isCompleted(
        _ cycle: CreditCycleSummary, in cycles: [CreditCycleSummary], liveDay: Int64?, now: Date
    ) -> Bool {
        if let liveDay { return cycle.resetDayMs < liveDay }
        return cycle.endAt(in: cycles) <= now
    }

    static func verify() {
        let hour: Int64 = 60 * 60 * 1000
        func date(_ day: String) -> Date {
            Date(timeIntervalSince1970: Double(CreditCycle.utcMidnightMs(day)) / 1000)
        }
        func cycle(_ end: String) -> CreditCycleSummary {
            let reset = CreditCycle.utcMidnightMs(end) + 18 * hour
            return CreditCycleSummary(latestSample: CreditSample(
                capturedAtMs: reset - hour, serverAtMs: nil,
                resetAtMs: reset, creditsUsed: 50
            ))
        }

        let november = cycle("2029-11-30")
        let january = cycle("2030-01-31")
        let february = cycle("2030-02-28")
        let march = cycle("2030-03-31")
        let now = date("2030-03-03")
        let historical = [february, january]
        let withCurrent = [march] + historical

        precondition(february.startAt(in: historical) == january.resetAt)
        precondition(february.startAt(in: [february, november]) == february.startAt)
        precondition(CreditCycleSummary.cycle(containingUTCDate: date("2030-01-29"),
                                              in: historical) == january,
                     "the February cycle must not claim days before the known January reset")
        let split = date("2030-01-31")
        precondition(january.overlapOnUTCDay(split, in: historical) == 18 * hour)
        precondition(february.overlapOnUTCDay(split, in: historical) == 6 * hour)
        precondition(CreditCycleSummary.cycle(containingUTCDate: split, in: historical) == january)

        let offline = CreditCycleNavigation(cycles: historical, selectedDay: nil, now: now)
        let online = CreditCycleNavigation(cycles: withCurrent, selectedDay: nil, now: now)
        precondition(offline.older == february && online.older == february,
                     "the older arrow must enter the latest completed cycle even without a live reading")
        let latest = CreditCycleNavigation(cycles: historical, selectedDay: february.resetDayMs, now: now)
        precondition(latest.older == january && latest.newer == nil && latest.canReturnToCurrent,
                     "the newer arrow from the latest completed cycle must return to the current view")
        let older = CreditCycleNavigation(cycles: historical, selectedDay: january.resetDayMs, now: now)
        precondition(older.older == nil && older.newer == february && !older.canReturnToCurrent)

        let planned = CreditCycle.utcMidnightMs("2030-02-01")
        let observed = planned - 15 * 60_000
        let nextReset = CreditCycle.utcMidnightMs("2030-03-01")
        let previousSample = CreditSample(
            capturedAtMs: observed - 60_000, serverAtMs: nil, resetAtMs: planned, creditsUsed: 60
        )
        let early = CreditSample(
            capturedAtMs: observed, serverAtMs: nil, resetAtMs: nextReset, creditsUsed: 0
        )
        let later = CreditSample(
            capturedAtMs: observed + 10 * 60_000, serverAtMs: nil, resetAtMs: nextReset, creditsUsed: 25
        )
        CreditSampleStore.withTemporaryStore {
            for sample in [previousSample, early, later] {
                precondition(CreditSampleStore.save(sample, account: "fixture"))
            }
            let cycles = CreditSampleStore.cycles(account: "fixture")
            precondition(cycles.count == 2)
            precondition(cycles == CreditSampleStore.compactedHistory(account: "fixture")?.cycles)
            let live = cycles[0]
            let prior = cycles[1]
            precondition(live.firstObservedAtMs == observed)
            precondition(live.startAt(in: cycles) == early.capturedAt)
            precondition(prior.endAt(in: cycles) == early.capturedAt)
            let nav = CreditCycleNavigation(cycles: cycles, selectedDay: nil,
                                            liveDay: live.id, now: later.capturedAt)
            precondition(nav.older == prior, "a confirmed early reset must make the previous cycle navigable")
            let beforeMidnight = date("2030-01-31")
            precondition(CreditCycleSummary.cycle(containingUTCDate: beforeMidnight, in: cycles) == prior)
            precondition(live.overlapOnUTCDay(beforeMidnight, in: cycles) == 15 * 60_000)
            precondition(CreditCycleSummary.overlapsUTCMonth(live, containing: beforeMidnight, in: cycles),
                         "the calendar must include a new cycle that recorded spend in the previous month")
            let daily = CreditTimeline.combinedDaily(samplesByCycle: [[previousSample], [early, later]],
                                                      monthKey: "2030-01")
            precondition(daily["2030-01-31"] == 25)
            let merged = SyncAggregate.mergedCreditCycles(
                local: [CreditCycleSummary(latestSample: later), prior], additionalSamples: [early]
            )
            precondition(merged == cycles, "an earlier peer observation must keep the early reset after a merge")
        }
    }
}

// ---------------------------------------------------------------------------
// CreditSampleStore — cumulative server-counter observations.
//
// Keep the historical filename so upgrades preserve samples and cycle budgets.
// Poll failures are never written, and timelines never diff across a reset.
// ---------------------------------------------------------------------------

enum CreditSampleStore {
    static var path: String {
        if let override = ProcessInfo.processInfo.environment["BARPILOT_CACHE_PATH"],
           !override.isEmpty { return override }
        return FileManager.default.homeDirectoryForCurrentUser.path
            + "/Library/Application Support/com.victorrodrigues.barpilot/spans-cache.db"
    }

    static func getMeta(_ key: String) -> String? {
        guard let db = open() else { return nil }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "SELECT value FROM meta WHERE key=?", -1, &statement, nil
        ) == SQLITE_OK else {
            NSLog("BarPilot: unable to read credit metadata")
            return nil
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, sqliteTransient)
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) {
            return String(cString: value)
        }
        if result != SQLITE_DONE {
            NSLog("BarPilot: credit metadata read failed")
        }
        return nil
    }

    static func setMeta(_ key: String, _ value: String) {
        guard let db = open() else { return }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)",
            -1, &statement, nil
        ) == SQLITE_OK else {
            NSLog("BarPilot: unable to prepare credit metadata write")
            return
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, value, -1, sqliteTransient)
        if sqlite3_step(statement) != SQLITE_DONE {
            NSLog("BarPilot: credit metadata write failed")
        }
    }

    /// Retire only telemetry-owned storage. Account adoption, budget migration
    /// and database identity metadata must survive this upgrade.
    static func retireLegacyTelemetry() -> Bool {
        guard let db = open() else { return false }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            NSLog("BarPilot: unable to start telemetry retirement")
            return false
        }
        let retired = sqlite3_exec(db, """
        DROP TABLE IF EXISTS spans;
        DELETE FROM meta WHERE key IN (
            'macAppJSONLOffset', 'macAppJSONLLastSize', 'macAppJSONLLastGrowthAt',
            'lastSourceCheckAt', 'backfill_version', 'reasoning_backfill_version'
        );
        """, nil, nil, nil) == SQLITE_OK
        if retired && sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK {
            return true
        }
        sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
        NSLog("BarPilot: telemetry retirement failed; credit history retained")
        return false
    }

    static func verifyTelemetryRetirement() {
        withTemporaryStore {
            let identity = storeIdentity()
            let sample = CreditSample(
                capturedAtMs: CreditCycle.utcMidnightMs("2030-01-10"),
                serverAtMs: nil, resetAtMs: CreditCycle.utcMidnightMs("2030-02-01"),
                creditsUsed: 123
            )
            precondition(save(sample, account: "fixture", budgetUSD: 150))
            setMeta(adoptionKey, "fixture")
            guard let db = open() else { preconditionFailure("fixture database unavailable") }
            precondition(sqlite3_exec(db, """
            CREATE TABLE spans(span_id TEXT PRIMARY KEY, credits REAL);
            INSERT INTO spans VALUES('retired',999);
            INSERT INTO meta VALUES('macAppJSONLOffset','1234');
            INSERT INTO meta VALUES('backfill_version','2');
            CREATE TRIGGER prevent_retirement BEFORE DELETE ON meta
            WHEN OLD.key='macAppJSONLOffset'
            BEGIN SELECT RAISE(ABORT,'fixture retirement failure'); END;
            """, nil, nil, nil) == SQLITE_OK)
            sqlite3_close(db)
            precondition(!retireLegacyTelemetry(), "failed retirement must report failure")
            precondition(getMeta("macAppJSONLOffset") == "1234")
            guard let rollback = open() else { preconditionFailure("rollback database unavailable") }
            var restored: OpaquePointer?
            precondition(sqlite3_prepare_v2(
                rollback, "SELECT COUNT(*) FROM spans", -1, &restored, nil
            ) == SQLITE_OK, "a failed cleanup must restore the dropped table")
            precondition(sqlite3_step(restored) == SQLITE_ROW && sqlite3_column_int(restored, 0) == 1)
            sqlite3_finalize(restored)
            precondition(sqlite3_exec(
                rollback, "DROP TRIGGER prevent_retirement", nil, nil, nil
            ) == SQLITE_OK)
            sqlite3_close(rollback)
            precondition(retireLegacyTelemetry())
            precondition(retireLegacyTelemetry(), "retirement must be idempotent")
            precondition(storeIdentity() == identity)
            precondition(load(resetAtMs: sample.resetAtMs, account: "fixture") == [sample])
            precondition(cycleBudget(
                resetDayMs: CreditCycleSummary.dayStart(for: sample.resetAtMs),
                account: "fixture"
            ) == 150, "telemetry retirement must preserve cycle budgets")
            precondition(getMeta(adoptionKey) == "fixture")
            precondition(getMeta("macAppJSONLOffset") == nil && getMeta("backfill_version") == nil)
            guard let checked = open() else { preconditionFailure("retired database unavailable") }
            defer { sqlite3_close(checked) }
            var statement: OpaquePointer?
            precondition(sqlite3_prepare_v2(
                checked, "SELECT 1 FROM sqlite_master WHERE name='spans'",
                -1, &statement, nil
            ) == SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            precondition(sqlite3_step(statement) == SQLITE_DONE, "telemetry table must be removed")
        }
    }

    struct HistorySnapshot {
        let cycles: [CreditCycleSummary]
        let samplesByCycle: [Int64: [CreditSample]]
        let cycleBudgets: [SyncedCycleBudget]

        var samples: [CreditSample] {
            samplesByCycle.values.flatMap { $0 }
                .sorted { $0.capturedAtMs < $1.capturedAtMs }
        }
    }

    /// Stable identity stored inside the database itself. UsageStore mirrors it
    /// in preferences; a mismatch proves that SQLite created a replacement file
    /// and enables one-time recovery from this machine's remote payload.
    static func storeIdentity() -> String? {
        let key = "credit_history_store_id"
        if let existing = CreditSampleStore.getMeta(key), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString
        CreditSampleStore.setMeta(key, created)
        return CreditSampleStore.getMeta(key) == created ? created : nil
    }

    private static func open() -> OpaquePointer? {
        let path = CreditSampleStore.path
        do {
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
        } catch {
            NSLog("BarPilot: unable to create credit history directory")
            return nil
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            NSLog("BarPilot: unable to open credit history database")
            if let db { sqlite3_close(db) }
            return nil
        }
        sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
        // Budget edits, polling and sync recovery may write concurrently.
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
        // A completed cycle must keep the target it was measured against.
        // Existing rows intentionally remain NULL: the original target cannot
        // be reconstructed safely from today's preference.
        sqlite3_exec(db, "ALTER TABLE credit_samples ADD COLUMN budget_usd REAL", nil, nil, nil)
        // This timestamp advances only when the target changes. For existing
        // snapshots, the observation timestamp is the safest one-time estimate.
        sqlite3_exec(
            db,
            "ALTER TABLE credit_samples ADD COLUMN budget_updated_at_ms INTEGER",
            nil, nil, nil
        )
        sqlite3_exec(db, """
        UPDATE credit_samples
        SET budget_updated_at_ms = captured_at_ms
        WHERE budget_usd IS NOT NULL AND budget_updated_at_ms IS NULL;
        """, nil, nil, nil)
        sqlite3_exec(db, """
        CREATE INDEX IF NOT EXISTS idx_credit_samples_account_cycle
            ON credit_samples(account, reset_at_ms, captured_at_ms);
        CREATE TABLE IF NOT EXISTS credit_cycle_budgets (
            account_key   TEXT NOT NULL,
            reset_day_ms  INTEGER NOT NULL,
            budget_usd    REAL NOT NULL,
            updated_at_ms INTEGER NOT NULL,
            PRIMARY KEY (account_key, reset_day_ms)
        );
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
        """, nil, nil, nil)
        // Move the former observation-attached snapshots into first-class cycle
        // metadata once. INSERT OR IGNORE plus newest-first ordering retains the
        // latest legacy snapshot for each account/cycle without overwriting a
        // budget already written by the new model.
        var migrationStmt: OpaquePointer?
        let migrationKey = "credit_cycle_budget_table_v1"
        if sqlite3_prepare_v2(
            db, "SELECT 1 FROM meta WHERE key=?", -1, &migrationStmt, nil
        ) == SQLITE_OK {
            sqlite3_bind_text(
                migrationStmt, 1, migrationKey, -1, sqliteTransient
            )
            let migrationNeeded = sqlite3_step(migrationStmt) != SQLITE_ROW
            sqlite3_finalize(migrationStmt)
            migrationStmt = nil
            if migrationNeeded,
               sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK {
                let migrated = sqlite3_exec(db, """
                INSERT OR IGNORE INTO credit_cycle_budgets
                    (account_key, reset_day_ms, budget_usd, updated_at_ms)
                SELECT COALESCE(account, ''),
                       (reset_at_ms / \(CreditCycleSummary.dayMs))
                           * \(CreditCycleSummary.dayMs),
                       budget_usd, budget_updated_at_ms
                FROM credit_samples
                WHERE budget_usd IS NOT NULL
                  AND budget_updated_at_ms IS NOT NULL
                  AND budget_usd >= 0
                  AND budget_usd <= \(BudgetInput.maximum)
                  AND (budget_usd = 0
                       OR budget_usd >= \(BudgetInput.minimumNonZero))
                ORDER BY budget_updated_at_ms DESC, captured_at_ms DESC;
                """, nil, nil, nil) == SQLITE_OK
                var marker: OpaquePointer?
                let markerPrepared = sqlite3_prepare_v2(
                    db,
                    "INSERT OR REPLACE INTO meta(key,value) VALUES(?,'complete')",
                    -1, &marker, nil
                ) == SQLITE_OK
                if markerPrepared {
                    sqlite3_bind_text(
                        marker, 1, migrationKey, -1, sqliteTransient
                    )
                }
                let markerWritten = markerPrepared
                    && sqlite3_step(marker) == SQLITE_DONE
                sqlite3_finalize(marker)
                if migrated && markerWritten {
                    sqlite3_exec(db, "COMMIT", nil, nil, nil)
                } else {
                    sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                }
            }
        } else {
            sqlite3_finalize(migrationStmt)
        }
        return db
    }

    /// Claim pre-migration rows for `account`, once. Guarded so a *second*
    /// account connecting later cannot inherit the first account's history.
    @discardableResult
    static func adoptUnattributed(account: String) -> Int {
        guard CreditSampleStore.getMeta(adoptionKey) == nil else { return 0 }
        guard let db = open() else { return 0 }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK
        else { return 0 }
        var committed = false
        defer {
            if !committed { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "UPDATE credit_samples SET account = ? WHERE account IS NULL", -1, &stmt, nil
        ) == SQLITE_OK else { return 0 }
        sqlite3_bind_text(stmt, 1, account, -1, sqliteTransient)
        let ok = sqlite3_step(stmt) == SQLITE_DONE
        let adoptedCount = Int(sqlite3_changes(db))
        sqlite3_finalize(stmt)
        guard ok else { return 0 }

        var legacyBudgets: [SyncedCycleBudget] = []
        guard sqlite3_prepare_v2(
            db,
            "SELECT reset_day_ms,budget_usd,updated_at_ms FROM credit_cycle_budgets WHERE account_key=''",
            -1, &stmt, nil
        ) == SQLITE_OK else { return 0 }
        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            legacyBudgets.append(SyncedCycleBudget(
                resetDayMs: sqlite3_column_int64(stmt, 0),
                budgetUSD: sqlite3_column_double(stmt, 1),
                updatedAtMs: sqlite3_column_int64(stmt, 2)
            ))
            step = sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        let validLegacyBudgets = legacyBudgets.filter {
            isValidBudget($0.budgetUSD) && $0.updatedAtMs > 0
        }
        guard step == SQLITE_DONE,
              validLegacyBudgets.allSatisfy({
                  upsertCycleBudget(
                      db, resetDayMs: $0.resetDayMs, account: account,
                      budgetUSD: $0.budgetUSD, updatedAtMs: $0.updatedAtMs
                  )
              }),
              sqlite3_exec(
                  db, "DELETE FROM credit_cycle_budgets WHERE account_key=''",
                  nil, nil, nil
              ) == SQLITE_OK,
              sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            return 0
        }
        committed = true
        CreditSampleStore.setMeta(adoptionKey, account)
        return adoptedCount
    }

    private static let adoptionKey = "credit_samples_account_adopted"

    private static func accountKey(_ account: String?) -> String {
        account ?? ""
    }

    /// Insert or advance one first-class cycle target. A cycle budget is valid
    /// even when this Mac has not captured a counter observation for that cycle.
    private static func upsertCycleBudget(
        _ db: OpaquePointer?, resetDayMs: Int64, account: String?,
        budgetUSD: Double, updatedAtMs: Int64
    ) -> Bool {
        guard isValidBudget(budgetUSD), updatedAtMs > 0 else { return false }
        var stmt: OpaquePointer?
        let sql = """
        INSERT INTO credit_cycle_budgets
            (account_key, reset_day_ms, budget_usd, updated_at_ms)
        VALUES (?,?,?,?)
        ON CONFLICT(account_key, reset_day_ms) DO UPDATE SET
            budget_usd = excluded.budget_usd,
            updated_at_ms = excluded.updated_at_ms
        WHERE excluded.updated_at_ms >= credit_cycle_budgets.updated_at_ms
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(
            stmt, 1, accountKey(account), -1, sqliteTransient
        )
        sqlite3_bind_int64(stmt, 2, resetDayMs)
        sqlite3_bind_double(stmt, 3, budgetUSD)
        sqlite3_bind_int64(stmt, 4, updatedAtMs)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    /// Run `body` against a throwaway database so verification never touches the
    /// user's real samples. Uses the existing `BARPILOT_CACHE_PATH` override.
    static func withTemporaryStore(_ body: () -> Void) {
        let previous = ProcessInfo.processInfo.environment["BARPILOT_CACHE_PATH"]
        let dir = NSTemporaryDirectory() + "barpilot-verify-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        setenv("BARPILOT_CACHE_PATH", dir + "/spans-cache.db", 1)
        precondition(CreditSampleStore.path.hasPrefix(dir),
                     "verification must not run against the real database")
        body()
        if let previous { setenv("BARPILOT_CACHE_PATH", previous, 1) }
        else { unsetenv("BARPILOT_CACHE_PATH") }
        try? FileManager.default.removeItem(atPath: dir)
    }

    @discardableResult
    static func save(
        _ sample: CreditSample,
        account: String?,
        budgetUSD: Double? = nil,
        budgetUpdatedAtMs: Int64? = nil
    ) -> Bool {
        if let budgetUSD, !isValidBudget(budgetUSD) { return false }
        let budgetTimestamp = budgetUSD.map { _ in
            budgetUpdatedAtMs ?? sample.capturedAtMs
        }
        if let budgetTimestamp, budgetTimestamp <= 0 { return false }
        guard let db = open() else { return false }
        defer { sqlite3_close(db) }
        let transactionStarted = budgetUSD != nil
            && sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK
        guard budgetUSD == nil || transactionStarted else { return false }
        var committed = !transactionStarted
        defer {
            if transactionStarted && !committed {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            }
        }
        var stmt: OpaquePointer?
        let sql = """
        INSERT INTO credit_samples
            (captured_at_ms, server_at_ms, reset_at_ms, credits_used, account,
             budget_usd, budget_updated_at_ms)
        VALUES (?,?,?,?,?,?,?)
        ON CONFLICT(captured_at_ms) DO UPDATE SET
            server_at_ms = excluded.server_at_ms,
            reset_at_ms = excluded.reset_at_ms,
            credits_used = excluded.credits_used,
            account = excluded.account,
            budget_usd = COALESCE(excluded.budget_usd, credit_samples.budget_usd),
            budget_updated_at_ms = COALESCE(
                excluded.budget_updated_at_ms,
                credit_samples.budget_updated_at_ms
            )
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
        if let budgetUSD { sqlite3_bind_double(stmt, 6, budgetUSD) }
        else { sqlite3_bind_null(stmt, 6) }
        if let budgetTimestamp { sqlite3_bind_int64(stmt, 7, budgetTimestamp) }
        else { sqlite3_bind_null(stmt, 7) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
        if let budgetUSD, let budgetTimestamp {
            let resetDayMs = CreditCycleSummary.dayStart(for: sample.resetAtMs)
            guard upsertCycleBudget(
                db, resetDayMs: resetDayMs, account: account,
                budgetUSD: budgetUSD, updatedAtMs: budgetTimestamp
            ) else { return false }
        }
        if transactionStarted {
            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                return false
            }
            committed = true
        }
        return true
    }

    /// Restore a compact set of observations recovered from this machine's
    /// remote payload. One transaction avoids thousands of database opens; a
    /// recovered budget replaces local metadata only when it is at least as new.
    @discardableResult
    static func saveAll(
        _ samples: [CreditSample],
        cycleBudgets: [SyncedCycleBudget] = [],
        account: String
    ) -> Bool {
        guard !samples.isEmpty || !cycleBudgets.isEmpty else { return true }
        guard let db = open() else { return false }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK
        else { return false }
        var committed = false
        defer {
            if !committed { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
        }
        let sql = """
        INSERT INTO credit_samples
            (captured_at_ms, server_at_ms, reset_at_ms, credits_used, account, budget_usd)
        VALUES (?,?,?,?,?,NULL)
        ON CONFLICT(captured_at_ms) DO UPDATE SET
            server_at_ms = excluded.server_at_ms,
            reset_at_ms = excluded.reset_at_ms,
            credits_used = excluded.credits_used,
            account = excluded.account
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        for sample in samples {
            guard sqlite3_reset(stmt) == SQLITE_OK,
                  sqlite3_clear_bindings(stmt) == SQLITE_OK,
                  sqlite3_bind_int64(stmt, 1, sample.capturedAtMs) == SQLITE_OK
            else { return false }
            if let serverAtMs = sample.serverAtMs {
                guard sqlite3_bind_int64(stmt, 2, serverAtMs) == SQLITE_OK else {
                    return false
                }
            } else {
                guard sqlite3_bind_null(stmt, 2) == SQLITE_OK else { return false }
            }
            guard sqlite3_bind_int64(stmt, 3, sample.resetAtMs) == SQLITE_OK,
                  sqlite3_bind_double(stmt, 4, sample.creditsUsed) == SQLITE_OK,
                  sqlite3_bind_text(
                      stmt, 5, account, -1, sqliteTransient
                  ) == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_DONE else {
                return false
            }
        }
        let budgetSQL = """
        UPDATE credit_samples
        SET budget_usd = ?, budget_updated_at_ms = ?
        WHERE reset_at_ms >= ? AND reset_at_ms < ? AND account = ?
          AND (budget_updated_at_ms IS NULL OR budget_updated_at_ms <= ?)
        """
        var budgetStmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, budgetSQL, -1, &budgetStmt, nil
        ) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(budgetStmt) }
        for budget in SyncAggregate.compactCycleBudgets(cycleBudgets) {
            guard upsertCycleBudget(
                      db, resetDayMs: budget.resetDayMs, account: account,
                      budgetUSD: budget.budgetUSD,
                      updatedAtMs: budget.updatedAtMs
                  ),
                  sqlite3_reset(budgetStmt) == SQLITE_OK,
                  sqlite3_clear_bindings(budgetStmt) == SQLITE_OK,
                  sqlite3_bind_double(
                      budgetStmt, 1, budget.budgetUSD
                  ) == SQLITE_OK,
                  sqlite3_bind_int64(
                      budgetStmt, 2, budget.updatedAtMs
                  ) == SQLITE_OK,
                  sqlite3_bind_int64(
                      budgetStmt, 3, budget.resetDayMs
                  ) == SQLITE_OK,
                  sqlite3_bind_int64(
                      budgetStmt, 4,
                      budget.resetDayMs + CreditCycleSummary.dayMs
                  ) == SQLITE_OK,
                  sqlite3_bind_text(
                      budgetStmt, 5, account, -1, sqliteTransient
                  ) == SQLITE_OK,
                  sqlite3_bind_int64(
                      budgetStmt, 6, budget.updatedAtMs
                  ) == SQLITE_OK,
                  sqlite3_step(budgetStmt) == SQLITE_DONE else {
                return false
            }
        }
        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            return false
        }
        committed = true
        return true
    }

    /// The most recently recorded target for one account-scoped cycle. A nil
    /// result is meaningful: it identifies pre-migration history whose target
    /// is unknowable until the user supplies it explicitly.
    static func cycleBudget(resetDayMs: Int64, account: String?) -> Double? {
        cycleBudgetSnapshot(resetDayMs: resetDayMs, account: account)?.budgetUSD
    }

    static func cycleBudgetSnapshot(
        resetDayMs: Int64, account: String?
    ) -> SyncedCycleBudget? {
        guard let db = open() else { return nil }
        defer { sqlite3_close(db) }
        let key = accountKey(account)
        let sql = """
        SELECT budget_usd, updated_at_ms
        FROM credit_cycle_budgets
        WHERE reset_day_ms = ? AND (account_key = ? OR account_key = '')
        ORDER BY CASE WHEN account_key = ? THEN 0 ELSE 1 END
        LIMIT 1
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, resetDayMs)
        sqlite3_bind_text(stmt, 2, key, -1, sqliteTransient)
        sqlite3_bind_text(stmt, 3, key, -1, sqliteTransient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let value = sqlite3_column_double(stmt, 0)
        let updatedAtMs = sqlite3_column_int64(stmt, 1)
        guard isValidBudget(value), updatedAtMs > 0 else { return nil }
        return SyncedCycleBudget(
            resetDayMs: resetDayMs, budgetUSD: value,
            updatedAtMs: updatedAtMs
        )
    }

    /// Apply an explicitly chosen target to every observation in a cycle. This
    /// is used both when today's target changes and when repairing legacy
    /// history; updating the whole cycle avoids a reset-time variant selecting
    /// a different target later.
    @discardableResult
    static func setCycleBudget(
        resetDayMs: Int64,
        account: String?,
        budgetUSD: Double,
        updatedAtMs: Int64
    ) -> Bool {
        guard isValidBudget(budgetUSD), updatedAtMs > 0,
              let db = open() else { return false }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK
        else { return false }
        var committed = false
        defer {
            if !committed { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
        }
        let end = resetDayMs + CreditCycleSummary.dayMs
        let accountClause = account.map {
            "(account IS NULL OR account = '\(escape($0))')"
        } ?? "account IS NULL"
        let sql = """
        UPDATE credit_samples
        SET budget_usd = ?, budget_updated_at_ms = ?
        WHERE reset_at_ms >= \(resetDayMs) AND reset_at_ms < \(end)
          AND \(accountClause)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, budgetUSD)
        sqlite3_bind_int64(stmt, 2, updatedAtMs)
        guard sqlite3_step(stmt) == SQLITE_DONE,
              upsertCycleBudget(
                  db, resetDayMs: resetDayMs, account: account,
                  budgetUSD: budgetUSD, updatedAtMs: updatedAtMs
              ),
              sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            return false
        }
        committed = true
        return true
    }

    /// One-time repair for the cycle immediately preceding this migration.
    /// Unlike `setCycleBudget`, this is atomic and refuses to overwrite any
    /// snapshot already attached to the cycle.
    @discardableResult
    static func assignCycleBudgetIfMissing(
        resetDayMs: Int64,
        account: String?,
        budgetUSD: Double,
        updatedAtMs: Int64
    ) -> Bool {
        guard isValidBudget(budgetUSD), updatedAtMs > 0,
              let db = open() else { return false }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK
        else { return false }
        var committed = false
        defer {
            if !committed { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
        }
        let end = resetDayMs + CreditCycleSummary.dayMs
        let accountClause = account.map {
            "(account IS NULL OR account = '\(escape($0))')"
        } ?? "account IS NULL"
        var insertStmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "INSERT OR IGNORE INTO credit_cycle_budgets(account_key,reset_day_ms,budget_usd,updated_at_ms) VALUES(?,?,?,?)",
            -1, &insertStmt, nil
        ) == SQLITE_OK else { return false }
        sqlite3_bind_text(
            insertStmt, 1, accountKey(account), -1, sqliteTransient
        )
        sqlite3_bind_int64(insertStmt, 2, resetDayMs)
        sqlite3_bind_double(insertStmt, 3, budgetUSD)
        sqlite3_bind_int64(insertStmt, 4, updatedAtMs)
        let inserted = sqlite3_step(insertStmt) == SQLITE_DONE
            && sqlite3_changes(db) == 1
        sqlite3_finalize(insertStmt)
        guard inserted else { return false }
        let sql = """
        UPDATE credit_samples
        SET budget_usd = ?, budget_updated_at_ms = ?
        WHERE reset_at_ms >= \(resetDayMs) AND reset_at_ms < \(end)
          AND \(accountClause)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, budgetUSD)
        sqlite3_bind_int64(stmt, 2, updatedAtMs)
        guard sqlite3_step(stmt) == SQLITE_DONE,
              sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            return false
        }
        committed = true
        return true
    }

    /// Persist the single pre-migration cycle eligible for repair. Keeping the
    /// reset day in metadata prevents the affordance moving to an older cycle
    /// after it is used, or to a newer one after another rollover.
    static func budgetMigrationCycle(
        liveResetDayMs: Int64,
        cycles: [CreditCycleSummary],
        account: String?,
        eligibleStartMonth: String = "2026-08"
    ) -> Int64? {
        guard let account else { return nil }
        let key = budgetMigrationKey(account: account)
        if let stored = CreditSampleStore.getMeta(key) {
            if stored == budgetMigrationComplete { return nil }
            if let resetDayMs = Int64(stored),
               let cycle = cycles.first(where: { $0.resetDayMs == resetDayMs }),
               resetDayMs != liveResetDayMs,
               cycle.startAt.map(CreditCycleSummary.utcMonthKey) == eligibleStartMonth {
                guard cycleBudget(resetDayMs: resetDayMs, account: account) == nil else {
                    CreditSampleStore.setMeta(key, budgetMigrationComplete)
                    return nil
                }
                return resetDayMs
            }
        }

        // This repair exists solely for the August 2026 cycle missed by the
        // original schema migration. It must never drift to "the previous
        // month" as time advances or as users change the current target.
        guard let candidate = cycles.first(where: {
            $0.resetDayMs != liveResetDayMs
                && $0.startAt.map(CreditCycleSummary.utcMonthKey) == eligibleStartMonth
        }) else {
            return nil
        }
        guard cycleBudget(resetDayMs: candidate.resetDayMs, account: account) == nil else {
            CreditSampleStore.setMeta(key, budgetMigrationComplete)
            return nil
        }
        CreditSampleStore.setMeta(key, String(candidate.resetDayMs))
        return candidate.resetDayMs
    }

    static func completeBudgetMigration(account: String?) {
        guard let account else { return }
        CreditSampleStore.setMeta(
            budgetMigrationKey(account: account), budgetMigrationComplete
        )
    }

    private static let budgetMigrationComplete = "complete"

    private static func budgetMigrationKey(account: String) -> String {
        "credit_cycle_budget_migration_v1_\(account)"
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

    /// Load retained history in one database pass, already compacted to the
    /// representation used for sync and rolling activity. The newest cycle
    /// keeps 15-minute buckets; completed cycles keep each UTC day's first,
    /// high-water and last observation. This avoids opening SQLite once per
    /// cycle and avoids materialising either minute-level polls or obsolete
    /// detailed history.
    /// The final observation in every cycle is always retained.
    static func compactedHistory(account: String?) -> HistorySnapshot? {
        guard let db = open() else { return nil }
        defer { sqlite3_close(db) }
        let accountClause = account.map {
            "(account IS NULL OR account = '\(escape($0))')"
        } ?? "account IS NULL"
        let bucketMs: Int64 = 15 * 60 * 1000
        let sql = """
        WITH source AS (
            SELECT captured_at_ms, server_at_ms, reset_at_ms, credits_used,
                   (reset_at_ms / \(CreditCycleSummary.dayMs)) AS reset_day,
                   COALESCE(server_at_ms, captured_at_ms) AS effective_at,
                   (COALESCE(server_at_ms, captured_at_ms)
                       / \(CreditCycleSummary.dayMs)) AS observed_day
            FROM credit_samples
            WHERE \(accountClause)
        ),
        ranked AS (
            SELECT captured_at_ms, server_at_ms, reset_at_ms, credits_used,
                   reset_day,
                   ROW_NUMBER() OVER (
                       PARTITION BY reset_day,
                                    (effective_at / \(bucketMs))
                       ORDER BY effective_at ASC, captured_at_ms ASC
                   ) AS bucket_rank,
                   ROW_NUMBER() OVER (
                       PARTITION BY reset_day, observed_day
                       ORDER BY effective_at ASC, captured_at_ms ASC
                   ) AS day_first_rank,
                   ROW_NUMBER() OVER (
                       PARTITION BY reset_day, observed_day
                       ORDER BY effective_at DESC, captured_at_ms DESC
                   ) AS day_last_rank,
                   ROW_NUMBER() OVER (
                       PARTITION BY reset_day, observed_day
                       ORDER BY credits_used DESC, effective_at DESC,
                                captured_at_ms DESC
                   ) AS day_peak_rank,
                   ROW_NUMBER() OVER (
                       PARTITION BY reset_day
                       ORDER BY effective_at DESC, captured_at_ms DESC
                   ) AS cycle_last_rank,
                   MAX(reset_day) OVER () AS newest_reset_day
            FROM source
        )
        SELECT captured_at_ms, server_at_ms, reset_at_ms, credits_used,
               reset_day, cycle_last_rank
        FROM ranked
        WHERE (reset_day = newest_reset_day
               AND (bucket_rank = 1 OR cycle_last_rank = 1))
           OR (reset_day != newest_reset_day
               AND (day_first_rank = 1 OR day_peak_rank = 1
                    OR day_last_rank = 1
                    OR cycle_last_rank = 1))
        ORDER BY reset_day DESC,
                 COALESCE(server_at_ms, captured_at_ms) ASC,
                 captured_at_ms ASC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        var samplesByCycle: [Int64: [CreditSample]] = [:]
        var latestByCycle: [Int64: CreditSample] = [:]
        var stepResult = sqlite3_step(stmt)
        while stepResult == SQLITE_ROW {
            let sample = CreditSample(
                capturedAtMs: sqlite3_column_int64(stmt, 0),
                serverAtMs: sqlite3_column_type(stmt, 1) == SQLITE_NULL
                    ? nil : sqlite3_column_int64(stmt, 1),
                resetAtMs: sqlite3_column_int64(stmt, 2),
                creditsUsed: sqlite3_column_double(stmt, 3)
            )
            let resetDay = sqlite3_column_int64(stmt, 4)
                * CreditCycleSummary.dayMs
            samplesByCycle[resetDay, default: []].append(sample)
            if sqlite3_column_int64(stmt, 5) == 1 {
                latestByCycle[resetDay] = sample
            }
            stepResult = sqlite3_step(stmt)
        }
        // A mid-query SQLite failure is not a smaller valid history. Returning
        // nil prevents callers from publishing or presenting a partial snapshot.
        guard stepResult == SQLITE_DONE else { return nil }
        let budgetAccountKey = accountKey(account)
        let budgetSQL = """
        SELECT reset_day_ms, budget_usd, updated_at_ms
        FROM credit_cycle_budgets
        WHERE account_key = ? OR account_key = ''
        ORDER BY CASE WHEN account_key = ? THEN 0 ELSE 1 END,
                 updated_at_ms DESC
        """
        var budgetStmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, budgetSQL, -1, &budgetStmt, nil
        ) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(budgetStmt) }
        sqlite3_bind_text(
            budgetStmt, 1, budgetAccountKey, -1, sqliteTransient
        )
        sqlite3_bind_text(
            budgetStmt, 2, budgetAccountKey, -1, sqliteTransient
        )
        var budgetsByCycle: [Int64: SyncedCycleBudget] = [:]
        var budgetStep = sqlite3_step(budgetStmt)
        while budgetStep == SQLITE_ROW {
            let resetDayMs = sqlite3_column_int64(budgetStmt, 0)
            let budget = SyncedCycleBudget(
                resetDayMs: resetDayMs,
                budgetUSD: sqlite3_column_double(budgetStmt, 1),
                updatedAtMs: sqlite3_column_int64(budgetStmt, 2)
            )
            if budgetsByCycle[resetDayMs] == nil,
               isValidBudget(budget.budgetUSD), budget.updatedAtMs > 0 {
                budgetsByCycle[resetDayMs] = budget
            }
            budgetStep = sqlite3_step(budgetStmt)
        }
        guard budgetStep == SQLITE_DONE else { return nil }
        let cycles = latestByCycle
            .map { day, sample in
                CreditCycleSummary(latestSample: sample, firstObservedAtMs: samplesByCycle[day]?.first?.observedAtMs)
            }
            .sorted { $0.resetDayMs > $1.resetDayMs }
        return HistorySnapshot(
            cycles: cycles,
            samplesByCycle: samplesByCycle,
            cycleBudgets: SyncAggregate.compactCycleBudgets(
                Array(budgetsByCycle.values)
            )
        )
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
            SELECT captured_at_ms, server_at_ms, reset_at_ms, credits_used,
                   MIN(COALESCE(server_at_ms, captured_at_ms)) OVER ()
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
                ), firstObservedAtMs: sqlite3_column_int64(latestStmt, 4)))
            }
            sqlite3_finalize(latestStmt)
        }
        return out
    }

    /// Fingerprints are hex, but never build SQL from unvalidated text.
    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private static func isValidBudget(_ value: Double) -> Bool {
        value.isFinite && value >= 0 && value <= BudgetInput.maximum
            && (value == 0 || value >= BudgetInput.minimumNonZero)
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
        sqlite3_exec(
            db,
            "DELETE FROM credit_cycle_budgets WHERE reset_day_ms < \(cutoff)",
            nil, nil, nil
        )
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
