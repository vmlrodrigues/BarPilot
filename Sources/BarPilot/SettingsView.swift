import SwiftUI
import AppKit

// ---------------------------------------------------------------------------
// SettingsView — the single place configuration lives.
//
// The right-click menu keeps only actions (open, refresh, updates, what's new,
// diagnostics, quit). Anything that changes how BarPilot behaves moves here, so
// a setting has one home instead of being half-menu, half-dialog. The window is
// a real NSWindow rather than a popover, giving sheets, alerts and save panels
// an independent presentation hierarchy.
// ---------------------------------------------------------------------------

/// Actions the settings window needs from the AppDelegate, which owns the
/// device flows, alerts and panels.
struct SettingsActions {
    var close: () -> Void
    var connectGitHub: () -> Void
    var disconnectGitHub: () -> Void
    var toggleSync: () -> Void
    var checkForUpdates: () -> Void
    var saveDiagnostics: () -> Void
}

private enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case spending
    case github
    case support

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .spending: return "Spending"
        case .github: return "GitHub"
        case .support: return "Updates & Support"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "Control how BarPilot starts and how quickly you can reach it."
        case .spending: return "Choose the currency you see and the budget you want to track."
        case .github: return "Manage the account used for usage data and optional cross-device sync."
        case .support: return "Keep BarPilot current or collect information for troubleshooting."
        }
    }

    var symbol: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .spending: return "creditcard"
        case .github: return "person.crop.circle"
        case .support: return "lifepreserver"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: UsageStore
    let actions: SettingsActions
    @ObservedObject var shortcutController: GlobalShortcutController

    @State private var budgetText: String = ""
    @State private var budgetError: String?
    @State private var startAtLogin: Bool = LoginItem.isEnabled
    @State private var selectedPane: SettingsPane = .general

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selectedPane.title)
                            .font(.system(size: 22, weight: .semibold))
                        Text(selectedPane.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Done", action: actions.close)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
                selectedPaneContent
                Spacer(minLength: 0)
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 740, height: 470)
        .onAppear {
            budgetText = currentBudgetText
            startAtLogin = LoginItem.isEnabled
        }
        // The budget is stored in USD, so switching currency must restate the
        // field in the newly selected one rather than leave a stale number.
        .onChange(of: store.displayCurrency) { _ in budgetText = currentBudgetText }
        .onChange(of: store.usdToAUD) { _ in budgetText = currentBudgetText }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.gradient)
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 0) {
                    Text("BarPilot").font(.subheadline.weight(.semibold))
                    Text("Copilot usage monitor")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)

            ForEach(SettingsPane.allCases) { pane in
                Button {
                    selectedPane = pane
                } label: {
                    Label(pane.title, systemImage: pane.symbol)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedPane == pane ? Color.primary : Color.secondary)
                .background(
                    selectedPane == pane ? Color.primary.opacity(0.08) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7)
                )
            }

            Spacer()
            Text("BarPilot \(Updater.currentVersion())\(Updater.isDevBuild ? " · Development" : "")")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
        }
        .padding(12)
        .frame(width: 190)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.025))
    }

    @ViewBuilder
    private var selectedPaneContent: some View {
        switch selectedPane {
        case .general: generalPane
        case .spending: spendingPane
        case .github: githubPane
        case .support: supportPane
        }
    }

    /// A label-plus-switch row where the switch always sits hard right, so the
    /// switches line up regardless of how long each label runs.
    private func switchRow(
        _ title: String, _ detail: String?, isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(14)
    }

    private var spendingPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsGroup {
                VStack(spacing: 0) {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Display currency")
                            Text("Used consistently across the dashboard, forecasts and model prices.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("Display currency", selection: $store.displayCurrency) {
                            ForEach(Currency.allCases, id: \.self) { currency in
                                Text(currency.code).tag(currency)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 132)
                    }
                    .padding(14)

                    Divider().padding(.leading, 14)

                    HStack(alignment: .center, spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Monthly budget")
                            Text(budgetDetail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        HStack(spacing: 7) {
                            Text(store.effectiveCurrency.symbol)
                                .foregroundStyle(.secondary)
                            BudgetField(text: $budgetText, onCommit: commitBudget)
                                .frame(width: 92, height: 22)
                            Button("Set", action: commitBudget)
                                .disabled(budgetText.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    .padding(14)

                    Divider().padding(.leading, 14)

                    switchRow(
                        "Exclude weekends from the forecast",
                        "Project future spend across working days only. Weekend spend already made still counts.",
                        isOn: $store.excludeWeekendsFromProjection
                    )
                }
            }

            if let budgetError {
                statusNote(budgetError, color: .red)
            } else if let persistenceError = store.budgetPersistenceError {
                statusNote(persistenceError, color: .red)
            } else if store.displayCurrency == .aud && store.usdToAUD == nil {
                statusNote("Showing US dollars until an exchange rate loads.", color: .orange)
            }
        }
    }

    private var budgetDetail: String {
        if store.effectiveCurrency == .aud {
            return "Stored as \(Fmt.money(store.monthlyBudget)) US and converted for display so the target remains stable."
        }
        return "Your Copilot spend target, pro-rated for the period being shown."
    }

    private var currentBudgetText: String {
        if store.effectiveCurrency == .aud, let rate = store.usdToAUD {
            return String(Int((store.monthlyBudget * rate).rounded()))
        }
        return Fmt.money(store.monthlyBudget).replacingOccurrences(of: "$", with: "")
    }

    private func commitBudget() {
        switch BudgetInput.parse(budgetText) {
        case .invalid:
            budgetError = "Enter a number, for example 500."
        case .tooLarge:
            budgetError = "That looks like a typo — the maximum is \(store.effectiveCurrency.symbol)\(BudgetInput.maximumText)."
        case .ok(let value):
            budgetError = nil
            if store.effectiveCurrency == .aud, let rate = store.usdToAUD, rate > 0 {
                store.monthlyBudget = value / rate  // entered AUD → canonical USD
            } else {
                store.monthlyBudget = value
            }
            budgetText = currentBudgetText
        }
    }

    private var githubPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsGroup {
                VStack(spacing: 0) {
                    HStack(spacing: 11) {
                        Image(systemName: store.serverUsageEnabled
                              ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.title3)
                            .foregroundStyle(store.serverUsageEnabled ? .green : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.serverUsageEnabled ? "GitHub connected" : "GitHub not connected")
                                .font(.subheadline.weight(.medium))
                            Text(store.serverUsageError
                                 ?? "Account-wide credit usage is used for the authoritative total.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if store.isConnectingServerUsage {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Button("Cancel") { store.cancelServerUsageConnection() }
                            }
                        } else if store.serverUsageEnabled {
                            Button("Disconnect", action: actions.disconnectGitHub)
                        } else {
                            Button("Connect…", action: actions.connectGitHub)
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(14)

                    Divider().padding(.leading, 14)

                    switchRow("Multi-machine sync", syncDetail, isOn: Binding(
                        get: { store.syncEnabled },
                        set: { _ in actions.toggleSync() }
                    ))
                }
            }
            if let error = store.syncError {
                statusNote(error, color: .orange)
            }
            infoNote(
                symbol: "lock.shield",
                text: "Sync stores usage totals only. Credentials remain in the macOS Keychain."
            )
        }
    }

    private var syncDetail: String {
        guard store.syncEnabled else {
            return "Turn on only if you run Copilot on more than one Mac. Stores readings in a secret GitHub gist — no iCloud, no code or prompts."
        }
        // counterSyncMachineCount includes this Mac.
        let others = max(0, store.counterSyncMachineCount - 1)
        let who = store.syncLogin.map { "@\($0)" } ?? "your account"
        return "Authorized as \(who). \(others) other Mac\(others == 1 ? "" : "s") contributing readings."
    }

    private var generalPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsGroup {
                VStack(spacing: 0) {
                    switchRow(
                        "Start at login",
                        "Open BarPilot automatically when you log in.",
                        isOn: Binding(
                            get: { startAtLogin },
                            set: { _ in
                                LoginItem.toggle()
                                startAtLogin = LoginItem.isEnabled
                            }
                        )
                    )

                    Divider().padding(.leading, 14)

                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Usage window shortcut")
                            Text("Show or hide BarPilot from any app. Use at least two modifiers.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        ShortcutRecorder(
                            shortcut: shortcutController.pendingShortcut
                                ?? shortcutController.shortcut,
                            isRecording: shortcutController.isRecording,
                            beginRecording: shortcutController.beginRecording,
                            cancelRecording: shortcutController.cancelRecording,
                            assign: shortcutController.assign,
                            reportInvalid: shortcutController.reportInvalidCombination
                        )
                        .frame(width: 132, height: 24)
                        Button("Clear") { shortcutController.clear() }
                            .disabled(
                                shortcutController.shortcut == nil
                                    || shortcutController.isRecording
                            )
                    }
                    .padding(14)
                }
            }

            if let message = shortcutController.confirmationMessage {
                statusNote(message, color: .blue)
            } else if let error = shortcutController.errorMessage {
                statusNote(error, color: .orange)
            }
            infoNote(
                symbol: "menubar.rectangle",
                text: "BarPilot remains a menu-bar app. Starting it at login does not add a Dock icon."
            )
        }
    }

    private var supportPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsGroup {
                VStack(spacing: 0) {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Software updates")
                            Text("You are running BarPilot \(Updater.currentVersion())\(Updater.isDevBuild ? " (development build)." : ".")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Check for Updates", action: actions.checkForUpdates)
                    }
                    .padding(14)

                    Divider().padding(.leading, 14)

                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Diagnostics")
                            Text("Save a support report you can inspect before sharing.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Save Diagnostics…", action: actions.saveDiagnostics)
                            .help("Save timings and counts only — no code, prompts or account details.")
                    }
                    .padding(14)
                }
            }
            infoNote(
                symbol: "lock.doc",
                text: "Diagnostic exports omit credentials, monetary figures and credit totals."
            )
        }
    }

    @ViewBuilder
    private func settingsGroup<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.secondary.opacity(0.18))
            }
    }

    private func infoNote(symbol: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: 16)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
    }

    private func statusNote(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 2)
    }
}

