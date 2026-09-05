import Foundation
import SwiftUI

// ---------------------------------------------------------------------------
// Model pricing — offline-first client and dialogue for the daily catalogue
// published by .github/workflows/publish-model-pricing.yml.
//
// The public catalogue is authoritative when reachable. A validated copy is
// cached for twelve hours and a small built-in snapshot keeps the feature useful
// on a first offline launch. The user's shortlist is deliberately app-owned; it
// is not baked into the public data contract.
// ---------------------------------------------------------------------------

struct ModelPricingCatalog: Codable, Equatable {
    let schemaVersion: Int
    let generatedAt: Date
    let pricingUnit: String
    let source: ModelPricingSource
    /// Optional by design: a temporary LM Arena outage must not prevent newer,
    /// independently authoritative GitHub prices from being published.
    let communityPreferenceSource: ModelCommunityPreferenceSource?
    let modelCount: Int
    let models: [ModelPricingModel]

    func validated() throws -> ModelPricingCatalog {
        guard schemaVersion == 2 else {
            throw ModelPricingError.invalidCatalog("Unsupported schema version \(schemaVersion).")
        }
        guard pricingUnit == "USD per 1 million tokens" else {
            throw ModelPricingError.invalidCatalog("Unexpected pricing unit.")
        }
        guard !models.isEmpty, modelCount == models.count else {
            throw ModelPricingError.invalidCatalog("The model count is inconsistent.")
        }
        let sourceURL = URL(string: source.url)
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        guard source.repository == "github/docs",
              source.path == "data/tables/copilot/models-and-pricing.yml",
              sourceURL?.scheme == "https", sourceURL?.host == "github.com",
              source.revision.count == 40,
              source.revision.unicodeScalars.allSatisfy(hex.contains),
              source.sha256.count == 64,
              source.sha256.unicodeScalars.allSatisfy(hex.contains) else {
            throw ModelPricingError.invalidCatalog("The catalogue source metadata is invalid.")
        }
        guard generatedAt <= Date().addingTimeInterval(24 * 60 * 60) else {
            throw ModelPricingError.invalidCatalog("The generated timestamp is implausibly future-dated.")
        }
        if let communityPreferenceSource {
            let preferenceURL = URL(string: communityPreferenceSource.url)
            let preferenceLicenseURL = URL(string: communityPreferenceSource.licenseURL)
            guard communityPreferenceSource.publisher == "LM Arena",
                  communityPreferenceSource.dataset == "lmarena-ai/leaderboard-dataset",
                  communityPreferenceSource.configuration == "text_style_control",
                  communityPreferenceSource.split == "latest",
                  communityPreferenceSource.category == "overall",
                  communityPreferenceSource.license == "CC BY 4.0",
                  communityPreferenceSource.revision.count == 40,
                  communityPreferenceSource.revision.unicodeScalars.allSatisfy(hex.contains),
                  communityPreferenceSource.snapshotDate.range(
                    of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression
                  ) != nil,
                  ISO8601DateFormatter().date(
                    from: "\(communityPreferenceSource.snapshotDate)T00:00:00Z"
                  ) != nil,
                  preferenceURL?.absoluteString
                    == "https://huggingface.co/datasets/lmarena-ai/leaderboard-dataset",
                  preferenceLicenseURL?.absoluteString
                    == "https://creativecommons.org/licenses/by/4.0/" else {
                throw ModelPricingError.invalidCatalog("The community-preference source metadata is invalid.")
            }
        }

        var modelIDs = Set<String>()
        for model in models {
            guard model.id.range(
                of: "^[a-z0-9_]+:[a-z0-9][a-z0-9.-]*$",
                options: .regularExpression
            ) != nil,
                  !model.name.isEmpty, !model.provider.isEmpty,
                  modelIDs.insert(model.id).inserted else {
                throw ModelPricingError.invalidCatalog("A model identifier is empty or duplicated.")
            }
            guard ["generally-available", "public-preview"].contains(model.releaseStatus),
                  (1...2).contains(model.tiers.count) else {
                throw ModelPricingError.invalidCatalog("\(model.name) has unsupported availability or tiers.")
            }
            var tierIDs = Set<String>()
            for tier in model.tiers {
                guard ["standard", "long-context"].contains(tier.id),
                      tierIDs.insert(tier.id).inserted,
                      tier.prices.isValid,
                      tier.inputTokenRange == nil || tier.inputTokenRange!.tokens > 0 else {
                    throw ModelPricingError.invalidCatalog("\(model.name) contains invalid pricing.")
                }
            }
            guard tierIDs.contains("standard"),
                  model.tiers.count == 1 || tierIDs.contains("long-context") else {
                throw ModelPricingError.invalidCatalog("\(model.name) is missing a standard or long-context tier.")
            }
            let standard = model.standardTier
            guard standard.label == "Standard context" else {
                throw ModelPricingError.invalidCatalog("\(model.name) has an invalid standard-tier label.")
            }
            if let long = model.tiers.first(where: { $0.id == "long-context" }) {
                guard long.label == "Long context",
                      standard.inputTokenRange?.operatorName == "less-than-or-equal",
                      long.inputTokenRange?.operatorName == "greater-than",
                      standard.inputTokenRange?.tokens == long.inputTokenRange?.tokens else {
                    throw ModelPricingError.invalidCatalog("\(model.name) has incomplete context-tier boundaries.")
                }
            } else if standard.inputTokenRange != nil {
                throw ModelPricingError.invalidCatalog("\(model.name) has a threshold without long-context pricing.")
            }
            if let preference = model.communityPreference {
                guard communityPreferenceSource != nil else {
                    throw ModelPricingError.invalidCatalog(
                        "\(model.name) has a community rank without source metadata."
                    )
                }
                guard preference.isValid else {
                    throw ModelPricingError.invalidCatalog(
                        "\(model.name) contains invalid community-preference data."
                    )
                }
            }
        }
        let providers = Set(models.map(\.provider))
        guard providers.isSuperset(of: ["openai", "anthropic", "google"]) else {
            throw ModelPricingError.invalidCatalog("The catalogue is missing a major provider.")
        }
        return self
    }
}

struct ModelPricingSource: Codable, Equatable {
    let repository: String
    let path: String
    let revision: String
    let sha256: String
    let url: String
}

