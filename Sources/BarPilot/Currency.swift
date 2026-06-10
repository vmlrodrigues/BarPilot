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

enum ExchangeRate {
    /// Current USD→AUD rate from open.er-api.com (free, no key). Nil on failure.
    static func fetchUSDToAUD() async -> Double? {
        guard let url = URL(string: "https://open.er-api.com/v6/latest/USD") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["result"] as? String) == "success",
              let rates = json["rates"] as? [String: Any],
              let aud = (rates["AUD"] as? NSNumber)?.doubleValue, aud > 0
        else { return nil }
        return aud
    }
}
