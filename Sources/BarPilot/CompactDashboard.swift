import SwiftUI
import Charts

@MainActor
final class PopoverPresentationState: ObservableObject {
    enum Layer {
        case base
        case spendCalendar
        case modelPricing
    }

    @Published var layer: Layer = .base

    /// Returns true when an overlay consumed Escape. The caller may close the
    /// containing NSPopover only when this returns false.
    @discardableResult
    func dismissTopLayer() -> Bool {
        guard layer != .base else { return false }
        layer = .base
        return true
    }

    func reset() { layer = .base }

    static func verify() {
        let state = PopoverPresentationState()
        precondition(!state.dismissTopLayer())
        state.layer = .spendCalendar
        precondition(state.dismissTopLayer() && state.layer == .base)
        state.layer = .modelPricing
        precondition(state.dismissTopLayer() && state.layer == .base)

        let statusItemWindow = verificationWindow()
        let popoverRoot = verificationWindow()
        let popoverChild = verificationWindow()
        let settingsRoot = verificationWindow()
        let settingsSheet = verificationWindow()
        let unknownPanel = verificationWindow()
        popoverRoot.addChildWindow(popoverChild, ordered: .above)
        settingsRoot.addChildWindow(settingsSheet, ordered: .above)

        precondition(PopoverMouseTarget.classify(
            candidate: statusItemWindow,
            statusItemWindow: statusItemWindow,
            popoverRoot: popoverRoot,
            settingsRoot: settingsRoot
        ) == .statusItem)
        for candidate in [popoverRoot, popoverChild] {
            precondition(PopoverMouseTarget.classify(
                candidate: candidate,
                statusItemWindow: statusItemWindow,
                popoverRoot: popoverRoot,
                settingsRoot: settingsRoot
            ) == .content)
        }
        for candidate in [settingsRoot, settingsSheet] {
            precondition(PopoverMouseTarget.classify(
                candidate: candidate,
                statusItemWindow: statusItemWindow,
                popoverRoot: popoverRoot,
                settingsRoot: settingsRoot
            ) == .settingsWindow)
        }
        precondition(PopoverMouseTarget.classify(
            candidate: unknownPanel,
            statusItemWindow: statusItemWindow,
            popoverRoot: popoverRoot,
            settingsRoot: settingsRoot
        ) == .auxiliaryUI)
        precondition(PopoverMouseTarget.classify(
            candidate: nil,
            statusItemWindow: statusItemWindow,
            popoverRoot: popoverRoot,
            settingsRoot: settingsRoot
        ) == .auxiliaryUI)
        precondition(PopoverMouseTarget.settingsWindow.closesParent)
        precondition(PopoverMouseTarget.otherApplication.closesParent)
        print("popover presentation verification passed")
    }

    private static func verificationWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
    }
}

/// The usage popover has application-defined dismissal, so every mouse event
/// has one explicit owner. Replacing a clicked SwiftUI button with an overlay
/// must never let AppKit reinterpret that click as a reason to close the parent.
@MainActor
enum PopoverMouseTarget: Equatable {
    case content
    case statusItem
    case auxiliaryUI
    case settingsWindow
    case otherApplication

    var closesParent: Bool {
        switch self {
        case .settingsWindow, .otherApplication:
            return true
        case .content, .statusItem, .auxiliaryUI:
            return false
        }
    }

    /// Classifies only windows BarPilot owns. Unknown local windows are treated
    /// as auxiliary UI because SwiftUI and AppKit create implementation-detail
    /// panels for controls such as popovers, menus and date pickers. Assuming an
    /// unknown panel is "outside" can close the parent during a valid click.
    static func classify(
        candidate: NSWindow?,
        statusItemWindow: NSWindow?,
        popoverRoot: NSWindow?,
        settingsRoot: NSWindow?
    ) -> Self {
        guard let candidate else { return .auxiliaryUI }
        if candidate === statusItemWindow { return .statusItem }
        if belongs(candidate, to: popoverRoot) { return .content }
        if belongs(candidate, to: settingsRoot) { return .settingsWindow }
        return .auxiliaryUI
    }