struct ModelCommunityPreferenceSource: Codable, Equatable {
    let publisher: String
    let dataset: String
    let configuration: String
    let split: String
    let category: String
    let revision: String
    let snapshotDate: String
    let license: String
    let licenseURL: String
    let url: String
}

struct ModelPricingModel: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let provider: String
    let releaseStatus: String
    let category: String
    let sourceAnnotations: [String]
    let tiers: [ModelPricingTier]
    let notes: String?
    let communityPreference: ModelCommunityPreference?

    var standardTier: ModelPricingTier { tiers.first { $0.id == "standard" } ?? tiers[0] }

    func tier(forInputTokens inputTokens: Double) -> ModelPricingTier {
        guard tiers.count > 1 else { return standardTier }
        return tiers.first { tier in
            guard let range = tier.inputTokenRange else { return tier.id == "standard" }
            switch range.operatorName {
            case "greater-than": return inputTokens > Double(range.tokens)
            case "less-than-or-equal": return inputTokens <= Double(range.tokens)
            default: return false
            }
        } ?? standardTier
    }

    /// Estimate one request using the same semantics everywhere in the app.
    /// GitHub's threshold applies to all input sent for the request, including
    /// input written to a prompt cache. If GitHub does not publish a distinct
    /// cache-write rate, those tokens are conservatively charged as fresh input.
    func estimate(
        freshInput: Double,
        cachedInput: Double,
        cacheWrite: Double,
        output: Double
    ) -> ModelPricingEstimate {
        let tier = tier(forInputTokens: freshInput + cachedInput + cacheWrite)
        let prices = tier.prices
        let usd = freshInput / 1_000_000 * prices.input
            + cachedInput / 1_000_000 * prices.cachedInput
            + cacheWrite / 1_000_000 * (prices.cacheWrite ?? prices.input)
            + output / 1_000_000 * prices.output
        return ModelPricingEstimate(tier: tier, usd: usd)
    }

    var providerLabel: String {
        switch provider {
        case "openai": return "OpenAI"
        case "anthropic": return "Anthropic"
        case "google": return "Google"
        case "xai": return "xAI"
        case "microsoft": return "Microsoft"
        case "github": return "GitHub"
        case "moonshot_ai": return "Moonshot AI"
        default: return provider.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    var releaseStatusLabel: String {
        releaseStatus == "generally-available" ? "Generally available" : "Public preview"
    }

    /// GitHub's catalogue categories are source taxonomy, not release status.
    /// Present them as concise usage roles so "Versatile" is not mistaken for
    /// availability; the unmodified category remains in the decoded contract.
    var usageRoleLabel: String {
        switch category.lowercased() {
        case "lightweight": return "Fast"
        case "versatile": return "Balanced"
        case "powerful": return "Deep reasoning"
        default: return category
        }
    }
}

struct ModelPricingEstimate: Equatable {
    let tier: ModelPricingTier
    let usd: Double
}

struct ModelCommunityPreference: Codable, Equatable {
    let bestRank: Int
    let worstRank: Int
    let variants: [ModelCommunityPreferenceVariant]

    var rankLabel: String {
        bestRank == worstRank ? "#\(bestRank)" : "#\(bestRank)–\(worstRank)"
    }

    var isValid: Bool {
        guard bestRank > 0, worstRank >= bestRank, !variants.isEmpty else { return false }
        var names = Set<String>()
        for variant in variants {
            guard variant.isValid, names.insert(variant.arenaModel).inserted else { return false }
        }
        let ranks = variants.map(\.rank)
        return bestRank == ranks.min()
            && worstRank == ranks.max()
            && variants.map(\.rank) == variants.map(\.rank).sorted()
    }
}

struct ModelCommunityPreferenceVariant: Codable, Equatable, Identifiable {
    let arenaModel: String
    let label: String
    let rank: Int
    let rating: Double
    let ratingLower: Double
    let ratingUpper: Double
    let voteCount: Int

    var id: String { arenaModel }

    var isValid: Bool {
        !arenaModel.isEmpty && !label.isEmpty && rank > 0 && voteCount >= 0
            && [rating, ratingLower, ratingUpper].allSatisfy { $0.isFinite && $0 >= 0 }
            && ratingLower <= rating && rating <= ratingUpper
    }
}

struct ModelPricingTier: Codable, Equatable, Identifiable {
    let id: String
    let label: String
    let inputTokenRange: ModelPricingTokenRange?
    let prices: ModelTokenPrices

    var rangeLabel: String? {
        guard let range = inputTokenRange else { return nil }
        let amount = ModelPricingFormat.tokens(Double(range.tokens))
        return range.operatorName == "greater-than" ? ">\(amount) input" : "≤\(amount) input"
    }
}

struct ModelPricingTokenRange: Codable, Equatable {
    let operatorName: String
    let tokens: Int

    enum CodingKeys: String, CodingKey {
        case operatorName = "operator"
        case tokens
    }
}

struct ModelTokenPrices: Codable, Equatable {
    let input: Double
    let cachedInput: Double
    let cacheWrite: Double?
    let output: Double

    var isValid: Bool {
        [input, cachedInput, output].allSatisfy { $0.isFinite && $0 >= 0 }
            && (cacheWrite == nil || (cacheWrite!.isFinite && cacheWrite! >= 0))
    }
}

enum ModelPricingError: LocalizedError {
    case invalidCatalog(String)
    case requestFailed

    var errorDescription: String? {
        switch self {
        case .invalidCatalog(let reason): return "Invalid pricing catalogue: \(reason)"
        case .requestFailed: return "The latest model prices could not be downloaded."
        }
    }
}

private enum ModelPricingCache {
    static let refreshInterval: TimeInterval = 12 * 60 * 60

    static var fileURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return base.appendingPathComponent("BarPilot", isDirectory: true)
            .appendingPathComponent("model-pricing-v2.json")
    }

    static func load() -> (catalog: ModelPricingCatalog, modifiedAt: Date)? {
        let url = fileURL
        guard let data = try? Data(contentsOf: url),
              let catalog = try? ModelPricingCodec.decode(data).validated() else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modifiedAt = attributes?[.modificationDate] as? Date ?? .distantPast
        return (catalog, modifiedAt)
    }

    static func save(_ data: Data) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }
}

private enum ModelPricingCodec {
    static func decode(_ data: Data) throws -> ModelPricingCatalog {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ModelPricingCatalog.self, from: data)
    }
}

@MainActor
final class ModelPricingStore: ObservableObject {
    enum Origin {
        case bundled
        case cache
        case network
    }

