import AppKit
import SwiftUI
import Combine

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(CommandLine.arguments.contains("--regular") ? .regular : .accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "dollarsign.circle",
                                   accessibilityDescription: "Copilot usage")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.title = " " + store.menuBarTitle
            button.target = self
            button.action = #selector(statusButtonClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item

        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(
            rootView: DetailView().environmentObject(store)
        )
        popover.contentSize = desiredContentSize()

        // Keep the menu-bar title in sync with the selected period's total.
        store.$menuBarTitle
            .receive(on: RunLoop.main)
            .sink { [weak self] title in
                self?.statusItem.button?.title = " " + title
            }
            .store(in: &cancellables)

        updater.start()
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
        let updates = NSMenuItem(title: "Check for Updates", action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        menu.addItem(updates)
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

    @objc private func checkForUpdates() {
        Updater.checkNow()
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
            Task { await store.reload() }   // freshen on open
        }
    }

    /// Window size, clamped so it never exceeds the usable screen height.
    private func desiredContentSize() -> NSSize {
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        let available = (screen?.visibleFrame.height ?? 800) - 8
        return NSSize(width: 600, height: min(700, max(480, available)))
    }
}
