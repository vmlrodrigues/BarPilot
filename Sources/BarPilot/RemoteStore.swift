import Foundation
import SQLite3

// ---------------------------------------------------------------------------
// RemoteStore — a SEPARATE local SQLite store of OTHER machines' pulled sync
// payloads, keyed by random machine UUID. It holds authoritative counter
// observations plus temporary legacy aggregates, never raw spans or content.
//
// Each pull replaces a machine's row wholesale (INSERT OR REPLACE). Cleared on
// disable / revert. A missing/foreign machine can be forgotten individually
// (staleness prune). Path is overridable via BARPILOT_REMOTE_PATH for testing.
// ---------------------------------------------------------------------------

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum RemoteStore {
    static var path: String {
        if let o = ProcessInfo.processInfo.environment["BARPILOT_REMOTE_PATH"], !o.isEmpty { return o }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/Library/Application Support/com.victorrodrigues.barpilot/remote-aggregates.db"
    }

    private static func open() -> OpaquePointer? {
        let p = path
        try? FileManager.default.createDirectory(
            atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open_v2(p, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return nil
        }
        sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
        sqlite3_busy_timeout(db, 5000)
        sqlite3_exec(db, """
        CREATE TABLE IF NOT EXISTS machines (
            machine_id TEXT PRIMARY KEY,
            updated_at TEXT,
            json       TEXT NOT NULL
        );
        """, nil, nil, nil)
        return db
    }

    /// Store (or replace) one machine's payload.
    static func save(_ agg: MachineSyncPayload) {
        guard let data = try? JSONEncoder().encode(agg),
              let json = String(data: data, encoding: .utf8),
              let db = open() else { return }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO machines(machine_id, updated_at, json) VALUES (?,?,?)", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, agg.machineId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, agg.updatedAt, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, json, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    /// All stored machine payloads (undecodable rows are skipped).
    static func load() -> [MachineSyncPayload] {
        guard let db = open() else { return [] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT json FROM machines", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [MachineSyncPayload] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0),
               let data = String(cString: c).data(using: .utf8),
               let agg = try? JSONDecoder().decode(MachineSyncPayload.self, from: data) {
                out.append(agg)
            }
        }
        return out
    }

    /// Machine refs (for staleness / manage UI), without decoding all rows' data.
    static func machines() -> [MachineRef] {
        guard let db = open() else { return [] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT machine_id, updated_at FROM machines", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [MachineRef] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let upd = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
            out.append(MachineRef(machineId: id, label: nil, updatedAt: upd ?? ""))
        }
        return out
    }

    /// Forget one machine (staleness prune / manual remove).
    static func remove(machineId: String) {
        guard let db = open() else { return }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM machines WHERE machine_id=?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, machineId, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt); sqlite3_finalize(stmt)
        }
    }

    /// Wipe all remote payloads (on disable / revert). Local history is untouched.
    static func clear() {
        guard let db = open() else { return }
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "DELETE FROM machines", nil, nil, nil)
    }
}