    static let catalogURL = URL(
        string: "https://vmlrodrigues.github.io/BarPilot/model-pricing/v2/catalog.json"
    )!
    static let defaultShortlist: Set<String> = [
        "openai:gpt-5.6-sol",
        "openai:gpt-5.6-terra",
        "anthropic:claude-opus-5",
        "anthropic:claude-sonnet-5",
        "google:gemini-3.8-flash",
        "xai:grok-4.6",
        "moonshot_ai:kimi-k3",
    ]

    @Published private(set) var catalog = ModelPricingCatalog.bundledFallback
    @Published private(set) var origin: Origin = .bundled
    @Published private(set) var isRefreshing = false
    @Published private(set) var refreshMessage: String?
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var shortlistIDs: Set<String>

    private var loadedCache = false
    private static let shortlistKey = "modelPricingShortlistV1"

    init(defaults: UserDefaults = .standard) {
        if let saved = defaults.stringArray(forKey: Self.shortlistKey) {
            shortlistIDs = Set(saved)
        } else {
            shortlistIDs = Self.defaultShortlist
        }
    }

    func loadIfNeeded() async {
        guard !loadedCache else { return }
        loadedCache = true

        var cacheIsFresh = false
        if let cached = ModelPricingCache.load() {
            catalog = cached.catalog
            origin = .cache
            lastCheckedAt = cached.modifiedAt
            cacheIsFresh = Date().timeIntervalSince(cached.modifiedAt)
                < ModelPricingCache.refreshInterval
        }
        if !cacheIsFresh { await refresh(force: true) }
    }

    func refresh(force: Bool = true) async {
        if !force { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        refreshMessage = nil
        defer { isRefreshing = false }

        var request = URLRequest(url: Self.catalogURL)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("BarPilot", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw ModelPricingError.requestFailed
            }
            let fetched = try ModelPricingCodec.decode(data).validated()
            // Never regress to an older generated snapshot if a CDN edge or
            // deployment race briefly serves stale content.
            if fetched.generatedAt >= catalog.generatedAt {
                catalog = fetched
                try ModelPricingCache.save(data)
                origin = .network
            } else {
                refreshMessage = "Checked · published catalogue is older than this snapshot"
            }
            lastCheckedAt = Date()
        } catch {
            refreshMessage = origin == .bundled
                ? "Offline · showing the built-in snapshot"
                : "Offline · showing cached prices"
        }
    }

    func isShortlisted(_ model: ModelPricingModel) -> Bool {
        shortlistIDs.contains(model.id)
    }

    func toggleShortlist(_ model: ModelPricingModel, defaults: UserDefaults = .standard) {
        if shortlistIDs.contains(model.id) {
            shortlistIDs.remove(model.id)
        } else {
            shortlistIDs.insert(model.id)
        }
        defaults.set(shortlistIDs.sorted(), forKey: Self.shortlistKey)
    }
}

private enum ModelPricingScope: String, CaseIterable, Identifiable {
    case shortlist
    case available
    case all

    var id: String { rawValue }
    var label: String {
        switch self {
        case .shortlist: return "Favourites"
        case .available: return "Current"
        case .all: return "All"
        }
    }
}

private enum ModelPricingUnit: String, CaseIterable, Identifiable {
    case credits
    case currency

    var id: String { rawValue }
}

private enum ModelPricingMode: String, CaseIterable, Identifiable {
    case prices
    case compare

    var id: String { rawValue }
    var label: String { self == .prices ? "Prices" : "Compare" }
}

private enum ModelPricingSortField: String {
    case model
    case preference
    case input
    case output
}

struct ModelPricingView: View {
    let close: () -> Void

    @EnvironmentObject private var usageStore: UsageStore
    @StateObject private var store = ModelPricingStore()
    @State private var mode: ModelPricingMode = .prices
    @State private var unit = ModelPricingUnit(
        rawValue: UserDefaults.standard.string(forKey: "modelPricingDisplayUnitV1") ?? ""
    ) ?? .credits
    @State private var scope: ModelPricingScope = .shortlist
    @State private var provider = "all"
    @State private var query = ""
    @State private var selectedModelID = "openai:gpt-5.6-sol"
    @State private var showingAttribution = false
    @State private var freshInput = 100_000.0
    @State private var cachedInput = 0.0
    @State private var cacheWrite = 0.0
    @State private var output = 20_000.0
    @State private var showingTokenHelp = false
    @State private var showingArenaHelp = false
    @State private var sortField = ModelPricingSortField(
        rawValue: UserDefaults.standard.string(forKey: "modelPricingSortFieldV1") ?? ""
    )
    @State private var sortAscending = UserDefaults.standard.object(
        forKey: "modelPricingSortAscendingV1"
    ) as? Bool ?? true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Picker("Pricing view", selection: $mode) {
                ForEach(ModelPricingMode.allCases) { item in Text(item.label).tag(item) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            Group {
                if mode == .prices { pricesView } else { comparisonView }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            attributionFooter
        }
        .task { await store.loadIfNeeded() }
        .onChange(of: unit) { newUnit in
            UserDefaults.standard.set(newUnit.rawValue, forKey: "modelPricingDisplayUnitV1")
        }
        .onChange(of: filteredModels.map(\.id)) { ids in
            if !ids.contains(selectedModelID), let first = ids.first {
                selectedModelID = first
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("GITHUB COPILOT")
                    .font(.caption2.weight(.semibold))
                    .tracking(1.3)
                    .foregroundStyle(.tint)
                Text("Model prices").font(.title2.weight(.semibold))
                HStack(spacing: 5) {
                    Circle()
                        .fill(store.refreshMessage == nil ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(freshnessLabel).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if store.isRefreshing { ProgressView().controlSize(.small) }
            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh from the published catalogue")
            Button(action: close) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close model prices")
        }
        .padding(.horizontal, 16)
        .padding(.top, 15)
        .padding(.bottom, 12)
    }

    private var freshnessLabel: String {
        if let message = store.refreshMessage { return message }
        if store.isRefreshing { return "Checking for updates…" }
        if let checked = store.lastCheckedAt,
           Date().timeIntervalSince(checked) < 90 { return "Checked just now" }
        return "Published \(Self.freshnessFormatter.string(from: store.catalog.generatedAt))"
    }

    private var pricesView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                TextField("Search models", text: $query)
                    .textFieldStyle(.roundedBorder)
                Picker("Price unit", selection: $unit) {
                    ForEach(ModelPricingUnit.allCases) { item in
                        Text(unitLabel(item)).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 9)

            HStack(spacing: 16) {
                ForEach(ModelPricingScope.allCases) { item in
                    Button(item.label) { scope = item }
                        .buttonStyle(.plain)
                        .font(.caption.weight(scope == item ? .semibold : .regular))
                        .foregroundStyle(scope == item ? Color.primary : Color.secondary)
                        .padding(.bottom, 6)
                        .overlay(alignment: .bottom) {
                            if scope == item { Rectangle().fill(Color.accentColor).frame(height: 2) }
                        }
                        .help(scopeHelp(item))
            }
            Spacer()
            if sortField != nil {
                Button("Reset sort", action: resetSort)
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Restore the catalogue’s default order")
            }
            Text("\(filteredModels.count) shown")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .overlay(alignment: .bottom) { Divider() }

            HStack(spacing: 8) {
                providerFilter
                Spacer()
                Text("Prices: standard tier")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showingArenaHelp.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(store.catalog.communityPreferenceSource == nil
                             ? "Arena ranking unavailable"
                             : "Arena rank · lower is better")
                        Image(systemName: "questionmark.circle")
                    }
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .help("Explain LM Arena rank, score and votes")
            }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)

            if showingArenaHelp {
                arenaHelp
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack {
                Color.clear.frame(width: 24, height: 1)
                sortHeader("Model", field: .model)
                    .frame(maxWidth: .infinity, alignment: .leading)
                sortHeader("Arena", field: .preference)
                    .frame(width: 62, alignment: .trailing)
                sortHeader("Input", field: .input)
                    .frame(width: 76, alignment: .trailing)
                sortHeader("Output", field: .output)
                    .frame(width: 76, alignment: .trailing)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.bottom, 5)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredModels) { model in
                        modelRow(model)
                        if model.id != filteredModels.last?.id { Divider() }
                    }
                    if filteredModels.isEmpty {
                        Text(emptyModelsMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 80)
                    }
                }
            }
            .background(Color.primary.opacity(0.025))
            .overlay(alignment: .top) { Divider() }
            .overlay(alignment: .bottom) { Divider() }

            if let selectedModel { modelDetail(selectedModel) }
        }
    }

