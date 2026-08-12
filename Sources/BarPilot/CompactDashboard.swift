import SwiftUI

struct CompactDashboard: View {
    @EnvironmentObject var store: UsageStore
    let showLegacy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    valueCards
                    CompactBudgetBar()
                    hourlySection
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .foregroundStyle(.tint)
                Text("Copilot Credits")
                    .font(.headline)
                if Updater.isDevBuild {
                    Text("PROTOTYPE")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange, in: Capsule())
                }
                Spacer()
                if store.isLoading { ProgressView().controlSize(.small) }
                Button {
                    Task { await store.reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh now")
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

    private var valueCards: some View {
        HStack(spacing: 10) {
            valueCard(
                title: "US dollars", value: store.usdCostString(credits: store.compactTotalCredits),
                detail: "100 credits = US$1")
            valueCard(
                title: "Australian dollars", value: store.audCostString(credits: store.compactTotalCredits),
                detail: store.usdToAUD.map { String(format: "Live rate · %.4f", $0) } ?? "Exchange rate unavailable")
        }
    }

    private func valueCard(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
            Text(detail).font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }

    private var hourlySection: some View {
        let timeline = store.creditTimeline
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hourly credit snapshots")
                        .font(.subheadline.weight(.semibold))
                    Text(timelineSubtitle)
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
            HourlyCreditsChart(points: timeline.hourly)
                .frame(height: 150)
        }
    }

    private var timelineSubtitle: String {
        let timeline = store.creditTimeline
        guard timeline.firstAtMs != nil else {
            return "Waiting for saved GitHub counter samples."
        }
        if timeline.unallocatedCredits > 0 {
            return "\(Fmt.credits(timeline.unallocatedCredits)) credits crossed an offline gap and remain unallocated."
        }
        return "Cumulative GitHub counter, reduced to one point per hour."
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
            Spacer()
            Button("Show legacy telemetry") { showLegacy() }
                .buttonStyle(.borderless)
                .font(.caption)
                .help("Temporarily open the telemetry-based interface scheduled for removal.")
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
        guard store.serverUsageEnabled else { return Color.secondary.opacity(0.4) }
        if store.serverUsageError != nil { return .red }
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

    var body: some View {
        let spent = store.compactTotalCredits
        let budget = store.monthlyBudget * 100
        let projection = store.compactSpendProjection
        let maximum = max(budget * 1.2, spent, projection?.projectedCredits ?? 0, 1)
        let over = budget > 0 && spent > budget

        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("This month’s spend")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(store.usdCostString(credits: budget)) budget")
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
                    if budget > 0 {
                        Rectangle()
                            .fill(Color.orange)
                            .frame(width: 2, height: 18)
                            .offset(x: width * min(budget / maximum, 1) - 1)
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
                    Text("Projected \(store.usdCostString(credits: projection.projectedCredits))")
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

private struct HourlyCreditsChart: View {
    let points: [HourlyCreditPoint]
    private let maximumJoinedGapMs: Int64 = 90 * 60 * 1000

    var body: some View {
        GeometryReader { geometry in
            if points.count < 2 {
                Text(points.isEmpty ? "No samples yet" : "Waiting for another hourly snapshot")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let values = points.map(\.credits)
                let minimum = values.min() ?? 0
                let maximum = values.max() ?? minimum
                let spread = max(maximum - minimum, 1)
                let plotHeight = geometry.size.height - 22
                let firstTime = points.first?.atMs ?? 0
                let timeRange = max((points.last?.atMs ?? firstTime) - firstTime, 1)

                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        ForEach(0..<4, id: \.self) { _ in
                            Divider()
                            Spacer()
                        }
                    }
                    .opacity(0.35)
                    .frame(height: plotHeight)

                    linePath(
                        size: CGSize(width: geometry.size.width, height: plotHeight),
                        minimum: minimum, spread: spread,
                        firstTime: firstTime, timeRange: timeRange
                    )
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineJoin: .round))

                    HStack {
                        Text(Self.axisFormatter.string(from: date(points.first!.atMs)))
                        Spacer()
                        Text(Self.axisFormatter.string(from: date(points.last!.atMs)))
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .offset(y: plotHeight + 6)
                }
            }
        }
    }

    private func linePath(
        size: CGSize, minimum: Double, spread: Double,
        firstTime: Int64, timeRange: Int64
    ) -> Path {
        Path { path in
            for (index, point) in points.enumerated() {
                let x = size.width * CGFloat(point.atMs - firstTime) / CGFloat(timeRange)
                let y = size.height * (1 - CGFloat((point.credits - minimum) / spread))
                let joinsPrevious = index > 0
                    && point.atMs - points[index - 1].atMs <= maximumJoinedGapMs
                if !joinsPrevious { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
        }
    }

    private func date(_ ms: Int64) -> Date {
        Date(timeIntervalSince1970: Double(ms) / 1000)
    }

    private static let axisFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM, h a"
        return formatter
    }()
}
