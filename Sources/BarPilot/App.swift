import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers

// ---------------------------------------------------------------------------
// Entry point. `@MainActor static main()` (the same shape SwiftUI's App uses)
// runs the bootstrap on the main actor. `--dump` short-circuits to the
// headless verification path; otherwise we boot an AppKit run loop.
// ---------------------------------------------------------------------------

@main
struct AppMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--dump") {
            Dump.run()
            exit(0)
        }
        // Dev-only: verify the versioned sync payload and legacy projection.
        if CommandLine.arguments.contains("--verify-sync") {
            SyncAggregate.verifySelfConsistency()
            exit(0)
        }
        // Dev-only: preview the combined view vs a simulated second machine.
        if CommandLine.arguments.contains("--sync-preview") {
            SyncAggregate.preview()
            exit(0)
        }
        // Dev-only: regression-check the spend projection math (#18).
        if CommandLine.arguments.contains("--verify-projection") {
            SpendProjection.verify()
            exit(0)
        }
        // Dev-only: exporter-heartbeat watchdog decision rules (#27).
        if CommandLine.arguments.contains("--verify-watchdog") {
            ExporterHealth.verify()
            exit(0)
        }
        // Dev-only: prove incremental JSONL reads never lose/duplicate a record (#24).
        if CommandLine.arguments.contains("--verify-incremental") {
            DataSources.verifyIncremental()
            exit(0)
        }
        // Dev-only: cumulative-counter reset, baseline and gap rules (#33).
        if CommandLine.arguments.contains("--verify-credits") {
            CreditReconciliation.verify()
            exit(0)
        }
        // Support report — state, a timed load, and the recent reload log (#24).
        if CommandLine.arguments.contains("--diagnose") {
            Diagnose.run()
            exit(0)
        }
        // `--regular` runs as a normal foreground (Dock) app instead of a
        // menu-bar-only agent — used for UI verification, since automation tools
        // don't bind LSUIElement agent apps.
        let regular = CommandLine.arguments.contains("--regular")
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(regular ? .regular : .accessory)
        app.run()
    }
}