    private var providerFilter: some View {
        HStack(spacing: 5) {
            ForEach(providerOptions, id: \.id) { option in
                Button(option.label) { provider = option.id }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .foregroundStyle(provider == option.id ? Color.accentColor : Color.secondary)
                    .background(
                        provider == option.id ? Color.accentColor.opacity(0.12) : Color.clear,
                        in: Capsule()
                    )
                    .overlay(
                        Capsule().strokeBorder(
                            provider == option.id ? Color.clear : Color.secondary.opacity(0.18)
                        )
                    )
            }
        }
    }

    private var arenaHelp: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("What the Arena numbers mean")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showingArenaHelp = false
                    }
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close Arena explanation")
            }

            if store.catalog.communityPreferenceSource == nil {
                Text("Pricing is current, but LM Arena ranking data was unavailable when this catalogue was published. BarPilot never delays a GitHub price update just because the independent ranking source is offline.")
                    .foregroundStyle(.secondary)
            } else {
                Text("People compare two responses without seeing which models produced them and vote for the one they prefer. LM Arena turns those head-to-head results into a statistical preference score and rank.")

                HStack(alignment: .top, spacing: 16) {
                    arenaTerm("Rank", "#1 is most preferred. Lower is better.")
                    arenaTerm("Arena score", "Higher means more preferred; it is not a percentage. Its range shows uncertainty.")
                    arenaTerm("Votes", "Battles involving that model—the evidence behind its score.")
                }

                Text("BarPilot uses Arena’s latest overall text ranking with style control, which adjusts for formatting and response-style effects. A range such as #7–12 means BarPilot matched multiple reasoning modes at those ranks; it is not an uncertainty range. — means no exact match.")
                    .foregroundStyle(.secondary)

                Text("This reflects community preference, not intelligence, factual accuracy, coding ability, suitability for your task, or value for money.")
                    .fontWeight(.semibold)
            }
        }
        .font(.caption2)
        .padding(10)
        .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Color.accentColor.opacity(0.18))
        )
    }

    private func arenaTerm(_ term: String, _ definition: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(term).fontWeight(.semibold)
            Text(definition).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func modelRow(_ model: ModelPricingModel) -> some View {
        let tier = model.standardTier
        return HStack(spacing: 0) {
            Button {
                store.toggleShortlist(model)
            } label: {
                Image(systemName: store.isShortlisted(model) ? "star.fill" : "star")
                    .foregroundStyle(store.isShortlisted(model) ? Color.yellow : Color.secondary)
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                store.isShortlisted(model)
                    ? "Remove \(model.name) from favourites"
                    : "Add \(model.name) to favourites"
            )
            .help(store.isShortlisted(model) ? "Remove from favourites" : "Add to favourites")

            Button {
                selectedModelID = model.id
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.name).font(.callout.weight(.semibold)).lineLimit(1)
                        HStack(spacing: 4) {
                            Text("\(model.providerLabel) · \(model.usageRoleLabel)")
                            if !model.sourceAnnotations.isEmpty {
                                Text("· Pricing note").foregroundStyle(.orange)
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    preferenceStack(model).frame(width: 62, alignment: .trailing)
                    rateStack(tier.prices.input).frame(width: 76, alignment: .trailing)
                    rateStack(tier.prices.output).frame(width: 76, alignment: .trailing)
                }
                .padding(.leading, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(model.id == selectedModelID ? Color.accentColor.opacity(0.12) : .clear)
    }

    private func sortHeader(_ label: String, field: ModelPricingSortField) -> some View {
        Button {
            if sortField == field {
                sortAscending.toggle()
            } else {
                sortField = field
                sortAscending = true
            }
            persistSort()
        } label: {
            HStack(spacing: 3) {
                Text(label)
                Image(systemName: sortIndicator(for: field))
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(sortField == field ? Color.accentColor : Color.secondary.opacity(0.55))
            }
        }
        .buttonStyle(.plain)
        .help(sortHelp(label, field: field))
        .accessibilityLabel(sortHelp(label, field: field))
    }

    private func persistSort() {
        let defaults = UserDefaults.standard
        if let sortField {
            defaults.set(sortField.rawValue, forKey: "modelPricingSortFieldV1")
            defaults.set(sortAscending, forKey: "modelPricingSortAscendingV1")
        } else {
            defaults.removeObject(forKey: "modelPricingSortFieldV1")
            defaults.removeObject(forKey: "modelPricingSortAscendingV1")
        }
    }

    private func resetSort() {
        sortField = nil
        sortAscending = true
        persistSort()
    }

    private func sortIndicator(for field: ModelPricingSortField) -> String {
        guard sortField == field else { return "arrow.up.arrow.down" }
        return sortAscending ? "chevron.up" : "chevron.down"
    }

    private func sortHelp(_ label: String, field: ModelPricingSortField) -> String {
        guard sortField == field else { return "Sort by \(label.lowercased())" }
        return "Sorted by \(label.lowercased()), \(sortAscending ? "ascending" : "descending"). Click to reverse."
    }

    private func rateStack(_ usd: Double) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(rateText(usd, unit: unit)).monospacedDigit()
            Text(rateText(usd, unit: alternateUnit))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.callout)
    }

    private func preferenceStack(_ model: ModelPricingModel) -> some View {
        Group {
            if let preference = model.communityPreference {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(preference.rankLabel)
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                    if preference.variants.count > 1 {
                        Text("\(preference.variants.count) modes")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(preference.variants[0].label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .help(preferenceHelp(model))
                .accessibilityLabel(preferenceHelp(model))
            } else {
                Text("—")
                    .foregroundStyle(.tertiary)
                    .help(preferenceHelp(model))
                    .accessibilityLabel(preferenceHelp(model))
            }
        }
    }

    private func modelDetail(_ model: ModelPricingModel) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name).font(.callout.weight(.semibold))
                    Text("\(model.providerLabel) · \(model.usageRoleLabel) · \(model.releaseStatusLabel)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Button(store.isShortlisted(model) ? "Remove from favourites" : "Add to favourites") {
                        store.toggleShortlist(model)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                }
            }
            ForEach(model.tiers) { tier in
                VStack(alignment: .leading, spacing: 5) {
                    Text([tier.label, tier.rangeLabel].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                    HStack(spacing: 12) {
                        detailRate("Input / 1M", tier.prices.input)
                        detailRate("Cached / 1M", tier.prices.cachedInput)
                        detailRate(
                            tier.prices.cacheWrite == nil
                                ? "Cache write / 1M*" : "Cache write / 1M",
                            tier.prices.cacheWrite ?? tier.prices.input
                        )
                        detailRate("Output / 1M", tier.prices.output)
                    }
                }
                if tier.id != model.tiers.last?.id { Divider() }
            }
            if model.tiers.contains(where: { $0.prices.cacheWrite == nil }) {
                Text("* GitHub publishes no separate cache-write price; comparisons conservatively use the fresh-input rate.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            communityPreferenceDetail(model)
            if !model.sourceAnnotations.isEmpty {
                HStack(spacing: 4) {
                    Text("GitHub marks this model as having promotional or special pricing.")
                    Link("View GitHub’s pricing note", destination: Self.pricingTermsURL)
                }
                .font(.caption2)
                .foregroundStyle(.orange)
            } else if let notes = model.notes {
                Text(notes).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.045))
    }

    @ViewBuilder
    private func communityPreferenceDetail(_ model: ModelPricingModel) -> some View {
        if let preference = model.communityPreference {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Community preference").font(.caption.weight(.semibold))
                    Spacer()
                    Text("LM Arena · \(store.catalog.communityPreferenceSource?.snapshotDate ?? "unavailable")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 18) {
                    ForEach(preference.variants) { variant in
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(variant.label)  #\(variant.rank)")
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                            Text(
                                "\(ModelPricingFormat.number(variant.rating, maximum: 0)) score · "
                                + "\(ModelPricingFormat.compactCount(variant.voteCount)) battles"
                            )
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            Text(
                                "Confidence \(ModelPricingFormat.number(variant.ratingLower, maximum: 1))–"
                                + "\(ModelPricingFormat.number(variant.ratingUpper, maximum: 1))"
                            )
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        .help("LM Arena source model: \(variant.arenaModel)")
                    }
                }
                Text("Blind head-to-head votes · style-controlled overall leaderboard · lower rank is better")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 1)
        } else if store.catalog.communityPreferenceSource == nil {
            Text("Community preference · Temporarily unavailable in this catalogue")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            Text("Community preference · No exact match in the current LM Arena overall leaderboard")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func detailRate(_ label: String, _ usd: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Text(usd.map { rateText($0, unit: unit) } ?? "—")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var comparisonView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text("Estimate a workload").font(.headline)
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                showingTokenHelp.toggle()
                            }
                        } label: {
                            Label("What do these mean?", systemImage: "questionmark.circle")
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                    Text("Published token rates, before product overhead.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Estimate unit", selection: $unit) {
                    ForEach(ModelPricingUnit.allCases) { item in
                        Text(unitLabel(item)).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            if showingTokenHelp {
                tokenHelp
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                workloadSlider("Fresh input", value: $freshInput, maximum: 400_000, step: 10_000)
                workloadSlider("Cached input", value: $cachedInput, maximum: 400_000, step: 10_000)
                workloadSlider("Cache write", value: $cacheWrite, maximum: 200_000, step: 10_000)
                workloadSlider("Output", value: $output, maximum: 100_000, step: 5_000)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            HStack {
                Text("Model").frame(maxWidth: .infinity, alignment: .leading)
                Text("Estimated cost").frame(width: 150, alignment: .trailing)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.bottom, 5)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(comparisons.enumerated()), id: \.element.model.id) { index, estimate in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(estimate.model.name).font(.callout.weight(.semibold))
                                Text(
                                    "\(estimate.model.providerLabel) · \(estimate.tier.label)"
                                    + (estimate.model.communityPreference.map { " · Arena \($0.rankLabel)" } ?? "")
                                    + (index == 0 ? " · Lowest estimate" : "")
                                )
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(costText(estimate.usd, unit: unit))
                                    .font(.callout.weight(.semibold)).monospacedDigit()
                                Text(costText(estimate.usd, unit: alternateUnit))
                                .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                            }
                            .frame(width: 150, alignment: .trailing)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(index == 0 ? Color.accentColor.opacity(0.10) : .clear)
                        if index != comparisons.count - 1 { Divider() }
                    }
                }
            }
            .overlay(alignment: .top) { Divider() }
        }
    }

    private var tokenHelp: some View {
        VStack(alignment: .leading, spacing: 6) {
            tokenDefinition(
                "Fresh input",
                "New prompt, conversation and file-context tokens sent to the model."
            )
            tokenDefinition(
                "Cached input",
                "Previously cached context reused in this request, usually at a lower price."
            )
            tokenDefinition(
                "Cache write",
                "New context stored in the provider’s prompt cache. If no separate rate is published, BarPilot uses the fresh-input rate—not zero."
            )
            tokenDefinition(
                "Output",
                "Tokens generated by the model in its response."
            )
        }
        .font(.caption2)
        .padding(10)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
    }

    private func tokenDefinition(_ term: String, _ definition: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(term).fontWeight(.semibold).frame(width: 76, alignment: .leading)
            Text(definition).foregroundStyle(.secondary)
        }
    }

    private func workloadSlider(
        _ label: String, value: Binding<Double>, maximum: Double, step: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text(ModelPricingFormat.tokens(value.wrappedValue)).monospacedDigit()
            }
            .font(.caption)
            Slider(value: value, in: 0...maximum, step: step)
        }
    }

    private var attributionFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showingAttribution {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Data attribution and method").font(.caption.weight(.semibold))
                    Text("GitHub publishes this pricing table under Creative Commons Attribution 4.0. That licence lets BarPilot copy and adapt the table as long as GitHub is credited and BarPilot’s changes are disclosed.")
                    HStack(spacing: 4) {
                        Link("Raw GitHub pricing table", destination: URL(string: store.catalog.source.url)!)
                        Text("·")
                        Link("Read the licence", destination: Self.licenseURL)
                    }
                    Text("Converted to JSON, grouped into context tiers and relabelled for clarity.")
                    if let preferenceSource = store.catalog.communityPreferenceSource,
                       let preferenceURL = URL(string: preferenceSource.url) {
                        Text("LM Arena community-preference ranks come from its CC BY 4.0 leaderboard dataset. BarPilot uses the latest overall, text-style-controlled split, preserves each published score and vote count, and groups only explicitly matched reasoning modes.")
                        HStack(spacing: 4) {
                            Link("LM Arena leaderboard dataset", destination: preferenceURL)
                            Text("·")
                            Link("Read the licence", destination: Self.licenseURL)
                        }
                        Text("An em dash means no exact current match. Community preference is based on blind votes; it is not an intelligence or benchmark score.")
                        Text("Rating is LM Arena’s statistical preference rating; the published interval expresses uncertainty, while vote count shows the available evidence.")
                    } else {
                        Text("LM Arena community-preference data was unavailable for this publication. GitHub prices remain authoritative and current.")
                    }
                    Text("Modified by BarPilot. BarPilot is independent and is not affiliated with or endorsed by GitHub or LM Arena.")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            }
            HStack(spacing: 5) {
                Text("Data:")
                Link("GitHub prices", destination: URL(string: store.catalog.source.url)!)
                if let preferenceSource = store.catalog.communityPreferenceSource,
                   let preferenceURL = URL(string: preferenceSource.url) {
                    Text("·")
                    Link("LM Arena ranking", destination: preferenceURL)
                } else {
                    Text("· Arena unavailable")
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showingAttribution.toggle() }
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .help("Show data attribution and community-preference method")
                Spacer()
                Text("1 AI credit = $0.01 USD")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .overlay(alignment: .top) { Divider() }
    }

    private var providerOptions: [(id: String, label: String)] {
        let wanted = ["openai", "anthropic", "google"]
        var result = [("all", "All")]
        result += wanted.compactMap { id in
            guard store.catalog.models.contains(where: { $0.provider == id }) else { return nil }
            return (id, store.catalog.models.first { $0.provider == id }!.providerLabel)
        }
        if store.catalog.models.contains(where: { !wanted.contains($0.provider) }) {
            result.append(("other", "Other"))
        }
        return result
    }

    private func scopeHelp(_ value: ModelPricingScope) -> String {
        switch value {
        case .shortlist: return "Star models in Current or All to add them to Favourites"
        case .available: return "Models marked generally available by GitHub"
        case .all: return "Every model in the published catalogue"
        }
    }

    private func preferenceHelp(_ model: ModelPricingModel) -> String {
        guard let preference = model.communityPreference else {
            if store.catalog.communityPreferenceSource == nil {
                return "LM Arena ranking was unavailable when this catalogue was published"
            }
            return "No exact match in the current LM Arena overall leaderboard"
        }
        let modes = preference.variants.map { "\($0.label) #\($0.rank)" }.joined(separator: ", ")
        return "LM Arena community preference: \(modes). Lower rank is better."
    }

    private var emptyModelsMessage: String {
        if scope == .shortlist && store.shortlistIDs.isEmpty {
            return "No favourites yet. Open Current or All and click a star."
        }
        return "No models match this view."
    }

    private var alternateUnit: ModelPricingUnit {
        unit == .credits ? .currency : .credits
    }

    private func unitLabel(_ value: ModelPricingUnit) -> String {
        value == .credits ? "Credits" : usageStore.effectiveCurrency.code
    }

    private func rateText(_ usd: Double, unit: ModelPricingUnit) -> String {
        ModelPricingFormat.rate(
            usd,
            unit: unit,
            currency: usageStore.effectiveCurrency,
            usdToAUD: usageStore.usdToAUD
        )
    }

    private func costText(_ usd: Double, unit: ModelPricingUnit) -> String {
        ModelPricingFormat.cost(
            usd,
            unit: unit,
            currency: usageStore.effectiveCurrency,
            usdToAUD: usageStore.usdToAUD
        )
    }

    private var filteredModels: [ModelPricingModel] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var models = store.catalog.models.filter { model in
            let inScope: Bool
            switch scope {
            case .shortlist: inScope = store.isShortlisted(model)
            case .available: inScope = model.releaseStatus == "generally-available"
            case .all: inScope = true
            }
            let providerMatches = provider == "all"
                || model.provider == provider
                || (provider == "other" && !["openai", "anthropic", "google"].contains(model.provider))
            let arenaTerms = model.communityPreference?.variants
                .map { "\($0.arenaModel) \($0.label)" }
                .joined(separator: " ") ?? ""
            let searchMatches = needle.isEmpty
                || "\(model.name) \(model.providerLabel) \(model.category) \(model.usageRoleLabel) \(arenaTerms)"
                    .lowercased().contains(needle)
            return inScope && providerMatches && searchMatches
        }
        guard let sortField else { return models }
        models.sort { left, right in
            switch sortField {
            case .model:
                let comparison = left.name.localizedStandardCompare(right.name)
                return sortAscending
                    ? comparison == .orderedAscending
                    : comparison == .orderedDescending
            case .preference:
                return orderedByPreference(left, right)
            case .input:
                return orderedByPrice(
                    left.standardTier.prices.input,
                    right.standardTier.prices.input,
                    left: left,
                    right: right
                )
            case .output:
                return orderedByPrice(
                    left.standardTier.prices.output,
                    right.standardTier.prices.output,
                    left: left,
                    right: right
                )
            }
        }
        return models
    }

    private func orderedByPrice(
        _ left: Double,
        _ right: Double,
        left leftModel: ModelPricingModel,
        right rightModel: ModelPricingModel
    ) -> Bool {
        if left == right {
            return leftModel.name.localizedStandardCompare(rightModel.name) == .orderedAscending
        }
        return sortAscending ? left < right : left > right
    }

    private func orderedByPreference(
        _ left: ModelPricingModel,
        _ right: ModelPricingModel
    ) -> Bool {
        switch (left.communityPreference?.bestRank, right.communityPreference?.bestRank) {
        case let (leftRank?, rightRank?):
            if leftRank == rightRank {
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
            return sortAscending ? leftRank < rightRank : leftRank > rightRank
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }

    private var selectedModel: ModelPricingModel? {
        filteredModels.first { $0.id == selectedModelID }
    }

    private struct Estimate {
        let model: ModelPricingModel
        let tier: ModelPricingTier
        let usd: Double
    }

    private var comparisons: [Estimate] {
        filteredComparisonModels.map { model in
            let estimate = model.estimate(
                freshInput: freshInput,
                cachedInput: cachedInput,
                cacheWrite: cacheWrite,
                output: output
            )
            return Estimate(model: model, tier: estimate.tier, usd: estimate.usd)
        }
        .sorted { $0.usd < $1.usd }
    }

    private var filteredComparisonModels: [ModelPricingModel] {
        switch scope {
        case .shortlist: return store.catalog.models.filter(store.isShortlisted)
        case .available: return store.catalog.models.filter { $0.releaseStatus == "generally-available" }
        case .all: return store.catalog.models
        }
    }

    private static let pricingTermsURL = URL(
        string: "https://docs.github.com/en/copilot/reference/copilot-billing/models-and-pricing"
    )!
    private static let licenseURL = URL(string: "https://creativecommons.org/licenses/by/4.0/")!
    private static let freshnessFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private enum ModelPricingFormat {
    static func rate(
        _ usd: Double,
        unit: ModelPricingUnit,
        currency: Currency,
        usdToAUD: Double?
    ) -> String {
        if unit == .credits { return "\(number(usd * 100, maximum: 2)) cr" }
        return currency.symbol
            + number(convert(usd, currency: currency, usdToAUD: usdToAUD), maximum: 3)
    }

    static func cost(
        _ usd: Double,
        unit: ModelPricingUnit,
        currency: Currency,
        usdToAUD: Double?
    ) -> String {
        if unit == .credits { return "\(number(usd * 100, maximum: 2)) credits" }
        return currency.symbol
            + number(convert(usd, currency: currency, usdToAUD: usdToAUD), maximum: 3)
    }

    static func tokens(_ value: Double) -> String {
        value >= 1_000 ? "\(number(value / 1_000, maximum: 0))K" : number(value, maximum: 0)
    }

    static func number(_ value: Double, maximum: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = maximum
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func compactCount(_ value: Int) -> String {
        value >= 1_000
            ? "\(number(Double(value) / 1_000, maximum: 1))K"
            : number(Double(value), maximum: 0)
    }

    private static func convert(
        _ usd: Double,
        currency: Currency,
        usdToAUD: Double?
    ) -> Double {
        currency == .aud ? usd * (usdToAUD ?? 1) : usd
    }
}

extension ModelPricingCatalog {
    /// A compact first-launch/offline snapshot of the agreed shortlist. Network
    /// and cached catalogues replace it as soon as either is available.
    static let bundledFallback = ModelPricingCatalog(
        schemaVersion: 2,
        generatedAt: ISO8601DateFormatter().date(from: "2026-09-05T01:36:08Z")!,
        pricingUnit: "USD per 1 million tokens",
        source: ModelPricingSource(
            repository: "github/docs",
            path: "data/tables/copilot/models-and-pricing.yml",
            revision: "be4d995f7eb07f2bbcf1a9f6b664ff91f7f31a11",
            sha256: "b7fb21001f939dd8771be19257d3676dc053b5568f96cffe1cbe95465bcdca9c",
            url: "https://github.com/github/docs/blob/be4d995f7eb07f2bbcf1a9f6b664ff91f7f31a11/data/tables/copilot/models-and-pricing.yml"
        ),
        communityPreferenceSource: ModelCommunityPreferenceSource(
            publisher: "LM Arena",
            dataset: "lmarena-ai/leaderboard-dataset",
            configuration: "text_style_control",
            split: "latest",
            category: "overall",
            revision: "01150872069639f5a5559cc0e719ac766f268fcb",
            snapshotDate: "2026-09-01",
            license: "CC BY 4.0",
            licenseURL: "https://creativecommons.org/licenses/by/4.0/",
            url: "https://huggingface.co/datasets/lmarena-ai/leaderboard-dataset"
        ),
        modelCount: 7,
        models: [
            fallbackModel(
                "openai:gpt-5.6-sol", "GPT-5.6 Sol", "openai", "Powerful",
                4, 0.4, 5, 20,
                threshold: 272_000, long: (8, 0.8, 10, 30),
                preference: arena([
                    arenaVariant(
                        "gpt-5.6-sol-xhigh", "xHigh", 16,
                        1482.8679362258424, 1477.7476788504516, 1487.9881936012332, 23153
                    )
                ])
            ),
            fallbackModel(
                "openai:gpt-5.6-terra", "GPT-5.6 Terra", "openai", "Versatile",
                2, 0.2, 2.5, 12,
                threshold: 272_000, long: (4, 0.4, 5, 18),
                preference: arena([
                    arenaVariant(
                        "gpt-5.6-terra-xhigh", "xHigh", 41,
                        1466.233100270795, 1461.1708453662002, 1471.2953551753894, 23942
                    )
                ])
            ),
            fallbackModel(
                "anthropic:claude-opus-5", "Claude Opus 5", "anthropic", "Powerful",
                5, 0.5, 6.25, 25,
                preference: arena([
                    arenaVariant(
                        "claude-opus-5-high", "High", 7,
                        1492.0420828978251, 1487.475097858224, 1496.6090679374265, 34617
                    ),
                    arenaVariant(
                        "claude-opus-5-max", "Max", 12,
                        1487.80035070144, 1481.9827121388685, 1493.6179892640116, 16839
                    )
                ])
            ),
            fallbackModel(
                "anthropic:claude-sonnet-5", "Claude Sonnet 5", "anthropic", "Versatile",
                2, 0.2, 2.5, 10,
                preference: arena([
                    arenaVariant(
                        "claude-sonnet-5-high", "High", 46,
                        1462.1604360390372, 1457.4154844371524, 1466.9053876409218, 31096
                    )
                ])
            ),
            fallbackModel("google:gemini-3.8-flash", "Gemini 3.8 Flash", "google", "Versatile", 0.75, 0.075, nil, 3.75, annotations: ["gemini-flash-promo"]),
            fallbackModel(
                "xai:grok-4.6", "Grok 4.6", "xai", "Versatile", 2, 0.5, nil, 6,
                threshold: 200_000, long: (4, 1, nil, 12),
                preference: arena([
                    arenaVariant(
                        "grok-4.6-high", "High", 47,
                        1461.1152937622203, 1450.9710122364897, 1471.2595752879508, 3453
                    )
                ])
            ),
            fallbackModel(
                "moonshot_ai:kimi-k3", "Kimi K3", "moonshot_ai", "Powerful",
                3, 0.3, nil, 15,
                preference: arena([
                    arenaVariant(
                        "kimi-k3-max", "Max", 10,
                        1489.0169077301305, 1483.5465207090458, 1494.4872947512151, 17895
                    )
                ])
            ),
        ]
    )

    private static func fallbackModel(
        _ id: String,
        _ name: String,
        _ provider: String,
        _ category: String,
        _ input: Double,
        _ cached: Double,
        _ write: Double?,
        _ output: Double,
        threshold: Int? = nil,
        long: (Double, Double, Double?, Double)? = nil,
        annotations: [String] = [],
        preference: ModelCommunityPreference? = nil
    ) -> ModelPricingModel {
        var tiers = [ModelPricingTier(
            id: "standard",
            label: "Standard context",
            inputTokenRange: threshold.map {
                ModelPricingTokenRange(operatorName: "less-than-or-equal", tokens: $0)
            },
            prices: ModelTokenPrices(
                input: input, cachedInput: cached, cacheWrite: write, output: output
            )
        )]
        if let threshold, let long {
            tiers.append(ModelPricingTier(
                id: "long-context",
                label: "Long context",
                inputTokenRange: ModelPricingTokenRange(
                    operatorName: "greater-than", tokens: threshold
                ),
                prices: ModelTokenPrices(
                    input: long.0, cachedInput: long.1, cacheWrite: long.2, output: long.3
                )
            ))
        }
        return ModelPricingModel(
            id: id,
            name: name,
            provider: provider,
            releaseStatus: "generally-available",
            category: category,
            sourceAnnotations: annotations,
            tiers: tiers,
            notes: nil,
            communityPreference: preference
        )
    }

    private static func arena(
        _ variants: [ModelCommunityPreferenceVariant]
    ) -> ModelCommunityPreference {
        ModelCommunityPreference(
            bestRank: variants.map(\.rank).min()!,
            worstRank: variants.map(\.rank).max()!,
            variants: variants.sorted { $0.rank < $1.rank }
        )
    }

    private static func arenaVariant(
        _ arenaModel: String,
        _ label: String,
        _ rank: Int,
        _ rating: Double,
        _ ratingLower: Double,
        _ ratingUpper: Double,
        _ voteCount: Int
    ) -> ModelCommunityPreferenceVariant {
        ModelCommunityPreferenceVariant(
            arenaModel: arenaModel,
            label: label,
            rank: rank,
            rating: rating,
            ratingLower: ratingLower,
            ratingUpper: ratingUpper,
            voteCount: voteCount
        )
    }
}

enum ModelPricingVerification {
    @MainActor
    static func run() {
        do {
            let catalog = try ModelPricingCatalog.bundledFallback.validated()
            let defaultShortlistCount = ModelPricingStore.defaultShortlist.count
            precondition(catalog.modelCount == defaultShortlistCount)
            precondition(Set(catalog.models.map(\.id)) == ModelPricingStore.defaultShortlist)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let decoded = try ModelPricingCodec.decode(encoder.encode(catalog)).validated()
            precondition(decoded == catalog)
            let sol = catalog.models.first { $0.id == "openai:gpt-5.6-sol" }!
            precondition(catalog.schemaVersion == 2)
            precondition(catalog.communityPreferenceSource?.publisher == "LM Arena")
            precondition(sol.communityPreference?.rankLabel == "#16")
            precondition(sol.tier(forInputTokens: 272_000).id == "standard")
            precondition(sol.tier(forInputTokens: 272_001).id == "long-context")
            let opus = catalog.models.first { $0.id == "anthropic:claude-opus-5" }!
            precondition(opus.communityPreference?.rankLabel == "#7–12")
            let gemini = catalog.models.first { $0.id == "google:gemini-3.8-flash" }!
            precondition(gemini.communityPreference == nil)
            let estimate = sol.estimate(
                freshInput: 100_000, cachedInput: 0, cacheWrite: 0, output: 20_000
            )
            precondition(abs(estimate.usd - 0.8) < 0.000_001)
            let conservativeCacheWrite = gemini.estimate(
                freshInput: 0, cachedInput: 0, cacheWrite: 100_000, output: 0
            )
            precondition(abs(conservativeCacheWrite.usd - 0.075) < 0.000_001)
            let thresholdIncludesCacheWrites = sol.estimate(
                freshInput: 200_000, cachedInput: 0, cacheWrite: 72_001, output: 0
            )
            precondition(thresholdIncludesCacheWrites.tier.id == "long-context")
            print("model-pricing verification passed")
        } catch {
            fatalError(error.localizedDescription)
        }
    }
}
