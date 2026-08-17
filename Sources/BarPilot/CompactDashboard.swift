import SwiftUI
import Charts

struct CompactDashboard: View {
    @EnvironmentObject var store: UsageStore
    let connectGitHub: () -> Void
    let openSettings: () -> Void
    let showLegacy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !store.serverUsageEnabled {
                        connectionCard
                    }
                    valueCards
                    CompactBudgetBar()
                    dailyChartSection
                    dailySection
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 600)
        .frame(minHeight: 480, maxHeight: .infinity)
    }

    private var connectionCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(store.serverUsageError == nil
                     ? "Connect GitHub for accurate credit usage"
                     : "Reconnect GitHub")
                    .font(.subheadline.weight(.semibold))
                Text(connectionMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                if store.isConnectingServerUsage {
                    store.cancelServerUsageConnection()
                } else {
                    connectGitHub()
                }
            } label: {
                if store.isConnectingServerUsage {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Cancel")
                    }
                } else {
                    Text("Connect GitHub")
                }
            }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
        }
        .padding(12)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }

    private var connectionMessage: String {
        if let error = store.serverUsageError { return error }
        return "BarPilot is temporarily showing incomplete local telemetry. Connect to load GitHub’s account-wide credit total and begin daily tracking."
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .foregroundStyle(.tint)
                Text("Copilot Credits")
                    .font(.headline)
                Spacer()
                if store.isLoading { ProgressView().controlSize(.small) }
                Button {
                    showLegacy()
                } label: {
                    Label("Legacy telemetry", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Open the previous telemetry-based interface.")
                Button {
                    Task { await store.reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh now")
                Button {
                    openSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape.fill")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Budget, currency, GitHub connection, sync and updates")
            }

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("This billing cycle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(Fmt.credits(store.compactTotalCredits)) credits")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
                Spacer()
                if let sample = store.currentServerUsageSample {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Resets")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(Self.resetFormatter.string(from: sample.resetAt))
                            .font(.caption.weight(.medium))
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    /// Clicking a card selects the currency shown in the menu bar (and across
    /// the window). The cards are the most legible place to see both figures
    /// side by side, so they are also the most natural place to pick one.
    private var valueCards: some View {
        HStack(spacing: 10) {
            valueCard(
                currency: .usd, title: "US dollars",
                value: store.usdCostString(credits: store.compactTotalCredits),
                detail: "100 credits = US$1")
            valueCard(
                currency: .aud, title: "Australian dollars",
                value: store.audCostString(credits: store.compactTotalCredits),
                detail: store.usdToAUD.map { String(format: "Live rate · %.4f", $0) } ?? "Exchange rate unavailable")
        }
    }

    private func valueCard(
        currency: Currency, title: String, value: String, detail: String
    ) -> some View {
        // Compare against effectiveCurrency, not displayCurrency: AUD falls back
        // to USD until a rate loads, and the badge must show what the menu bar
        // is actually displaying rather than what was requested.
        let isMenuBar = store.effectiveCurrency == currency
        let unavailable = currency == .aud && store.usdToAUD == nil
        return Button {
            store.displayCurrency = currency
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Text(title).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if isMenuBar {
                        Label("Menu bar", systemImage: "menubar.rectangle")
                            .font(.caption2.weight(.medium))
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.tint)
                    }
                }
                Text(value)
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                Text(detail).font(.caption2).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                Color.primary.opacity(isMenuBar ? 0.075 : 0.045),
                in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isMenuBar ? Color.accentColor : .clear, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(unavailable)
        .help(unavailable
              ? "Available once an exchange rate loads."
              : (isMenuBar ? "Already shown in the menu bar"
                           : "Show \(currency.code) in the menu bar"))
        .accessibilityAddTraits(isMenuBar ? [.isSelected] : [])
    }

    private var dailyChartSection: some View {
        let timeline = store.creditTimeline
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Daily cost")
                        .font(.subheadline.weight(.semibold))
                    Text(dailyChartSubtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let first = timeline.firstAtMs {
                    Text("Tracking since \(Self.shortDateFormatter.string(from: Date(timeIntervalSince1970: Double(first) / 1000)))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            DailyCostBarChart(
                points: timeline.daily,
                cost: { store.displayCost(credits: $0) },
                symbol: store.effectiveCurrency.symbol
            )
            .frame(height: 150)
        }
    }

    private var dailyChartSubtitle: String {
        let timeline = store.creditTimeline
        guard timeline.firstAtMs != nil else {
            return "Waiting for saved GitHub counter samples."
        }
        // Gated on the *displayed* amount, not the raw residual: cost is 100x
        // coarser than credits, and the residual is a difference of accumulated
        // Doubles, so `> 0` was satisfied by values that render as "$0.00".
        if store.displayCost(credits: timeline.unallocatedCredits) >= 0.005 {
            return "\(store.costString(credits: timeline.unallocatedCredits)) cannot be assigned to a day."
        }
        return "Observed increases between saved GitHub counter samples."
    }

    private var dailySection: some View {
        let timeline = store.creditTimeline
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Observed daily spend")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("UTC")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }

            HStack {
                Text("Day").frame(maxWidth: .infinity, alignment: .leading)
                Text("Credits").frame(width: 90, alignment: .trailing)
                Text("USD").frame(width: 75, alignment: .trailing)
                Text("AUD").frame(width: 80, alignment: .trailing)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            Divider()

            if timeline.daily.isEmpty {
                Text("No complete observed increases yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 46)
            } else {
                VStack(spacing: 0) {
                    ForEach(timeline.daily) { row in
                        HStack {
                            Text(row.day)
                                .monospacedDigit()
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(Fmt.credits(row.credits))
                                .monospacedDigit()
                                .frame(width: 90, alignment: .trailing)
                            Text(store.usdCostString(credits: row.credits))
                                .monospacedDigit()
                                .frame(width: 75, alignment: .trailing)
                            Text(store.audCostString(credits: row.credits))
                                .monospacedDigit()
                                .frame(width: 80, alignment: .trailing)
                        }
                        .font(.callout)
                        .padding(.vertical, 5)
                    }
                }
            }

            if timeline.openingCredits > 0 {
                Divider()
                HStack {
                    Text("Before tracking")
                    Spacer()
                    Text("\(Fmt.credits(timeline.openingCredits)) credits")
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("The opening cumulative counter is included in the headline but cannot be assigned to earlier hours or days.")
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 7, height: 7)
            Text(store.serverUsageStatusLabel)
                .font(.caption2)
                .foregroundStyle(store.serverUsageError == nil ? Color.secondary : Color.red)
            if let updated = store.lastUpdated {
                Text("· updated \(Fmt.dateTime(Int64(updated.timeIntervalSince1970 * 1000)))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if store.syncEnabled {
                let hasError = store.syncError != nil
                Text(hasError
                     ? "· sync error"
                     : "· sync \(store.counterSyncMachineCount) Mac\(store.counterSyncMachineCount == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(hasError ? Color.red : Color.secondary)
            }
            Spacer()
            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")\(Updater.isDevBuild ? "-dev" : "")")
                .font(.caption2)
                .foregroundStyle(Updater.isDevBuild ? Color.orange : Color.secondary)
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private var statusColor: Color {
        if store.serverUsageError != nil { return .red }
        guard store.serverUsageEnabled else { return .orange }
        if store.serverUsageSample == nil || store.serverUsageIsStale { return .orange }
        return .green
    }

    private static let resetFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM, h:mm a"
        return formatter
    }()

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM, h a"
        return formatter
    }()
}

private struct CompactBudgetBar: View {
    @EnvironmentObject var store: UsageStore
    private let budgetMarkerFraction = 0.70

    var body: some View {
        let spent = store.compactTotalCredits
        let budget = store.monthlyBudget * 100
        let projection = store.compactSpendProjection
        let hasBudget = budget > 0
        let maximum = hasBudget
            ? budget / budgetMarkerFraction
            : max(spent, projection?.projectedCredits ?? 0, 1)
        let over = hasBudget && spent > budget

        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("This month’s spend")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(hasBudget
                     ? "\(store.budgetMoneyString(usd: store.monthlyBudget)) budget"
                     : "No budget set")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.14))
                    if let projection {
                        Capsule()
                            .fill((projection.overBudget ? Color.red : Color.green).opacity(0.18))
                            .frame(width: width * min(projection.projectedCredits / maximum, 1))
                    }
                    Capsule()
                        .fill(over ? Color.red : Color.green)
                        .frame(width: width * min(spent / maximum, 1))
                    if hasBudget {
                        Rectangle()
                            .fill(Color.orange)
                            .frame(width: 2, height: 18)
                            .offset(x: width * budgetMarkerFraction - 1)
                    }
                }
            }
            .frame(height: 18)

            HStack {
                Text("\(store.usdCostString(credits: spent)) USD")
                    .fontWeight(.medium)
                    .foregroundStyle(over ? Color.red : Color.primary)
                Text("· \(store.audCostString(credits: spent)) AUD")
                    .foregroundStyle(.secondary)
                Spacer()
                if let projection {
                    // The bar clamps at the top of the overflow region (~143% of
                    // budget), so past that every overrun looks identical. The
                    // percentage keeps the saturated case quantified.
                    Text(hasBudget
                         ? "Projected \(store.displayCostString(credits: projection.projectedCredits)) · \(Int(projection.pctOfBudget.rounded()))% of budget"
                         : "Projected \(store.displayCostString(credits: projection.projectedCredits))")
                        .foregroundStyle(projection.overBudget ? Color.red : Color.secondary)
                }
            }
            .font(.caption)
            .monospacedDigit()
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// A "nice" y-axis for money: explicit ticks plus the precision needed to label
/// them truthfully.
///
/// Swift Charts' `.automatic` tick values are not constrained to whole units —
/// it happily picks a 2.5 step — so any precision guessed from the *data* can
/// contradict the *ticks*. At whole-dollar precision a 2.5 step labels its
/// gridlines "$2" and "$8" (printf rounds half-to-even), which are evenly
/// spaced lines carrying unevenly spaced, wrong numbers. Owning the ticks is
/// what makes the label and the gridline the same fact.
struct MoneyAxisScale {
    let ticks: [Double]
    let decimals: Int
    let upperBound: Double

    /// Money has no sub-cent granularity, so a step never goes below a cent —
    /// otherwise a very light cycle yields ticks 0.005 apart and two adjacent
    /// gridlines both label as "$0.01".
    private static let minimumStep = 0.01

    static func make(max: Double, desiredCount: Int = 4) -> MoneyAxisScale {
        guard max.isFinite, max > 0 else {
            return MoneyAxisScale(ticks: [0], decimals: 0, upperBound: 1)
        }
        let rough = max / Double(desiredCount)
        let magnitude = pow(10, floor(log10(rough)))
        let normalised = rough / magnitude
        let niceNormalised: Double
        switch normalised {
        case ...1: niceNormalised = 1
        case ...2: niceNormalised = 2
        case ...2.5: niceNormalised = 2.5
        case ...5: niceNormalised = 5
        default: niceNormalised = 10
        }
        let step = Swift.max(niceNormalised * magnitude, minimumStep)
        let count = Swift.max(1, Int((max / step).rounded(.up)))
        let ticks = (0...count).map { Double($0) * step }
        // Whole steps read as "$50"; a fractional step is money, so it takes
        // cents rather than one decimal ("$2.50", never "$2.5").
        let decimals = step == step.rounded() ? 0 : 2
        return MoneyAxisScale(
            ticks: ticks, decimals: decimals, upperBound: Double(count) * step
        )
    }
}

private struct DailyCostBarChart: View {
    let points: [ObservedDayCredits]
    /// Credits → cost in the display currency. Injected rather than reading the
    /// store directly so the bar heights and the axis labels are guaranteed to
    /// use one conversion, and the view stays previewable.
    let cost: (Double) -> Double
    let symbol: String

    /// The day keys are UTC and the table below is badged UTC, so the chart must
    /// bin and label in UTC too. With the autoupdating calendar every bar sat one
    /// day earlier than its table row for anyone west of UTC.
    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static let axisDayFormat = Date.FormatStyle(
        calendar: utcCalendar, timeZone: TimeZone(identifier: "UTC")!
    ).day().month(.abbreviated)

    /// Spelled-out date for VoiceOver, where "11 Aug" is read poorly.
    private static let accessibilityDayFormat = Date.FormatStyle(
        calendar: utcCalendar, timeZone: TimeZone(identifier: "UTC")!
    ).day().month(.wide).year()

    /// Keep the label count sane: one tick per day for a short cycle, thinning
    /// out as the month fills up.
    private var dayStride: Int {
        max(1, Int(ceil(Double(points.count) / 6.0)))
    }

    /// Computed once per body evaluation rather than inside the axis builder,
    /// which runs for every tick.
    private var scale: MoneyAxisScale {
        MoneyAxisScale.make(max: points.map { cost($0.credits) }.max() ?? 0)
    }

    var body: some View {
        if points.isEmpty {
            Text("No complete observed daily increases yet")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let scale = self.scale
            Chart(points.sorted { $0.day < $1.day }) { point in
                BarMark(
                    x: .value("Day", point.date, unit: .day, calendar: Self.utcCalendar),
                    y: .value("Cost", cost(point.credits))
                )
                .foregroundStyle(Color.accentColor.gradient)
                .cornerRadius(3)
                // Without this VoiceOver reads a bare number with no currency,
                // which after this change is the whole point of the chart.
                .accessibilityLabel(Self.accessibilityDayFormat.format(point.date))
                .accessibilityValue(
                    Fmt.axisMoney(cost(point.credits), symbol: symbol, decimals: 2)
                )
            }
            .chartXAxis {
                // Whole-day strides, never `.automatic`: with only a few days in
                // the cycle an automatic tick count lands on half-days, and since
                // the label format has no time component every day is drawn twice.
                AxisMarks(values: .stride(by: .day, count: dayStride)) {
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: Self.axisDayFormat)
                }
            }
            .chartYScale(domain: 0...scale.upperBound)
            .chartYAxis {
                // Explicit ticks, never `.automatic`: see `MoneyAxisScale`.
                AxisMarks(position: .leading, values: scale.ticks) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let amount = value.as(Double.self) {
                            Text(Fmt.axisMoney(
                                amount, symbol: symbol, decimals: scale.decimals
                            ))
                        }
                    }
                }
            }
            .environment(\.calendar, Self.utcCalendar)
            .environment(\.timeZone, TimeZone(identifier: "UTC")!)
        }
    }
}