// ---------------------------------------------------------------------------
// AppDelegate — owns the menu-bar status item and the popover that hosts the
// SwiftUI detail window.
//
// We use an explicit AppKit NSStatusItem (rather than SwiftUI's MenuBarExtra)
// because it is the reliable way to get a menu-bar item to appear from a
// SwiftPM-built, hand-assembled .app bundle. The window UI itself is still
// SwiftUI (DetailView), hosted in an NSPopover.
// ---------------------------------------------------------------------------

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = UsageStore()
    private let updater = Updater()

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()
    // Backup outside-click monitor: NSPopover(.transient) breaks after a native
    // NSMenu (the period Picker) runs its modal event loop. This global monitor
    // ensures clicks in other apps still close the popover in that case.
    private var outsideClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(CommandLine.arguments.contains("--regular") ? .regular : .accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "dollarsign.circle",
                                   accessibilityDescription: "Copilot usage")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.title = (Updater.isDevBuild ? " (D) " : " ") + store.menuBarTitle
            button.target = self
            button.action = #selector(statusButtonClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: DetailView { [weak self] in
                Task { await self?.runCreditUsageDeviceFlow() }
            }
            .environmentObject(store)
        )
        popover.contentSize = desiredContentSize()

        // Keep the menu-bar title in sync with the selected period's total.
        store.$menuBarTitle
            .receive(on: RunLoop.main)
            .sink { [weak self] title in
                self?.statusItem.button?.title = (Updater.isDevBuild ? " (D) " : " ") + title
            }
            .store(in: &cancellables)

        updater.start()
        Task.detached(priority: .background) {
            SpanCache.prune()
            CreditSampleStore.prune()
        }
    }

    /// Left-click toggles the window; right-click (or control-click) shows a menu.
    @objc private func statusButtonClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showContextMenu()
        } else {
            togglePopover(nil)
        }
    }

    private func showContextMenu() {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) }

        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Usage Window", action: #selector(openWindow), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        menu.addItem(.separator())
        let budget = NSMenuItem(title: "Set Monthly Budget (\(store.budgetMoneyString(usd: store.monthlyBudget)))…",
                                action: #selector(setBudget), keyEquivalent: "")
        budget.target = self
        menu.addItem(budget)

        let currency = NSMenuItem(title: "Currency", action: nil, keyEquivalent: "")
        let currencyMenu = NSMenu()
        for c in Currency.allCases {
            let item = NSMenuItem(title: c.menuLabel, action: #selector(setCurrency(_:)), keyEquivalent: "")
            item.target = self
            item.state = (store.displayCurrency == c) ? .on : .off
            item.representedObject = c.rawValue
            currencyMenu.addItem(item)
        }
        currency.submenu = currencyMenu
        menu.addItem(currency)
        menu.addItem(.separator())

        let login = NSMenuItem(title: "Start at Login", action: #selector(toggleStartAtLogin), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)
        let creditUsage = NSMenuItem(
            title: store.serverUsageEnabled ? "Disconnect GitHub" : "Connect GitHub…",
            action: #selector(toggleCreditUsage), keyEquivalent: ""
        )
        creditUsage.target = self
        creditUsage.isEnabled = !store.isConnectingServerUsage
        menu.addItem(creditUsage)
        let sync = NSMenuItem(title: "Multi-Machine Sync", action: #selector(toggleSync), keyEquivalent: "")
        sync.target = self
        sync.state = store.syncEnabled ? .on : .off
        menu.addItem(sync)
        let updates = NSMenuItem(title: "Check for Updates", action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        menu.addItem(updates)
        let whatsNew = NSMenuItem(title: "What’s New", action: #selector(showWhatsNew), keyEquivalent: "")
        whatsNew.target = self
        menu.addItem(whatsNew)
        let diagnostics = NSMenuItem(title: "Save Diagnostics…", action: #selector(saveDiagnostics), keyEquivalent: "")
        diagnostics.target = self
        diagnostics.toolTip = "Save a support report (timings and counts only — no code or prompts)."
        menu.addItem(diagnostics)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit BarPilot", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
    }

    @objc private func openWindow() {
        if !popover.isShown { togglePopover(nil) }
    }

    @objc private func refreshNow() {
        Task { await store.reload() }
    }

    @objc private func setBudget() {
        store.promptForBudget()
    }

    @objc private func setCurrency(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let c = Currency(rawValue: raw) else { return }
        store.displayCurrency = c
    }

    @objc private func toggleStartAtLogin() {
        LoginItem.toggle()
    }

    /// The primary GitHub connection is separate from gist sync, so disconnecting
    /// credit usage cannot silently disable multi-machine sync.
    @objc private func toggleCreditUsage() {
        if store.serverUsageEnabled {
            let a = NSAlert()
            a.messageText = "Disconnect GitHub?"
            a.informativeText = "BarPilot will stop refreshing the authoritative credit total and temporarily show incomplete local telemetry. Saved daily counter history and multi-machine sync remain untouched."
            a.addButton(withTitle: "Disconnect")
            a.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() == .alertFirstButtonReturn { store.disableServerUsage() }
        } else {
            Task { await runCreditUsageDeviceFlow() }
        }
    }

    /// Multi-machine sync: enable via GitHub device flow, or confirm-disable.
    @objc private func toggleSync() {
        if store.syncEnabled {
            let a = NSAlert()
            a.messageText = "Turn off multi-machine sync?"
            a.informativeText = "This Mac will stop using counter observations captured by your other Macs. Local history is untouched; the token is removed and cached remote data cleared. Your gist on GitHub is left in place."
            a.addButton(withTitle: "Turn Off")
            a.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() == .alertFirstButtonReturn { store.disableSync() }
        } else {
            Task { await runDeviceFlow() }
        }
    }

    /// Device-flow enable: fetch a code, show it, open GitHub, poll, then enable.
    private func runDeviceFlow() async {
        let dc: DeviceCode
        do { dc = try await GitHubBackend.requestDeviceCode() }
        catch { showInfo("Couldn't start sync", "Couldn't reach GitHub to begin authorization."); return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(dc.userCode, forType: .string)
        let a = NSAlert()
        a.messageText = "Turn on multi-machine sync?"
        a.informativeText = """
        Turn this on only if both of these are true:

        1.  You run Copilot on more than one Mac.
        2.  Your GitHub account can create gists.

        Most work or enterprise accounts have gists disabled, so sync won’t work with those — a gist is where the data is stored. BarPilot shares compact cumulative credit observations so one Mac can fill another Mac’s offline gaps. During the legacy transition it also retains the existing daily telemetry summary. No code, prompts, or content are uploaded. Every Mac must use the same account.

        Open GitHub and enter the code below (already copied to your clipboard). It finishes on its own once you approve.
        """
        a.accessoryView = deviceCodeView(dc.userCode)
        a.addButton(withTitle: "Open GitHub")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        if let u = URL(string: dc.verificationUri) { NSWorkspace.shared.open(u) }

        do {
            let token = try await GitHubBackend.pollForToken(deviceCode: dc.deviceCode, interval: dc.interval, expiresIn: dc.expiresIn)
            let n = await store.enableSyncWith(token: token)
            let who = store.syncLogin.map { "@\($0)" } ?? "your account"
            if let err = store.syncError {
                showInfo("Sync couldn’t start", "Authorized as \(who), but it isn’t working:\n\n\(err)")
            } else {
                showInfo("Sync enabled", "Authorized as \(who). \(n) machine\(n == 1 ? "" : "s") contributing so far. If that’s not the account you meant, turn sync off and re-enable.")
            }
        } catch {
            showInfo("Sync not enabled", "Authorization didn't complete. You can try again from the menu.")
        }
    }

    private func runCreditUsageDeviceFlow() async {
        guard store.beginServerUsageConnection() else { return }
        defer { store.endServerUsageConnection() }

        let dc: DeviceCode
        do { dc = try await GitHubBackend.requestDeviceCode(scope: "read:user") }
        catch {
            showInfo("Couldn’t connect GitHub", "Couldn’t reach GitHub to begin authorization.")
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(dc.userCode, forType: .string)
        let a = NSAlert()
        a.messageText = "Connect BarPilot to GitHub?"
        a.informativeText = """
        BarPilot will read your account’s Copilot credit counter once a minute and save cumulative samples locally. This provides the current billing-cycle total, costs, budget progress, and daily usage.

        GitHub returns the cumulative credit total, reset date, and timestamp. BarPilot does not request or send prompts, code, sessions, or model details.

        Open GitHub and enter the code below (already copied to your clipboard). It finishes on its own once you approve.
        """
        a.accessoryView = deviceCodeView(dc.userCode)
        a.addButton(withTitle: "Open GitHub")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        if let u = URL(string: dc.verificationUri) { NSWorkspace.shared.open(u) }

        do {
            let token = try await GitHubBackend.pollForToken(
                deviceCode: dc.deviceCode, interval: dc.interval, expiresIn: dc.expiresIn)
            if await store.enableServerUsageWith(token: token) {
                showInfo("GitHub connected", "BarPilot is now using GitHub’s current billing-cycle credit counter.")
            } else {
                showInfo("GitHub couldn’t connect", store.serverUsageError ?? "GitHub did not return a usable credit total.")
            }
        } catch {
            showInfo("GitHub not connected", "Authentication didn’t complete. You can try again from the usage window.")
        }
    }

    private func showInfo(_ title: String, _ body: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    /// A prominent, selectable display of the device code for the enable dialog.
    private func deviceCodeView(_ code: String) -> NSView {
        let field = NSTextField(labelWithString: code)
        field.font = NSFont.monospacedSystemFont(ofSize: 24, weight: .semibold)
        field.alignment = .center
        field.isSelectable = true
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 40)
        return field
    }

    @objc private func checkForUpdates() {
        Updater.checkNow()
    }

    @objc private func showWhatsNew() {
        if let u = URL(string: "https://github.com/vmlrodrigues/BarPilot/blob/main/CHANGELOG.md") {
            NSWorkspace.shared.open(u)
        }
    }

    /// Save the same report as `--diagnose` to a file the user can send. Building
    /// it runs a load, so do that off the main actor and keep the UI responsive.
    /// The save panel states what's inside so sharing is an informed choice (#31).
    @objc private func saveDiagnostics() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.title = "Save BarPilot Diagnostics"
        panel.message = "Contains timings, counts and file sizes only — no code, prompts, or account details. Safe to share."
        panel.nameFieldStringValue = "barpilot-diagnose-\(Fmt.fileStamp(Date())).txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task { @MainActor in
            let text = await Task.detached(priority: .userInitiated) { Diagnose.report() }.value
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                NSWorkspace.shared.activateFileViewerSelecting([url])   // reveal in Finder
            } catch {
                let a = NSAlert()
                a.alertStyle = .warning
                a.messageText = "Couldn’t save diagnostics"
                a.informativeText = error.localizedDescription
                a.runModal()
            }
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            // Re-clamp to the current screen so the window always fits below the
            // menu bar (the status item sits at the very top of the screen).
            popover.contentSize = desiredContentSize()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
            installOutsideClickMonitor()
            Task { await store.reload() }   // freshen on open
        }
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self, self.popover.isShown else { return }
            self.popover.performClose(nil)
        }
    }

    private func removeOutsideClickMonitor() {
        if let m = outsideClickMonitor {
            NSEvent.removeMonitor(m)
            outsideClickMonitor = nil
        }
    }

    /// Window size, clamped so it never exceeds the usable screen height.
    private func desiredContentSize() -> NSSize {
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        let available = (screen?.visibleFrame.height ?? 800) - 8
        return NSSize(width: 600, height: min(700, max(480, available)))
    }
}

// MARK: - NSPopoverDelegate

extension AppDelegate: NSPopoverDelegate {
    /// Called whenever the popover closes (transient auto-close, our backup
    /// monitor, or the status-bar button toggle). Always clean up the monitor.
    func popoverDidClose(_ notification: Notification) {
        removeOutsideClickMonitor()
    }
}
