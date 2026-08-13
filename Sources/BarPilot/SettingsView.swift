import SwiftUI
import AppKit

// ---------------------------------------------------------------------------
// SettingsView — the single place configuration lives.
//
// The right-click menu keeps only actions (open, refresh, updates, what's new,
// diagnostics, quit). Anything that changes how BarPilot behaves moves here, so
// a setting has one home instead of being half-menu, half-dialog. The window is
// a real NSWindow rather than a popover: the popover is `.transient` and closes
// the moment a sheet, alert or save panel takes focus, which every one of these
// controls does.
// ---------------------------------------------------------------------------

/// Actions the settings window needs from the AppDelegate, which owns the
/// device flows, alerts and panels.
struct SettingsActions {
    var connectGitHub: () -> Void
    var disconnectGitHub: () -> Void
    var toggleSync: () -> Void
    var checkForUpdates: () -> Void
    var saveDiagnostics: () -> Void
}

struct SettingsView: View {
    @EnvironmentObject var store: UsageStore
    let actions: SettingsActions

    @State private var budgetText: String = ""
    @State private var budgetError: String?
    @State private var startAtLogin: Bool = LoginItem.isEnabled

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                budgetSection
                Divider()
                currencySection
                Divider()
                accountSection
                Divider()
                generalSection
            }
            .padding(20)
        }
        .frame(width: 460)
        .frame(minHeight: 600, maxHeight: 760)
        .onAppear { budgetText = currentBudgetText }
        // The budget is stored in USD, so switching currency must restate the
        // field in the newly selected one rather than leave a stale number.
        .onChange(of: store.displayCurrency) { _ in budgetText = currentBudgetText }
        .onChange(of: store.usdToAUD) { _ in budgetText = currentBudgetText }
    }

    // -- Budget --------------------------------------------------------------

    private var budgetSection: some View {
        section("Monthly budget", "Your Copilot spend target per month. It is pro-rated across the days in the period being shown.") {
            HStack(spacing: 8) {
                Text(store.effectiveCurrency.symbol)
                    .foregroundStyle(.secondary)
                BudgetField(text: $budgetText, onCommit: commitBudget)
                    .frame(width: 120, height: 22)
                Text("per month")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Set", action: commitBudget)
                    .disabled(budgetText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let budgetError {
                Text(budgetError).font(.caption).foregroundStyle(.red)
            } else if store.effectiveCurrency == .aud {
                Text("Stored as \(Fmt.money(store.monthlyBudget)) US and converted for display, so the target doesn't move when the exchange rate does.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
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

    // -- Currency ------------------------------------------------------------

    private var currencySection: some View {
        section("Currency", "Sets the currency used in the menu bar and throughout the usage window. You can also switch this by clicking a currency card in the usage window.") {
            Picker("", selection: $store.displayCurrency) {
                ForEach(Currency.allCases, id: \.self) { c in
                    Text(c.menuLabel).tag(c)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if store.displayCurrency == .aud && store.usdToAUD == nil {
                Text("Showing US dollars until an exchange rate loads.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    // -- Account -------------------------------------------------------------

    private var accountSection: some View {
        section("GitHub", "BarPilot reads your account-wide credit total from GitHub. Without it the figure is estimated from local telemetry and reads low.") {
            HStack(spacing: 10) {
                Image(systemName: store.serverUsageEnabled
                      ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(store.serverUsageEnabled ? .green : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.serverUsageEnabled ? "Connected" : "Not connected")
                        .font(.subheadline.weight(.medium))
                    if let error = store.serverUsageError {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                if store.isConnectingServerUsage {
                    ProgressView().controlSize(.small)
                } else if store.serverUsageEnabled {
                    Button("Disconnect", action: actions.disconnectGitHub)
                } else {
                    Button("Connect…", action: actions.connectGitHub)
                        .buttonStyle(.borderedProminent)
                }
            }

            Toggle(isOn: Binding(
                get: { store.syncEnabled },
                set: { _ in actions.toggleSync() }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Multi-machine sync")
                    Text(syncDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            if let error = store.syncError {
                Text(error).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
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

    // -- General -------------------------------------------------------------

    private var generalSection: some View {
        section("General", nil) {
            Toggle(isOn: Binding(
                get: { startAtLogin },
                set: { _ in
                    LoginItem.toggle()
                    // Reflect what the system actually did: registration can be
                    // refused, and a switch that lies is worse than no switch.
                    startAtLogin = LoginItem.isEnabled
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start at login")
                    Text("Open BarPilot automatically when you log in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            HStack(spacing: 10) {
                Button("Check for Updates", action: actions.checkForUpdates)
                Button("Save Diagnostics…", action: actions.saveDiagnostics)
                    .help("Save a support report — timings and counts only, no code, prompts or account details.")
                Spacer()
            }
            Text("BarPilot \(Updater.currentVersion())\(Updater.isDevBuild ? " (development build — auto-update disabled)" : "")")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // -- Layout --------------------------------------------------------------

    @ViewBuilder
    private func section<Content: View>(
        _ title: String, _ subtitle: String?, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    final class Coordinator: NSObject, NSTextFieldDelegate {
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