// ---------------------------------------------------------------------------
// BudgetInput — parsing kept out of the view so it can be verified headlessly.
// The budget feeds the budget bar and the spend projection, so a value accepted
// here that shouldn't be silently distorts both with nothing on screen to
// explain it.
// ---------------------------------------------------------------------------

enum BudgetInput: Equatable {
    case ok(Double)
    case invalid
    case tooLarge

    /// A monthly spend target in the millions is a typo, not an intention —
    /// most often a mistyped entry appended to the existing figure.
    static let maximum: Double = 1_000_000

    /// Grouped for display so the ceiling in the error message is legible.
    static var maximumText: String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: maximum)) ?? "\(Int(maximum))"
    }

    static func parse(_ raw: String) -> BudgetInput {
        let cleaned = raw
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "A$", with: "")
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard !cleaned.isEmpty, let value = Double(cleaned),
              value.isFinite, value >= 0 else { return .invalid }
        guard value <= maximum else { return .tooLarge }
        return .ok(value)
    }

    static func verify(_ check: (String, Bool) -> Void) {
        check("plain number", parse("500") == .ok(500))
        check("decimal", parse("706.44") == .ok(706.44))
        check("currency symbols stripped", parse("A$1,000") == .ok(1000))
        check("dollar sign stripped", parse(" $150 ") == .ok(150))
        check("zero allowed", parse("0") == .ok(0))
        check("empty rejected", parse("") == .invalid)
        check("text rejected", parse("abc") == .invalid)
        check("negative rejected", parse("-5") == .invalid)
        check("infinity rejected", parse("inf") == .invalid)
        // The regression: a mistyped entry appended to the existing figure.
        check("fat-fingered millions rejected", parse("12001000") == .tooLarge)
        check("at the ceiling is allowed", parse("1000000") == .ok(1_000_000))
    }
}

