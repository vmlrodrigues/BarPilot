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
                    Text("Daily credit usage")
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
            DailyCreditsBarChart(points: timeline.daily)
                .frame(height: 150)
        }
    }

    private var dailyChartSubtitle: String {
        let timeline = store.creditTimeline
        guard timeline.firstAtMs != nil else {
            return "Waiting for saved GitHub counter samples."
        }
        if timeline.unallocatedCredits > 0 {
            return "\(Fmt.credits(timeline.unallocatedCredits)) credits cannot be assigned to a day."
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

private struct DailyCreditsBarChart: View {
    let points: [ObservedDayCredits]

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

    /// Keep the label count sane: one tick per day for a short cycle, thinning
    /// out as the month fills up.
    private var dayStride: Int {
        max(1, Int(ceil(Double(points.count) / 6.0)))
    }

    var body: some View {
        if points.isEmpty {
            Text("No complete observed daily increases yet")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Chart(points.sorted { $0.day < $1.day }) { point in
                BarMark(
                    x: .value("Day", point.date, unit: .day, calendar: Self.utcCalendar),
                    y: .value("Credits", point.credits)
                )
                .foregroundStyle(Color.accentColor.gradient)
                .cornerRadius(3)
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
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) {
                    AxisGridLine()
                    AxisValueLabel()
                }
            }
            .environment(\.calendar, Self.utcCalendar)
            .environment(\.timeZone, TimeZone(identifier: "UTC")!)
        }
    }
}
