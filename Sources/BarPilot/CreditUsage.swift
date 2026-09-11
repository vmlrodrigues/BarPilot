import Foundation
import CommonCrypto

// ---------------------------------------------------------------------------
// CreditUsageAPI — account-level Copilot usage from GitHub's own counter.
//
// `/copilot_internal/user` is an internal endpoint used by GitHub clients. Its
// schema is intentionally parsed defensively and every failure leaves the last
// good local sample untouched.
// ---------------------------------------------------------------------------

enum CreditUsageError: Error {
    case network
    case unauthorized
    case forbidden
    case invalidResponse
}

struct CreditSample: Equatable {
    let capturedAtMs: Int64
    let serverAtMs: Int64?
    let resetAtMs: Int64
    let creditsUsed: Double

    var capturedAt: Date { Date(timeIntervalSince1970: Double(capturedAtMs) / 1000) }
    var resetAt: Date { Date(timeIntervalSince1970: Double(resetAtMs) / 1000) }
}

enum CreditUsageAPI {
    private static let earliestSupportedUnixSeconds = 946_684_800.0 // 2000-01-01
    private static let latestSupportedUnixSeconds = 4_102_444_800.0 // 2100-01-01
    private static let maximumCycleAheadSeconds: TimeInterval = 40 * 24 * 60 * 60
    private static let maximumServerClockSkewSeconds: TimeInterval = 24 * 60 * 60