    private static func belongs(_ candidate: NSWindow, to root: NSWindow?) -> Bool {
        guard let root else { return false }
        var window: NSWindow? = candidate
        while let current = window {
            if current === root { return true }
            window = current.parent
        }
        return false
    }
}

struct CompactDashboard: View {
    @EnvironmentObject var store: UsageStore
    let connectGitHub: () -> Void
    let openSettings: () -> Void
    let showLegacy: () -> Void
    let closePopover: () -> Void
    @ObservedObject var presentationState: PopoverPresentationState
    @State private var selectedSpendDay: String?
    @State private var selectedSpendCredits: Double?

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                cycleNavigator
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !store.serverUsageEnabled {
                            connectionCard
                        }
                        spendSummary
                        CompactBudgetBar()
                        if selectedSpendDay != nil {
                            selectedDayCard
                        }
                        activityCard
                    }
                    .padding(16)
                }
                Divider()
                footer
            }
            .allowsHitTesting(!showingModelPricing)
            .accessibilityHidden(showingModelPricing)
            if showingSpendCalendar {
                spendCalendarOverlay
            }
            if showingModelPricing {
                modelPricingOverlay
            }
        }
        .frame(width: 600)
        .frame(minHeight: 480, maxHeight: .infinity)
        .onExitCommand(perform: dismissTopLayer)
    }

    /// Escape unwinds exactly one presentation level. Handling it here avoids
    /// a nested overlay and NSPopover both reacting to the same key event.
    private func dismissTopLayer() {
        if !presentationState.dismissTopLayer() {
            closePopover()
        }
    }

    private var showingSpendCalendar: Bool {
        get { presentationState.layer == .spendCalendar }
        nonmutating set {
            if newValue {
                presentationState.layer = .spendCalendar
            } else if presentationState.layer == .spendCalendar {
                presentationState.layer = .base
            }
        }
    }

    private var showingModelPricing: Bool {
        get { presentationState.layer == .modelPricing }
        nonmutating set {
            if newValue {
                presentationState.layer = .modelPricing
            } else if presentationState.layer == .modelPricing {
                presentationState.layer = .base
            }
        }
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
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.gradient)
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 0) {
                Text("BARPILOT")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(.secondary)
                Text("Copilot usage")
                    .font(.headline)
            }
            Spacer()
            if store.isLoading { ProgressView().controlSize(.small) }
            Button {
                Task { await store.reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
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
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var cycleNavigator: some View {
        HStack(spacing: 12) {
            Button {
                selectedSpendDay = nil
                selectedSpendCredits = nil
                showingSpendCalendar = false
                store.selectOlderCreditCycle()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(!store.canSelectOlderCreditCycle || store.isLoadingCreditCycle)
            .help("Older billing cycle")

            Button {
                showingSpendCalendar.toggle()
            } label: {
                VStack(spacing: 1) {
                    Text(store.isViewingCurrentCreditCycle ? "Current billing cycle" : "Billing cycle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                        Text(cycleRangeLabel).monospacedDigit()
                    }
                    .font(.caption.weight(.medium))
                }
                .frame(minWidth: 150)
            }
            .buttonStyle(.plain)
            .disabled(store.selectedCreditCycle == nil)
            .help("Choose a date and inspect observed daily spend")

            Button {
                selectedSpendDay = nil
                selectedSpendCredits = nil
                showingSpendCalendar = false
                store.selectNewerCreditCycle()
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .disabled(!store.canSelectNewerCreditCycle || store.isLoadingCreditCycle)
            .help("Newer billing cycle")
            if store.isLoadingCreditCycle { ProgressView().controlSize(.mini) }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.025))
    }

    private var modelPricingOverlay: some View {
        ZStack {
            Color.black.opacity(0.18)
                .contentShape(Rectangle())
                .onTapGesture { showingModelPricing = false }
            ModelPricingView(close: { showingModelPricing = false })
                .frame(width: 570)
                .frame(maxHeight: 660)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.secondary.opacity(0.2))
                )
                .shadow(color: .black.opacity(0.25), radius: 22, y: 9)
                .padding(14)
        }
        .zIndex(20)
    }

    private var cycleRangeLabel: String {
        guard let cycle = store.selectedCreditCycle,
              let start = cycle.startAt else {
            return "Billing cycle"
        }
        return "\(Self.cycleDateFormatter.string(from: start)) – \(Self.cycleDateFormatter.string(from: cycle.resetAt))"
    }

    private var spendCalendarOverlay: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.12)
                .contentShape(Rectangle())
                .onTapGesture { showingSpendCalendar = false }
            SpendHistoryCalendar(
                initialMonth: calendarInitialDate,
                selectedDay: selectedSpendDay,
                selectDay: { date in
                    guard store.selectCreditCycle(containingUTCDate: date) else {
                        return
                    }
                    let day = CreditCycleSummary.utcDayString(for: date)
                    selectedSpendDay = day
                    selectedSpendCredits = store.spendCalendarDailyCredits[day]
                    showingSpendCalendar = false
                },
                close: { showingSpendCalendar = false }
            )
            .environmentObject(store)
            .frame(width: 420)
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.secondary.opacity(0.2))
            )
            .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
            .offset(x: 16, y: 108)
        }
        .zIndex(10)
    }

    private var calendarInitialDate: Date {
        if let selectedSpendDay {
            return Date(
                timeIntervalSince1970:
                    Double(Aggregator.utcMidnightMs(selectedSpendDay)) / 1000
            )
        }
        return store.selectedCreditCycle?.startAt ?? Date()
    }

    private var selectedDayCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar.badge.checkmark")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(selectedSpendDayLabel)
                    .font(.subheadline.weight(.semibold))
                if store.isLoadingCreditCycle {
                    Text("Loading billing-cycle history…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let selectedSpendCredits {
                    Text("\(Fmt.credits(selectedSpendCredits)) credits · \(store.costString(credits: selectedSpendCredits)) observed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No spend could be assigned to this UTC day.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                selectedSpendDay = nil
                selectedSpendCredits = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Clear selected day")
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var selectedSpendDayLabel: String {
        guard let selectedSpendDay else { return "Selected day" }
        let date = Date(
            timeIntervalSince1970:
                Double(Aggregator.utcMidnightMs(selectedSpendDay)) / 1000
        )
        return "\(Self.selectedDayFormatter.string(from: date)) · UTC"
    }

    private var spendSummary: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(store.isViewingCurrentCreditCycle
                         ? "SPENT THIS CYCLE" : "SPENT IN THIS CYCLE")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.7)
                        .foregroundStyle(.secondary)
                    if let updated = store.currentServerUsageSample?.capturedAt,
                       store.isViewingCurrentCreditCycle {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 6, height: 6)
                        Text("Updated \(relativeUpdatedLabel(updated))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(store.displayCostString(credits: store.compactTotalCredits))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                HStack(spacing: 7) {
                    Text("\(Fmt.credits(store.compactTotalCredits)) premium credits")
                        .font(.caption)
                    if let cycle = store.selectedCreditCycle {
                        Text("·")
                        Text("\(store.isViewingCurrentCreditCycle ? "Resets" : "Ended") \(Self.resetFormatter.string(from: cycle.resetAt))")
                            .font(.caption)
                    }
                }
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 8) {
                Picker("Display currency", selection: $store.displayCurrency) {
                    ForEach(Currency.allCases, id: \.self) { currency in
                        Text(currency.code).tag(currency)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 132)

                Button {
                    showingSpendCalendar = false
                    showingModelPricing = true
                } label: {
                    Label("Model prices", systemImage: "tag")
                        .frame(width: 112)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.accentColor)
                .help("Compare current GitHub Copilot model token prices")

                Button {
                    showLegacy()
                } label: {
                    Label("Legacy telemetry", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Open the previous telemetry-based interface unchanged")
            }
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [Color.primary.opacity(0.045), Color.accentColor.opacity(0.07)],
                startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.16))
        }
    }

    private func relativeUpdatedLabel(_ date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m ago" }
        return "\(Int(seconds / 3_600))h ago"
    }

    private var activityCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            dailyChartSection
                .padding(14)
            Divider()
            dailySection
                .padding(14)
        }
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.secondary.opacity(0.16))
        }
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
                Text("Recent activity")
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
                Text("Cost").frame(width: 90, alignment: .trailing)
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
                            Text(store.displayCostString(credits: row.credits))
                                .monospacedDigit()
                                .frame(width: 90, alignment: .trailing)
                        }
                        .font(.callout)
                        .padding(.vertical, 5)
                        .padding(.horizontal, 5)
                        .background(
                            selectedSpendDay == row.day
                                ? Color.accentColor.opacity(0.10)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
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
            if let updated = store.currentServerUsageSample?.capturedAt {
                Text("· GitHub updated \(Fmt.dateTime(Int64(updated.timeIntervalSince1970 * 1000)))")
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
        if store.currentServerUsageSample == nil || store.serverUsageIsStale { return .orange }
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

    private static let cycleDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    private static let selectedDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMMM yyyy"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()
}

private struct SpendHistoryCalendar: View {
    @EnvironmentObject private var store: UsageStore
    let initialMonth: Date
    let selectedDay: String?
    let selectDay: (Date) -> Void
    let close: () -> Void
    @State private var displayedMonth: Date

    init(
        initialMonth: Date,
        selectedDay: String?,
        selectDay: @escaping (Date) -> Void,
        close: @escaping () -> Void
    ) {
        self.initialMonth = initialMonth
        self.selectedDay = selectedDay
        self.selectDay = selectDay
        self.close = close
        _displayedMonth = State(initialValue: Self.monthStart(initialMonth))
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Daily spend calendar")
                        .font(.headline)
                    Text("Observed spend · UTC")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if store.isLoadingSpendCalendar {
                    ProgressView().controlSize(.mini)
                }
                Button(action: close) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close calendar")
            }

            HStack {
                Button {
                    moveMonth(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .disabled(previousMonth == nil || store.isLoadingSpendCalendar)
                .help("Previous available month")

                Spacer()
                Menu {
                    ForEach(Array(availableMonths.reversed()), id: \.self) { month in
                        Button(Self.monthFormatter.string(from: month)) {
                            showMonth(month)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(Self.monthFormatter.string(from: displayedMonth))
                            .font(.subheadline.weight(.semibold))
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(store.isLoadingSpendCalendar)
                .help("Choose an available month")
                Spacer()

                Button {
                    moveMonth(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
                .disabled(nextMonth == nil || store.isLoadingSpendCalendar)
                .help("Next available month")
            }

            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Self.weekdays, id: \.self) { weekday in
                    Text(weekday)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
                ForEach(Array(calendarDates.enumerated()), id: \.offset) { _, date in
                    if let date {
                        dayCell(date)
                    } else {
                        Color.clear.frame(height: 44)
                    }
                }
            }

            HStack(spacing: 6) {
                Circle().fill(Color.accentColor.opacity(0.28))
                    .frame(width: 8, height: 8)
                Text("Darker days cost more; — means no spend was safely assignable.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onAppear {
            let normalized = nearestAvailableMonth(to: displayedMonth) ?? displayedMonth
            displayedMonth = normalized
            store.loadSpendCalendar(containing: normalized)
        }
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
    }

    private var availableMonths: [Date] {
        var months: Set<Date> = []
        let today = Self.monthStart(Date())
        for cycle in store.creditCycles {
            guard let start = cycle.startAt else { continue }
            var month = Self.monthStart(start)
            let last = Self.monthStart(
                cycle.resetAt.addingTimeInterval(-0.001)
            )
            var count = 0
            while month <= last && month <= today && count < 240 {
                months.insert(month)
                guard let next = Self.utcCalendar.date(
                    byAdding: .month, value: 1, to: month
                ) else { break }
                month = next
                count += 1
            }
        }
        return months.sorted()
    }

    private var previousMonth: Date? {
        availableMonths.last { $0 < displayedMonth }
    }

    private var nextMonth: Date? {
        availableMonths.first { $0 > displayedMonth }
    }

    private func moveMonth(by direction: Int) {
        guard let month = direction < 0 ? previousMonth : nextMonth else { return }
        showMonth(month)
    }

    private func showMonth(_ month: Date) {
        displayedMonth = month
        store.loadSpendCalendar(containing: month)
    }

    private func nearestAvailableMonth(to month: Date) -> Date? {
        availableMonths.min {
            abs($0.timeIntervalSince(month)) < abs($1.timeIntervalSince(month))
        }
    }

    private var calendarDates: [Date?] {
        let calendar = Self.utcCalendar
        guard let days = calendar.range(of: .day, in: .month, for: displayedMonth)
        else { return [] }
        let weekday = calendar.component(.weekday, from: displayedMonth)
        let leading = (weekday + 5) % 7
        var dates = Array<Date?>(repeating: nil, count: leading)
        dates += days.compactMap {
            calendar.date(byAdding: .day, value: $0 - 1, to: displayedMonth)
        }
        while dates.count % 7 != 0 { dates.append(nil) }
        return dates
    }

    @ViewBuilder
    private func dayCell(_ date: Date) -> some View {
        let day = CreditCycleSummary.utcDayString(for: date)
        let todayStart = CreditCycleSummary.dayStart(
            for: Int64(Date().timeIntervalSince1970 * 1000)
        )
        let dateStart = CreditCycleSummary.dayStart(
            for: Int64(date.timeIntervalSince1970 * 1000)
        )
        let isAvailable = dateStart <= todayStart
            && CreditCycleSummary.cycle(
                containingUTCDate: date, in: store.creditCycles
            ) != nil
        let credits = store.spendCalendarMonthKey
            == CreditCycleSummary.utcMonthKey(for: displayedMonth)
            ? store.spendCalendarDailyCredits[day]
            : nil
        let maximum = store.spendCalendarDailyCredits.values.max() ?? 0
        let heat = credits.map {
            maximum > 0 ? min(max($0 / maximum, 0), 1) : 0
        } ?? 0
        let isSelected = selectedDay == day

        Button {
            selectDay(date)
        } label: {
            VStack(spacing: 2) {
                Text("\(Self.utcCalendar.component(.day, from: date))")
                    .font(.caption.weight(isSelected ? .bold : .medium))
                if let credits {
                    Text(store.costString(credits: credits))
                        .font(.system(size: 8, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                } else {
                    Text("—")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(isAvailable ? Color.primary : Color.secondary.opacity(0.35))
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.32)
                    : Color.accentColor.opacity(credits == nil ? 0 : 0.07 + heat * 0.21),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.clear,
                        lineWidth: 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable || store.isLoadingSpendCalendar)
        .help(dayCellHelp(day: day, credits: credits, available: isAvailable))
    }

    private func dayCellHelp(
        day: String, credits: Double?, available: Bool
    ) -> String {
        guard available else { return "No stored billing cycle for \(day)" }
        guard let credits else {
            return "\(day): no safely assignable observed spend"
        }
        return "\(day): \(store.costString(credits: credits)) observed"
    }

    private static func monthStart(_ date: Date) -> Date {
        utcCalendar.date(
            from: utcCalendar.dateComponents([.year, .month], from: date)
        ) ?? date
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()
}

private struct CompactBudgetBar: View {
    @EnvironmentObject var store: UsageStore
    @State private var isEditingHistoricalBudget = false
    @State private var historicalBudgetText = ""
    @State private var historicalBudgetError: String?
    @State private var isSavingHistoricalBudget = false
    private static let barHeight: CGFloat = 10
    private static let chevronGutter: CGFloat = 7
    private static let labelWidth: CGFloat = 142
    private static let caretGap: CGFloat = 7
    private static let budgetMonthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    var body: some View {
        let spent = store.compactTotalCredits
        let budgetUSD = store.compactBudgetUSD
        let budget = (budgetUSD ?? 0) * 100
        let projection = store.compactSpendProjection
        let hasBudget = budget > 0

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Monthly budget")
                        .font(.subheadline.weight(.semibold))
                    if let budgetUSD, hasBudget {
                        Text("\(store.displayCostString(credits: spent)) of \(store.budgetMoneyString(usd: budgetUSD))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } else if store.canAssignMissingBudgetForSelectedCreditCycle {
                        Text("The budget wasn’t captured for \(selectedCycleMonthLabel).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if budgetUSD == nil {
                        Text("No budget was recorded for this older cycle.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if store.isViewingCurrentCreditCycle {
                        Text("Set a target in Settings to compare your current pace.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("This cycle was recorded without a budget.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if store.isViewingCurrentCreditCycle {
                    Group {
                        if hasBudget {
                            Text("\(Int((spent / budget * 100).rounded()))% used")
                                .monospacedDigit()
                        } else {
                            Text("No budget set")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 9) {
                        if hasBudget {
                            Text("\(Int((spent / budget * 100).rounded()))% used")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        if store.canAssignMissingBudgetForSelectedCreditCycle,
                           !isEditingHistoricalBudget {
                            Button("Add \(selectedCycleMonthLabel) budget") {
                                beginEditingHistoricalBudget()
                            }
                            .buttonStyle(.plain)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .disabled(store.isLoadingCreditCycle)
                            .help("Supply the one budget missed before automatic snapshots began")
                        }
                    }
                    .font(.caption)
                }
            }

            if isEditingHistoricalBudget {
                historicalBudgetEditor
            }

            if let budgetUSD, budgetUSD > 0 {
                budgetMeter(
                    spent: spent,
                    budget: budget,
                    budgetUSD: budgetUSD,
                    projection: projection
                )
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.14))
        }
        .onChange(of: store.selectedCreditCycleDayMs) { _ in
            isEditingHistoricalBudget = false
            historicalBudgetError = nil
            isSavingHistoricalBudget = false
        }
        .onChange(of: store.displayCurrency) { _ in
            if isEditingHistoricalBudget { beginEditingHistoricalBudget() }
        }
        .onChange(of: store.usdToAUD) { _ in
            if isEditingHistoricalBudget { beginEditingHistoricalBudget() }
        }
    }

    private var historicalBudgetEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Text("\(selectedCycleMonthLabel) budget")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(store.effectiveCurrency.symbol)
                    .foregroundStyle(.secondary)
                BudgetField(
                    text: $historicalBudgetText,
                    onCommit: commitHistoricalBudget
                )
                .frame(width: 92, height: 22)
                Button("Save", action: commitHistoricalBudget)
                    .disabled(
                        historicalBudgetText.trimmingCharacters(in: .whitespaces).isEmpty
                            || isSavingHistoricalBudget
                            || store.isLoadingCreditCycle
                    )
                Button("Cancel") {
                    isEditingHistoricalBudget = false
                    historicalBudgetError = nil
                }
                .disabled(isSavingHistoricalBudget)
                if isSavingHistoricalBudget {
                    ProgressView().controlSize(.small)
                }
            }
            if let historicalBudgetError {
                Text(historicalBudgetError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func budgetMeter(
        spent: Double,
        budget: Double,
        budgetUSD: Double,
        projection: SpendProjection?
    ) -> some View {
        let maximum = budget
        let over = spent > budget
        return VStack(alignment: .leading, spacing: 0) {
            GeometryReader { geometry in
                let width = geometry.size.width
                let currentReach = width * min(spent / maximum, 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.16))
                    if let projection {
                        let reach = width * min(projection.projectedCredits / maximum, 1)
                        Capsule()
                            .fill(projectionColor(projection).opacity(0.28))
                            .frame(width: reach)
                        if projection.projectedCredits <= maximum {
                            Capsule()
                                .fill(projectionColor(projection).opacity(0.9))
                                .frame(width: 2)
                                .offset(x: max(0, reach - 2))
                        }
                    }
                    Capsule()
                        .fill(over ? Color.red : Color.accentColor)
                        .frame(width: spent > 0 ? max(Self.barHeight, currentReach) : 0)
                }
                .overlay(alignment: .leading) {
                    if let projection, projection.projectedCredits > maximum {
                        let overPercent = projection.projectedCredits / maximum * 100 - 100
                        let count = overPercent >= 75 ? 3 : (overPercent >= 25 ? 2 : 1)
                        HStack(spacing: -2) {
                            ForEach(0..<count, id: \.self) { _ in
                                Text("›").font(.system(size: 13, weight: .bold))
                            }
                        }
                        .foregroundStyle(projectionColor(projection))
                        .fixedSize()
                        .offset(x: width + 3)
                    }
                }
            }
            .frame(height: Self.barHeight)
            .padding(.trailing, Self.chevronGutter)

            if let projection, projection.projectedCredits > maximum {
                Text(projectionLabel(projection))
                    .font(.system(size: 9, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(projectionColor(projection))
                    .padding(.top, 3)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help(projectionHelp(projection))
            } else if let projection {
                GeometryReader { geometry in
                    let fraction = min(1, projection.projectedCredits / maximum)
                    let x = geometry.size.width * fraction
                    let flip = x + Self.caretGap + Self.labelWidth > geometry.size.width
                    ZStack(alignment: .topLeading) {
                        Text("▲")
                            .font(.system(size: 7))
                            .offset(x: max(0, x - 3))
                        Text(projectionLabel(projection))
                            .font(.system(size: 9, weight: .medium))
                            .monospacedDigit()
                            .frame(width: Self.labelWidth, alignment: flip ? .trailing : .leading)
                            .offset(x: flip
                                ? x - Self.labelWidth - Self.caretGap
                                : x + Self.caretGap)
                    }
                    .foregroundStyle(projectionColor(projection))
                    .help(projectionHelp(projection))
                }
                .frame(height: 12)
                .padding(.trailing, Self.chevronGutter)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Monthly budget")
        .accessibilityValue(accessibilityValue(
            spent: spent,
            budgetUSD: budgetUSD,
            projection: projection
        ))
    }

    private func beginEditingHistoricalBudget() {
        let budgetUSD = store.compactBudgetUSD ?? store.monthlyBudget
        if store.effectiveCurrency == .aud, let rate = store.usdToAUD {
            historicalBudgetText = String(Int((budgetUSD * rate).rounded()))
        } else {
            historicalBudgetText = Fmt.money(budgetUSD)
                .replacingOccurrences(of: "$", with: "")
        }
        historicalBudgetError = nil
        isEditingHistoricalBudget = true
    }

    private func commitHistoricalBudget() {
        let value: Double
        switch BudgetInput.parse(historicalBudgetText) {
        case .invalid:
            historicalBudgetError = "Enter a number, for example 500."
            return
        case .tooLarge:
            historicalBudgetError = "That looks like a typo — the maximum is \(store.effectiveCurrency.symbol)\(BudgetInput.maximumText)."
            return
        case .ok(let parsed):
            if store.effectiveCurrency == .aud, let rate = store.usdToAUD, rate > 0 {
                value = parsed / rate
            } else {
                value = parsed
            }
        }

        historicalBudgetError = nil
        isSavingHistoricalBudget = true
        Task {
            let saved = await store.assignMissingBudgetForSelectedCreditCycle(value)
            isSavingHistoricalBudget = false
            if saved {
                isEditingHistoricalBudget = false
            } else {
                historicalBudgetError = "The budget could not be saved. Try again."
            }
        }
    }

    private var selectedCycleMonthLabel: String {
        guard let start = store.selectedCreditCycle?.startAt else {
            return "previous cycle"
        }
        return Self.budgetMonthFormatter.string(from: start)
    }

    private func projectionColor(_ projection: SpendProjection) -> Color {
        projection.overBudget ? .red : .secondary
    }

    private func projectionLabel(_ projection: SpendProjection) -> String {
        "projected \(store.displayCostString(credits: projection.projectedCredits))"
    }

    private func projectionHelp(_ projection: SpendProjection) -> String {
        let basis = projection.excludesWeekends ? "working-day" : "calendar-day"
        return "Projected to \(projection.endLabel) from the current \(basis) pace."
    }

    private func accessibilityValue(
        spent: Double, budgetUSD: Double, projection: SpendProjection?
    ) -> String {
        var parts = ["\(store.displayCostString(credits: spent)) spent"]
        parts.append("\(store.budgetMoneyString(usd: budgetUSD)) budget")
        if let projection { parts.append(projectionLabel(projection)) }
        return parts.joined(separator: ", ")
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
