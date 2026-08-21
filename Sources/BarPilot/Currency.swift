import Foundation

// ---------------------------------------------------------------------------
// Currency — display currency + USD→AUD exchange rate.
//
// All of BarPilot's data is computed in USD (100 credits = $1.00). AUD is a
// display-time conversion using a live rate fetched from a free, no-API-key
// service (open.er-api.com), cached so it works offline and across launches.
// ---------------------------------------------------------------------------

enum Currency: String, CaseIterable {
    case usd
    case aud

    var symbol: String { self == .aud ? "A$" : "$" }
    var code: String { self == .aud ? "AUD" : "USD" }
    var menuLabel: String { self == .aud ? "Australian Dollars (A$)" : "US Dollars ($)" }
}

/// A provider-versioned USD→AUD quote. The provider timestamp, rather than the
/// local fetch time, lets multiple Macs deterministically agree on the newest rate.
struct ExchangeRateSnapshot: Codable, Equatable {
    var usdToAUD: Double
    var providerUpdatedAtUnix: Int64
    var providerNextUpdateAtUnix: Int64?

    func isValid(nowUnix: Int64 = Int64(Date().timeIntervalSince1970)) -> Bool {
        guard usdToAUD.isFinite, usdToAUD > 0,
              providerUpdatedAtUnix > 0,
              providerUpdatedAtUnix <= nowUnix + 60 * 60
        else { return false }
        guard let next = providerNextUpdateAtUnix else { return true }
        return next > providerUpdatedAtUnix && next <= providerUpdatedAtUnix + 3 * 24 * 60 * 60
    }

    /// First candidate wins ties, so a Mac keeps its current value when two
    /// payloads claim the same provider vintage.
    static func newestValid(
        _ candidates: [ExchangeRateSnapshot?],
        nowUnix: Int64 = Int64(Date().timeIntervalSince1970)
    ) -> ExchangeRateSnapshot? {
        var newest: ExchangeRateSnapshot?
        for case let candidate? in candidates where candidate.isValid(nowUnix: nowUnix) {
            if newest == nil || candidate.providerUpdatedAtUnix > newest!.providerUpdatedAtUnix {
                newest = candidate
            }
        }
        return newest
    }
}

enum ExchangeRate {
    /// Parse the current provider-versioned USD→AUD quote. Nil for malformed,
    /// invalid or implausibly future-dated responses.
    static func parseUSDToAUD(_ data: Data, now: Date = Date()) -> ExchangeRateSnapshot? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["result"] as? String) == "success",
              let rates = json["rates"] as? [String: Any],
              let aud = (rates["AUD"] as? NSNumber)?.doubleValue,
              let updated = (json["time_last_update_unix"] as? NSNumber)?.int64Value
        else { return nil }
        let snapshot = ExchangeRateSnapshot(
            usdToAUD: aud,
            providerUpdatedAtUnix: updated,
            providerNextUpdateAtUnix:
                (json["time_next_update_unix"] as? NSNumber)?.int64Value
        )
        return snapshot.isValid(nowUnix: Int64(now.timeIntervalSince1970)) ? snapshot : nil
    }

    /// Current USD→AUD quote from open.er-api.com (free, no key). Nil on failure.
    static func fetchUSDToAUD() async -> ExchangeRateSnapshot? {
        guard let url = URL(string: "https://open.er-api.com/v6/latest/USD") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return parseUSDToAUD(data)
    }
}