    /// Equality key for preventing observations from different Copilot accounts
    /// being merged. It has to be deterministic across Macs, so no per-install
    /// salt is possible — and a plain SHA-256 over GitHub's small, dense numeric
    /// id space is trivially reversed with a precomputed table, which matters
    /// because this value is published into the sync gist. PBKDF2 with a high
    /// iteration count makes that enumeration impractical while costing one
    /// hash per connect. The underlying account identifier is never stored or
    /// included in the sync payload.
    static func accountFingerprint(token: String) async -> String? {
        var req = URLRequest(url: URL(string: "https://api.github.com/user")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("BarPilot", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 30
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? NSNumber else { return nil }
        return derivedFingerprint(accountId: id.int64Value)
    }

    /// Stable identity for the connected account.
    ///
    /// Changing anything here — algorithm, salt, iteration count, or the
    /// password string — changes the fingerprint for accounts that have not
    /// changed at all. Saved samples carry the *old* fingerprint, so they are no
    /// longer `NULL` and `adoptUnattributed` cannot rescue them; queries under
    /// the new fingerprint return nothing and the user's history disappears
    /// exactly as it did before rows were attributed. If this ever has to
    /// change, ship it with a migration that re-maps old to new (and bump the
    /// adoption meta key), not on its own.
    static func derivedFingerprint(accountId: Int64) -> String? {
        var out = [UInt8](repeating: 0, count: 16)
        let password = Array("barpilot-credit:\(accountId)".utf8)
        let salt = Array("barpilot-account-fingerprint-v1".utf8)
        let status = password.withUnsafeBufferPointer { pwd in
            salt.withUnsafeBufferPointer { slt in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pwd.baseAddress!.withMemoryRebound(to: CChar.self, capacity: pwd.count) { $0 },
                    pwd.count,
                    slt.baseAddress!, slt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    600_000,
                    &out, out.count
                )
            }
        }
        guard status == kCCSuccess else { return nil }
        return out.map { String(format: "%02x", $0) }.joined()
    }

    static func fetch(token: String, now: Date = Date()) async throws -> CreditSample {
        var req = URLRequest(url: URL(string: "https://api.github.com/copilot_internal/user")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("BarPilot", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 30

        let data: Data
        let http: HTTPURLResponse
        do {
            let response = try await URLSession.shared.data(for: req)
            data = response.0
            guard let h = response.1 as? HTTPURLResponse else { throw CreditUsageError.network }
            http = h
        } catch let error as CreditUsageError {
            throw error
        } catch {
            throw CreditUsageError.network
        }

        switch http.statusCode {
        case 200: break
        case 401: throw CreditUsageError.unauthorized
        case 403: throw CreditUsageError.forbidden
        default: throw CreditUsageError.network
        }

        return try parse(data: data, capturedAt: now)
    }

    static func parse(data: Data, capturedAt: Date) throws -> CreditSample {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let snapshots = root["quota_snapshots"] as? [String: Any],
              let premium = snapshots["premium_interactions"] as? [String: Any],
              let credits = number(premium["credits_used"]),
              credits.isFinite, credits >= 0,
              let capturedAtMs = timestampMilliseconds(capturedAt),
              let reset = resetDate(root: root, premium: premium),
              let resetAtMs = timestampMilliseconds(reset),
              reset > capturedAt,
              reset.timeIntervalSince(capturedAt) <= maximumCycleAheadSeconds else {
            throw CreditUsageError.invalidResponse
        }

        let serverAtMs: Int64? = (premium["timestamp_utc"] as? String)
            .flatMap(parseISO)
            .flatMap { serverAt in
                guard abs(serverAt.timeIntervalSince(capturedAt))
                        <= maximumServerClockSkewSeconds else { return nil }
                return timestampMilliseconds(serverAt)
            }
        let sample = CreditSample(
            capturedAtMs: capturedAtMs,
            serverAtMs: serverAtMs,
            resetAtMs: resetAtMs,
            creditsUsed: credits
        )
        guard isPlausible(sample) else {
            throw CreditUsageError.invalidResponse
        }
        return sample
    }

    /// Semantic timestamp validation shared with untrusted sync payloads. The
    /// absolute range alone is insufficient: a current reset paired with a
    /// capture in 2099 would otherwise outrank every genuine observation.
    static func isPlausible(_ sample: CreditSample) -> Bool {
        let capturedAt = Date(
            timeIntervalSince1970: Double(sample.capturedAtMs) / 1_000
        )
        let resetAt = Date(
            timeIntervalSince1970: Double(sample.resetAtMs) / 1_000
        )
        guard timestampMilliseconds(capturedAt) != nil,
              timestampMilliseconds(resetAt) != nil,
              sample.creditsUsed.isFinite,
              sample.creditsUsed >= 0,
              resetAt > capturedAt,
              resetAt.timeIntervalSince(capturedAt)
                <= maximumCycleAheadSeconds else { return false }
        guard let serverAtMs = sample.serverAtMs else { return true }
        let serverAt = Date(
            timeIntervalSince1970: Double(serverAtMs) / 1_000
        )
        return timestampMilliseconds(serverAt) != nil
            && abs(serverAt.timeIntervalSince(capturedAt))
                <= maximumServerClockSkewSeconds
    }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static func parseISO(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) {
            return date
        }
        let parts = value.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else {
            return nil
        }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        guard let date = utc.date(
            from: DateComponents(year: year, month: month, day: day)
        ) else { return nil }
        let resolved = utc.dateComponents([.year, .month, .day], from: date)
        guard resolved.year == year, resolved.month == month,
              resolved.day == day else { return nil }
        return date
    }

    private static func resetDate(root: [String: Any], premium: [String: Any]) -> Date? {
        let values: [Any?] = [
            root["quota_reset_date_utc"],
            root["quota_reset_date"],
            root["limited_user_reset_date"],
            premium["quota_reset_at"]
        ]
        for value in values {
            if let string = value as? String, let date = parseISO(string) { return date }
            if let epoch = number(value), epoch.isFinite, epoch > 0 {
                let seconds = epoch > 10_000_000_000 ? epoch / 1000 : epoch
                let date = Date(timeIntervalSince1970: seconds)
                if timestampMilliseconds(date) != nil { return date }
            }
        }
        return nil
    }

    private static func timestampMilliseconds(_ date: Date) -> Int64? {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite,
              seconds >= earliestSupportedUnixSeconds,
              seconds <= latestSupportedUnixSeconds else { return nil }
        return Int64(seconds * 1_000)
    }
}
