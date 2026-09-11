import Foundation
import SQLite3

// ---------------------------------------------------------------------------
// RemoteStore — a SEPARATE local SQLite store of OTHER machines' pulled sync
// payloads, keyed by random machine UUID. It holds authoritative counter
// observations plus temporary legacy aggregates, never raw spans or content.
//
// Each successful pull atomically replaces the complete peer snapshot. Cleared
// on disable / revert. A missing/foreign machine can be forgotten individually
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

    /// Run verification against a fresh database and restore any caller-provided
    /// override afterwards. This makes the normal verification command exercise
    /// persistence without ever touching the user's cache.
    static func withTemporaryStore(_ body: () -> Void) {
        let previous = ProcessInfo.processInfo.environment["BARPILOT_REMOTE_PATH"]
        let directory = NSTemporaryDirectory()
            + "barpilot-remote-verify-\(UUID().uuidString)"
        do {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true
            )
        } catch {
            preconditionFailure(
                "could not create the remote-store verification directory"
            )
        }
        setenv("BARPILOT_REMOTE_PATH", directory + "/remote.db", 1)
        defer {
            if let previous {
                setenv("BARPILOT_REMOTE_PATH", previous, 1)
            } else {
                unsetenv("BARPILOT_REMOTE_PATH")
            }
            try? FileManager.default.removeItem(atPath: directory)
        }
        precondition(path.hasPrefix(directory),
                     "verification must not use the real remote cache")
        body()
    }

    /// Atomically replace the complete pulled snapshot. Encoding everything
    /// before opening the transaction means a malformed payload cannot clear
    /// the last known-good cache, and one connection avoids per-machine churn.
    @discardableResult
    static func replaceAll(_ payloads: [MachineSyncPayload]) -> Bool {
        guard payloads.count <= SyncAggregate.maximumMachinePayloads else {
            return false
        }
        let encoded: [(MachineSyncPayload, String)] = payloads.compactMap {
            guard let data = SyncAggregate.encodeSupportedPayload($0),
                  let json = String(data: data, encoding: .utf8) else {
                return nil
            }
            return ($0, json)
        }
        guard encoded.count == payloads.count, let db = open() else {
            return false
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK
        else { return false }
        var committed = false
        defer {
            if !committed {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            }
        }
        guard sqlite3_exec(db, "DELETE FROM machines", nil, nil, nil) == SQLITE_OK
        else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "INSERT INTO machines(machine_id, updated_at, json) VALUES (?,?,?)",
            -1, &stmt, nil
        ) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        for (payload, json) in encoded {
            guard sqlite3_reset(stmt) == SQLITE_OK,
                  sqlite3_clear_bindings(stmt) == SQLITE_OK,
                  sqlite3_bind_text(
                    stmt, 1, payload.machineId, -1, SQLITE_TRANSIENT
                  ) == SQLITE_OK,
                  sqlite3_bind_text(
                    stmt, 2, payload.updatedAt, -1, SQLITE_TRANSIENT
                  ) == SQLITE_OK,
                  sqlite3_bind_text(
                    stmt, 3, json, -1, SQLITE_TRANSIENT
                  ) == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_DONE else {
                return false
            }
        }
        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            return false
        }
        committed = true
        return true
    }

    /// All stored machine payloads. A nil result means the snapshot is not safe
    /// to use as a whole: it could not be read, contains an unsupported schema,
    /// or contains an undecodable row. Callers retain their last-good state.
    static func load() -> [MachineSyncPayload]? {
        guard let db = open() else { return nil }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "SELECT json FROM machines", -1, &stmt, nil
        ) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        var out: [MachineSyncPayload] = []
        var stepResult = sqlite3_step(stmt)
        while stepResult == SQLITE_ROW {
            guard out.count < SyncAggregate.maximumMachinePayloads else {
                return nil
            }
            guard let c = sqlite3_column_text(stmt, 0),
                  let data = String(cString: c).data(using: .utf8),
                  let payload = SyncAggregate.decodeSupportedPayload(data) else {
                return nil
            }
            out.append(payload)
            stepResult = sqlite3_step(stmt)
        }
        return stepResult == SQLITE_DONE ? out : nil
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