// ---------------------------------------------------------------------------
// BudgetField — AppKit-backed so focusing it selects the whole value.
//
// SwiftUI's TextField places the caret from the click after it reports focus, so
// a typed figure lands next to the existing one (1000 + 1200 => 12001000) and
// the mistake is easy to miss. NSTextField.selectText(_:) on becoming first
// responder is deterministic, which a deferred selectAll on the field editor is
// not.
// ---------------------------------------------------------------------------

struct BudgetField: NSViewRepresentable {
    @Binding var text: String
    var onCommit: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = SelectAllTextField(string: text)
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.commit(_:))
        field.alignment = .right
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.bezelStyle = .roundedBezel
        field.isBezeled = true
        field.focusRingType = .default
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        // Push down only changes that originated outside the field (currency
        // switch, commit restating the stored value). Keying off
        // currentEditor() instead would skip the initial value, because the
        // field takes first responder as the window opens.
        guard text != coordinator.lastSeenText else { return }
        coordinator.lastSeenText = text
        if field.stringValue != text {
            field.stringValue = text
            if field.currentEditor() != nil { field.currentEditor()?.selectAll(nil) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: BudgetField
        /// Last value seen on the binding, so updateNSView can tell an external
        /// change from an echo of the user's own typing.
        var lastSeenText: String
        init(_ parent: BudgetField) {
            self.parent = parent
            self.lastSeenText = parent.text
        }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            lastSeenText = field.stringValue
            parent.text = field.stringValue
        }

        @objc func commit(_ sender: NSTextField) {
            lastSeenText = sender.stringValue
            parent.text = sender.stringValue
            parent.onCommit()
        }
    }
}

private final class SelectAllTextField: NSTextField {
    init(string: String) {
        super.init(frame: .zero)
        stringValue = string
        isEditable = true
        isSelectable = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { currentEditor()?.selectAll(self) }
        return ok
    }
}
