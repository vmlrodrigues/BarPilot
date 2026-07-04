import Foundation

// ---------------------------------------------------------------------------
// GitHubBackend — SyncBackend over GitHub: device-flow OAuth (gist scope) for
// auth, and a single SECRET GIST (one file per machine) for storage. Only ever
// touches gists; never repos or org resources.
//
//   Auth:    static requestDeviceCode() → show code → pollForToken() → token
//   Storage: one secret gist marked in its description; files machine-<uuid>.json
//            push() writes only this machine's file; pullOthers() reads the rest.
// ---------------------------------------------------------------------------

enum SyncError: Error {
    case network, denied, expired, encoding, forbidden, unauthorized
    /// Won't fix itself — stop auto-retrying until the user re-authorizes.
    var isPermanent: Bool {
        switch self { case .forbidden, .unauthorized: return true; default: return false }
    }
}

struct DeviceCode {
    let deviceCode: String
    let userCode: String
    let verificationUri: String
    let interval: Int
    let expiresIn: Int
}

struct GitHubBackend: SyncBackend {
    static let clientId = "Ov23li5NCU0DDUNHo0Zp"
    static let gistMarker = "[barpilot-sync-v1]"
    static let gistDescription = "BarPilot multi-machine sync — do not delete. \(gistMarker)"

    let token: String

    // MARK: Device flow (no token yet)

    static func requestDeviceCode() async throws -> DeviceCode {
        var req = URLRequest(url: URL(string: "https://github.com/login/device/code")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = "client_id=\(clientId)&scope=gist".data(using: .utf8)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dc = j["device_code"] as? String, let uc = j["user_code"] as? String,
              let uri = j["verification_uri"] as? String else { throw SyncError.network }
        return DeviceCode(deviceCode: dc, userCode: uc, verificationUri: uri,
                          interval: (j["interval"] as? Int) ?? 5, expiresIn: (j["expires_in"] as? Int) ?? 900)
    }

    /// Poll until the user authorizes (or the code expires). Returns the token.
    static func pollForToken(deviceCode: String, interval: Int, expiresIn: Int) async throws -> String {
        var wait = max(interval, 1)
        let deadline = Date().addingTimeInterval(Double(expiresIn))
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000)
            var req = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = "client_id=\(clientId)&device_code=\(deviceCode)&grant_type=urn:ietf:params:oauth:grant-type:device_code".data(using: .utf8)
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let token = j["access_token"] as? String { return token }
            switch j["error"] as? String {
            case "slow_down":            wait = (j["interval"] as? Int) ?? (wait + 5)   // honor GitHub's requested backoff
            case "access_denied":        throw SyncError.denied
            case "expired_token":        throw SyncError.expired
            default:                     continue   // authorization_pending / transient
            }
        }
        throw SyncError.expired
    }

    // MARK: Gist storage (SyncBackend)

    private func authed(_ url: URL, _ method: String = "GET", _ body: Data? = nil) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("BarPilot", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 30
        if let body { req.httpBody = body; req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return req
    }

    /// Perform a request; return the body on the expected status, else throw a
    /// specific SyncError so the UI can explain it (401 = bad token, 403 = gists
    /// disabled / forbidden — the enterprise-account case).
    private func send(_ req: URLRequest, expect: Int) async throws -> Data {
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { throw SyncError.network }
        if http.statusCode == expect { return data }
        switch http.statusCode {
        case 401: throw SyncError.unauthorized
        case 403:
            // GitHub also returns 403 for rate limiting, which is transient — not a
            // "this account can't create gists" situation. Treat those as retryable.
            let rateLimited = http.value(forHTTPHeaderField: "Retry-After") != nil
                || http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0"
            throw rateLimited ? SyncError.network : SyncError.forbidden
        default:  throw SyncError.network
        }
    }

    /// Our sync gist id (found by the marker in its description), or nil.
    private func findGistId() async throws -> String? {
        let data = try await send(authed(URL(string: "https://api.github.com/gists?per_page=100")!), expect: 200)
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw SyncError.network }
        // Deterministic: if a first-enable race created two marked gists, every
        // machine binds to the OLDEST one, so they converge instead of splitting.
        return arr
            .filter { ($0["description"] as? String)?.contains(Self.gistMarker) == true }
            .min { ($0["created_at"] as? String ?? "") < ($1["created_at"] as? String ?? "") }?["id"] as? String
    }

    func push(_ aggregate: MachineAggregate) async throws {
        guard let data = try? JSONEncoder().encode(aggregate),
              let json = String(data: data, encoding: .utf8) else { throw SyncError.encoding }
        let files: [String: Any] = ["machine-\(aggregate.machineId).json": ["content": json]]
        if let id = try await findGistId() {
            let body = try JSONSerialization.data(withJSONObject: ["files": files])
            _ = try await send(authed(URL(string: "https://api.github.com/gists/\(id)")!, "PATCH", body), expect: 200)
        } else {
            let body = try JSONSerialization.data(withJSONObject: ["description": Self.gistDescription, "public": false, "files": files])
            _ = try await send(authed(URL(string: "https://api.github.com/gists")!, "POST", body), expect: 201)
        }
    }

    func pullOthers(excluding selfId: String) async throws -> [MachineAggregate] {
        guard let id = try await findGistId() else { return [] }
        let data = try await send(authed(URL(string: "https://api.github.com/gists/\(id)")!), expect: 200)
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = j["files"] as? [String: Any] else { throw SyncError.network }
        var out: [MachineAggregate] = []
        for (name, meta) in files {
            guard name.hasPrefix("machine-"), let m = meta as? [String: Any],
                  let content = m["content"] as? String,
                  let cdata = content.data(using: .utf8),
                  let agg = try? JSONDecoder().decode(MachineAggregate.self, from: cdata),
                  agg.machineId != selfId else { continue }
            out.append(agg)
        }
        return out
    }

    func listMachines() async throws -> [MachineRef] {
        try await pullOthers(excluding: "").map { MachineRef(machineId: $0.machineId, label: $0.machineLabel, updatedAt: $0.updatedAt) }
    }

    /// The GitHub login this token is authorized as (for the status bubble).
    func currentLogin() async -> String? {
        guard let (data, resp) = try? await URLSession.shared.data(for: authed(URL(string: "https://api.github.com/user")!)),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return j["login"] as? String
    }
}
