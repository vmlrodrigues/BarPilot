import Foundation

// ---------------------------------------------------------------------------
// SyncBackend — the transport seam for multi-machine sync. GitHub (a secret
// gist) is the first implementation; the combine/aggregate core is
// transport-agnostic, so another backend (CloudKit, etc.) could slot in behind
// this later without touching the rest of the app.
//
// Each machine pushes ONLY its own file; pulling is read-only of the others.
// ---------------------------------------------------------------------------

/// A machine's identity + last-seen, for the staleness/manage view.
struct MachineRef {
    let machineId: String
    let label: String?
    let updatedAt: String
}

protocol SyncBackend {
    /// Upload THIS machine's aggregate (its own file only — never others').
    func push(_ aggregate: MachineAggregate) async throws

    /// Download every OTHER machine's aggregate (excluding this machine's id).
    func pullOthers(excluding selfId: String) async throws -> [MachineAggregate]

    /// List machines present on the backend (for staleness / manage UI).
    func listMachines() async throws -> [MachineRef]
}
