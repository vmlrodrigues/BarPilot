import SwiftUI
import AppKit

// ---------------------------------------------------------------------------
// DetailView — the compact server-first dashboard plus the temporary legacy
// telemetry interface.
// ---------------------------------------------------------------------------

struct DetailView: View {
    @EnvironmentObject var store: UsageStore
    @State private var showingUTCInfo = false
    @State private var showingSyncInfo = false
    @State private var showingCreditInfo = false
    @State private var showingLegacyTelemetry = false

    var body: some View {
        Group {
            if showingLegacyTelemetry {
                legacyView
            } else {
                CompactDashboard {
                    showingLegacyTelemetry = true
                }
            }
        }
    }

    private var legacyView: some View {
        VStack(alignment: .leading, spacing: 0) {
            legacyBanner
            exporterBanner
            header
            Divider()
            BudgetBar(
                title: store.spendTitle,
                spentCredits: store.displayTotalCredits,
                budgetCredits: store.periodBudgetCredits,
                monthlyBudget: store.monthlyBudget
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            tabs
            Divider()
            footer
        }
        .frame(width: 600)
        .frame(minHeight: 480, maxHeight: .infinity)
    }

    private var legacyBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Legacy telemetry view")
                    .font(.caption.weight(.semibold))
                Text("Model and session details are incomplete because local telemetry omits billed calls. This interface will be removed soon.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Back to current view") {
                showingLegacyTelemetry = false
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.10))
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "chart.bar.doc.horizontal")
                    .foregroundStyle(.tint)
                Text("Copilot Usage")
                    .font(.headline)
                if Updater.isDevBuild {
                    Text("DEV")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.orange, in: Capsule())
                        .help("Local development build (not the released app).")
                }
                Spacer()
                if store.isLoading {
                    ProgressView().controlSize(.small)
                }
                Button {
                    Task { await store.reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh now")
            }

            HStack(spacing: 8) {
                Picker("", selection: $store.periodKind) {
                    ForEach(PeriodKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()

                if store.periodKind == .custom {
                    DatePicker("", selection: $store.customFrom, displayedComponents: .date)
                        .labelsHidden()
                    Text("→").foregroundStyle(.secondary)
                    DatePicker("", selection: $store.customTo, displayedComponents: .date)
                        .labelsHidden()
                }
                Spacer()
                HStack(spacing: 4) {
                    Text("\(store.report.fromStr)  →  \(store.report.toStr)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        showingUTCInfo.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.borderless)
                    .popover(isPresented: $showingUTCInfo) {
                        Text("Date ranges use UTC midnight to match GitHub's billing cycle, which resets at UTC midnight on the 1st of each month.")
                            .font(.caption)
                            .padding()
                            .frame(width: 280)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            HStack(alignment: .lastTextBaseline, spacing: 10) {
                if store.lastUpdated == nil {
                    // First load hasn't completed yet — show a loading placeholder
                    // rather than a misleading "$0.00" from the empty initial report.
                    Text("—")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text("loading…")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                } else {
                    Text(store.costString(credits: store.displayTotalCredits))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("\(Fmt.credits(store.displayTotalCredits)) credits")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Sparkline(totals: store.sparklineTotals)
                    .frame(width: 150, height: 38)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    // MARK: Tabs

    private var tabs: some View {
        TabView {
            SummaryTab(rows: store.summaryRows, total: store.displayTotalCredits)
                .tabItem { Text("Summary") }
            ModelsTab(rows: store.modelRows, total: store.displayTotalCredits)
                .tabItem { Text("Models") }
            DailyTab(rows: store.dailyRows, total: store.classifiedTotalCredits)
                .tabItem { Text("Daily") }
            SessionsTab(rows: store.report.sessions, total: store.sessionClassifiedTotalCredits)
                .tabItem { Text("Sessions") }
            TopTab(rows: store.report.top)
                .tabItem { Text("Top") }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            if !store.status.allConfigured {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption2)
                    Text(setupHint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Enable…") { store.runTelemetrySetup() }
                        .buttonStyle(.borderless)
                        .font(.caption2)
                        .help("Enable OTel telemetry now (shows exactly what will change first).")
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
            }

            if let hint = restartHint {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(.blue)
                        .font(.caption2)
                    Text(hint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
            }

            HStack(spacing: 12) {
                sourceBadge("VS Code", found: store.status.vscodeFound,
                            configured: store.status.vscodeConfigured, count: store.status.vscodeCount)
                sourceBadge("Mac App", found: store.status.macAppFound,
                            configured: store.status.macAppConfigured, count: store.status.macAppCount)
                HStack(spacing: 4) {
                    Circle()
                        .fill(creditStatusColor)
                        .frame(width: 7, height: 7)
                    Text(store.serverUsageStatusLabel)
                        .font(.caption2)
                        .foregroundStyle(store.serverUsageError == nil ? Color.secondary : Color.red)
                        .fixedSize()
                    Button { showingCreditInfo.toggle() } label: {
                        Image(systemName: "info.circle").font(.caption2).foregroundStyle(.blue)
                    }
                    .buttonStyle(.borderless)
                    .popover(isPresented: $showingCreditInfo) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("GitHub credit total").font(.caption.weight(.semibold))
                            if !store.serverUsageEnabled {
                                Text("Off. Enable **GitHub Credit Total** from the right-click menu to reconcile local attribution with GitHub’s account counter.")
                                    .foregroundStyle(.secondary)
                            } else {
                                if let error = store.serverUsageError {
                                    Text(error).foregroundStyle(.red)
                                }
                                if let sample = store.serverUsageSample {
                                    Text("Last sample: **\(Fmt.dateTime(sample.capturedAtMs))**")
                                    Text("Billing-cycle reset: **\(Fmt.dateTime(sample.resetAtMs))**")
                                } else if store.serverUsageError == nil {
                                    Text("Waiting for the first sample…").foregroundStyle(.secondary)
                                }
                                Text("For This Month, GitHub supplies the headline total while local telemetry supplies model and session detail. Other ranges remain local unless enough server samples exist to reconstruct them.")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption).padding().frame(width: 300)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if store.syncEnabled {
                    let hasError = store.syncError != nil
                    HStack(spacing: 4) {
                        Image(systemName: hasError ? "exclamationmark.triangle.fill" : "arrow.triangle.2.circlepath")
                            .font(.caption2).foregroundStyle(hasError ? .red : .green)
                        Text(hasError ? "sync error"
                             : (store.syncMachineCount == 1 ? "sync on · 1 machine" : "sync on · \(store.syncMachineCount) machines"))
                            .font(.caption2).foregroundStyle(hasError ? .red : .green).fixedSize()
                        Button { showingSyncInfo.toggle() } label: {
                            Image(systemName: "info.circle").font(.caption2).foregroundStyle(.blue)
                        }
                        .buttonStyle(.borderless)
                        .popover(isPresented: $showingSyncInfo) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Multi-machine sync").font(.caption.weight(.semibold))
                                if let err = store.syncError {
                                    Text(err).foregroundStyle(.red)
                                }
                                if let login = store.syncLogin {
                                    Text("Authorized as **@\(login)**")
                                } else if !hasError {
                                    Text("Authorized account: checking…").foregroundStyle(.secondary)
                                }
                                Text("Each Mac stores compact account-counter observations in a secret gist — no code, prompts, or content. The current dashboard unions matching observations to fill offline gaps; it never adds account totals together. The legacy summary remains synced during its deprecation window.")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption).padding().frame(width: 290)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .help(hasError ? (store.syncError ?? "") : "Multi-machine sync is ON.")
                }
                Spacer()
                if let updated = store.lastUpdated {
                    Text("Updated \(Fmt.dateTime(Int64(updated.timeIntervalSince1970 * 1000)))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")\(Updater.isDevBuild ? "-dev" : "")")
                    .font(.caption2)
                    .foregroundStyle(Updater.isDevBuild ? Color.orange : Color.secondary)
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private var setupHint: String {
        var missing: [String] = []
        if !store.status.vscodeConfigured { missing.append("VS Code") }
        if !store.status.macAppConfigured { missing.append("Mac App") }
        let who = missing.joined(separator: " & ")
        return "Telemetry not enabled for \(who)."
    }

    /// Configured sources that aren't producing any usage yet — almost always
    /// because the app needs a relaunch to pick up the exporter (#16).
    private var restartHint: String? {
        var who: [String] = []
        if store.status.vscodeConfigured && store.status.vscodeCount == 0 && !store.status.vscodeEverCaptured { who.append("VS Code") }
        if store.status.macAppConfigured && store.status.macAppCount == 0 && !store.status.macAppEverCaptured { who.append("the Copilot app") }
        guard !who.isEmpty else { return nil }
        let obj = who.count == 1 ? "it" : "them"
        return "Telemetry is on for \(who.joined(separator: " & ")) but no usage captured yet — quit & reopen \(obj), then use Copilot. It only starts on relaunch."
    }

    /// A source that HAS captured before but has gone quiet — the shape of "the
    /// app stopped exporting". Distinct from the never-captured case above:
    /// #21 rightly suppressed that nudge for existing users, which left this
    /// failure completely silent (#27). Worded conditionally because a user who
    /// simply hasn't used Copilot lately is indistinguishable from here.
    /// Banner shown when the Copilot app is running but has stopped writing
    /// telemetry — the total on screen is frozen and can't be trusted. Sits at
    /// the top, above the figure it's casting doubt on, and clears itself as
    /// soon as data flows again. (#27)
    @ViewBuilder private var exporterBanner: some View {
        if store.showExporterWarning {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(ExporterHealth.warningText)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.12))
        }
    }

    /// Status dot: green = data flowing, orange = configured but no traces yet,
    /// grey = telemetry not enabled.
    private func sourceBadge(_ name: String, found: Bool, configured: Bool, count: Int) -> some View {
        let color: Color = found ? .green : (configured ? .orange : Color.secondary.opacity(0.4))
        let label = found ? "\(name) · \(count)" : (configured ? "\(name) · waiting" : "\(name) · off")
        let help = found
            ? "\(name): \(count) usage records. Telemetry enabled."
            : (configured
               ? "\(name): telemetry enabled, but no traces yet — restart it and use Copilot."
               : "\(name): OTel telemetry not enabled — use the Enable… button below.")
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .help(help)
    }

    private var creditStatusColor: Color {
        guard store.serverUsageEnabled else { return Color.secondary.opacity(0.4) }
        if store.serverUsageError != nil { return .red }
        if store.serverUsageSample == nil || store.serverUsageIsStale { return .orange }
        return .green
    }
}

// ---------------------------------------------------------------------------
// Budget bar — spend vs budget for the SELECTED period. The budget is derived
// from the editable monthly budget, pro-rated across the days in the range.
// ---------------------------------------------------------------------------

struct BudgetBar: View {
    @EnvironmentObject var store: UsageStore
    let title: String
    let spentCredits: Double
    let budgetCredits: Double
    let monthlyBudget: Double

    var body: some View {
        let projection = store.spendProjection
        let hasBudget = budgetCredits > 0
        let over = hasBudget && spentCredits > budgetCredits
        let pct = hasBudget ? (spentCredits / budgetCredits) * 100 : 0
        let maxCredits = max(budgetCredits * 1.25, spentCredits, projection?.projectedCredits ?? 0, 1)
        let monthlyCredits = monthlyBudget * 100
        let wholePct = monthlyCredits > 0 ? (spentCredits / monthlyCredits) * 100 : 0

        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(store.budgetMoneyString(usd: monthlyBudget)) / mo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Monthly budget. Change it from the menu-bar icon’s right-click menu → “Set Monthly Budget…”.")
            }

            GeometryReader { geo in
                let w = geo.size.width
                let fillFrac = min(spentCredits, maxCredits) / maxCredits
                let limitFrac = budgetCredits / maxCredits
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    if let p = projection {
                        Capsule()
                            .fill((p.overBudget ? Color.red : Color.green).opacity(0.22))
                            .frame(width: max(0, w * (min(p.projectedCredits, maxCredits) / maxCredits)))
                    }
                    Capsule()
                        .fill(over ? Color.red : Color.green)
                        .frame(width: max(0, w * fillFrac))
                    if hasBudget {
                        Rectangle()
                            .fill(Color.orange)
                            .frame(width: 2, height: 14)
                            .offset(x: w * limitFrac - 1)
                    }
                }
            }
            .frame(height: 14)

            HStack(spacing: 5) {
                Text(store.costString(credits: spentCredits))
                    .monospacedDigit()
                    .foregroundStyle(over ? Color.red : Color.primary)
                Text("of")
                    .foregroundStyle(.secondary)
                Text(hasBudget ? store.costString(credits: budgetCredits) : "—")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text("budget")
                    .foregroundStyle(.secondary)
                if hasBudget {
                    Text(over
                         ? "(OVER by \(store.costString(credits: spentCredits - budgetCredits)))"
                         : String(format: "(%.0f%%)", pct))
                        .foregroundStyle(over ? Color.red : Color.secondary)
                        .monospacedDigit()
                }
                Spacer()
                if hasBudget {
                    Text(String(format: "%.0f%% of monthly budget", wholePct))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .font(.caption)

            if let p = projection {
                HStack(spacing: 5) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .foregroundStyle(p.overBudget ? Color.red : Color.secondary)
                    Text("Projected").foregroundStyle(.secondary)
                    Text(store.costString(credits: p.projectedCredits))
                        .monospacedDigit()
                        .foregroundStyle(p.overBudget ? Color.red : Color.primary)
                    Text("by \(p.endLabel)").foregroundStyle(.secondary)
                    if p.hasBudget {
                        Text(p.overBudget
                             ? "· over by \(store.costString(credits: p.projectedCredits - p.budgetCredits)) (\(String(format: "%.0f", p.pctOfBudget))%)"
                             : "· \(String(format: "%.0f", p.pctOfBudget))% of budget")
                            .foregroundStyle(p.overBudget ? Color.red : Color.secondary)
                            .monospacedDigit()
                    }
                    if p.daysElapsed < 3 {
                        Text("(early)").foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .font(.caption)
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Sparkline — a compact daily-credits bar chart for the selected period.
// ---------------------------------------------------------------------------

struct Sparkline: View {
    @EnvironmentObject var store: UsageStore
    let totals: [DayTotal]

    var body: some View {
        let maxVal = max(totals.map(\.credits).max() ?? 0, 0.0001)
        let hasData = totals.contains { $0.credits > 0 }
        GeometryReader { geo in
            if !hasData {
                Text("no data")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            } else {
                let count = totals.count
                let spacing: CGFloat = count > 40 ? 1 : 2
                let barW = max(1, (geo.size.width - CGFloat(count - 1) * spacing) / CGFloat(count))
                // One slot per day across the period; days with usage get a bar,
                // the rest are blank, so the strip fills up over the period.
                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(totals) { t in
                        if t.credits > 0 {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color.accentColor.opacity(0.85))
                                .frame(width: barW,
                                       height: max(1, geo.size.height * CGFloat(t.credits / maxVal)))
                                .help("\(t.day): \(store.costString(credits: t.credits))")
                        } else {
                            Color.clear.frame(width: barW, height: 1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
    }
}
