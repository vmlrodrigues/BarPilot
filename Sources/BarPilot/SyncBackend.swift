import Foundation

// ---------------------------------------------------------------------------
// SyncBackend — the transport seam for multi-machine sync. GitHub (a secret
// gist) is the first implementation; the merge/projection core is
// transport-agnostic, so another backend (CloudKit, etc.) could slot in behind
// this later without touching the rest of the app.
//
// Each machine pushes ONLY its own file. A sync reads the complete snapshot
// before writing so it can recover its own last-published history and refuse to
// overwrite a payload written by a newer schema.
// ---------------------------------------------------------------------------

/// A machine's identity + last-seen, for the staleness/manage view.
struct MachineRef {
    let machineId: String
    let label: String?
    let updatedAt: String
}

protocol SyncBackend {
    /// Upload THIS machine's payload (its own file only — never others').
    func push(_ payload: MachineSyncPayload) async throws

    /// Download every machine payload, including this machine's existing file.
    /// Callers must inspect that self payload before overwriting it.
    func pullAll() async throws -> [MachineSyncPayload]

    /// Download every OTHER machine's payload (excluding this machine's id).
    func pullOthers(excluding selfId: String) async throws -> [MachineSyncPayload]

    /// List machines present on the backend (for staleness / manage UI).
    func listMachines() async throws -> [MachineRef]
}

extension SyncBackend {
    func pullOthers(excluding selfId: String) async throws -> [MachineSyncPayload] {
        try await pullAll().filter { $0.machineId != selfId }
    }
}
