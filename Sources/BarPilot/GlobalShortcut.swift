import AppKit
import Carbon
import Combine
import SwiftUI

struct GlobalShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifierFlagsRawValue: UInt64
    let keyLabel: String

    private static let allowedModifiers: NSEvent.ModifierFlags = [
        .control, .option, .shift, .command
    ]

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: UInt(modifierFlagsRawValue))
            .intersection(Self.allowedModifiers)
    }

    var displayName: String {
        var result = ""
        if modifierFlags.contains(.control) { result += "⌃" }
        if modifierFlags.contains(.option) { result += "⌥" }
        if modifierFlags.contains(.shift) { result += "⇧" }
        if modifierFlags.contains(.command) { result += "⌘" }
        return result + keyLabel
    }

    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if modifierFlags.contains(.command) { result |= UInt32(cmdKey) }
        if modifierFlags.contains(.option) { result |= UInt32(optionKey) }
        if modifierFlags.contains(.control) { result |= UInt32(controlKey) }
        if modifierFlags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    static func capture(from event: NSEvent) -> GlobalShortcut? {
        guard let label = keyLabel(for: event) else { return nil }
        return validated(
            keyCode: UInt32(event.keyCode),
            modifiers: event.modifierFlags,
            keyLabel: label
        )
    }

    static func validated(
        keyCode: UInt32,
        modifiers: NSEvent.ModifierFlags,
        keyLabel: String
    ) -> GlobalShortcut? {
        let normalized = modifiers.intersection(allowedModifiers)
        let modifierCount = [
            NSEvent.ModifierFlags.control,
            .option,
            .shift,
            .command
        ].filter(normalized.contains).count
        guard keyCode <= 127,
              modifierCount >= 2,
              normalized.contains(.command)
                || normalized.contains(.option)
                || normalized.contains(.control),
              !keyLabel.isEmpty,
              keyLabel.count <= 8 else {
            return nil
        }
        return GlobalShortcut(
            keyCode: keyCode,
            modifierFlagsRawValue: UInt64(normalized.rawValue),
            keyLabel: keyLabel
        )
    }

    private static func keyLabel(for event: NSEvent) -> String? {
        if let special = specialKeyLabels[event.keyCode] { return special }
        guard let characters = event.charactersIgnoringModifiers,
              !characters.isEmpty else {
            return nil
        }
        return characters.uppercased()
    }

    private static let specialKeyLabels: [UInt16: String] = [
        36: "↩",
        48: "⇥",
        49: "Space",
        64: "F17",
        71: "Clear",
        76: "⌤",
        79: "F18",
        80: "F19",
        90: "F20",
        96: "F5",
        97: "F6",
        98: "F7",
        99: "F3",
        100: "F8",
        101: "F9",
        105: "F13",
        106: "F16",
        107: "F14",
        103: "F11",
        109: "F10",
        111: "F12",
        113: "F15",
        118: "F4",
        120: "F2",
        122: "F1",
        123: "←",
        124: "→",
        125: "↓",
        126: "↑"
    ]

    @MainActor
    static func verify() {
        var pass = 0
        var fail = 0
        var defaultsSuites: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            if condition() {
                pass += 1
            } else {
                fail += 1
                FileHandle.standardError.write(Data("FAIL: \(name)\n".utf8))
            }
        }
        func isolatedDefaults() -> UserDefaults {
            let suite = "BarPilotShortcutVerify.\(UUID().uuidString)"
            defaultsSuites.append(suite)
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            return defaults
        }

        let valid = validated(
            keyCode: 11,
            modifiers: [.control, .option],
            keyLabel: "B"
        )
        check(valid?.displayName == "⌃⌥B", "display uses standard modifier order")
        check(
            valid?.carbonModifiers == UInt32(controlKey | optionKey),
            "modifiers translate to Carbon"
        )
        check(
            validated(keyCode: 11, modifiers: [.command], keyLabel: "B") == nil,
            "single modifier rejected"
        )
        check(
            validated(keyCode: 11, modifiers: [.shift, .command], keyLabel: "B") != nil,
            "two modifiers accepted"
        )
        check(
            validated(keyCode: 11, modifiers: [.shift, .capsLock], keyLabel: "B") == nil,
            "shift plus ignored device flag rejected"
        )
        check(
            validated(keyCode: 200, modifiers: [.control, .option], keyLabel: "B") == nil,
            "invalid virtual key rejected"
        )
        if let valid,
           let data = try? JSONEncoder().encode(valid),
           let decoded = try? JSONDecoder().decode(GlobalShortcut.self, from: data) {
            check(decoded == valid, "persistence round trip")
        } else {
            check(false, "persistence round trip")
        }
        let registrationProbe = validated(
            keyCode: 90,
            modifiers: [.control, .option, .shift, .command],
            keyLabel: "F20"
        )
        check(registrationProbe != nil, "registration probe is valid")
        // Carbon registration depends on an interactive WindowServer session.
        // Keep it available as an explicit local integration probe, while the
        // default verification remains deterministic on headless CI runners.
        if ProcessInfo.processInfo.environment["BARPILOT_VERIFY_LIVE_SHORTCUT"] == "1",
           let registrationProbe {
            let first = GlobalHotKeyRegistrar()
            let second = GlobalHotKeyRegistrar()
            let firstStatus = first.register(registrationProbe, identifier: 1)
            check(firstStatus == noErr, "Carbon registers a valid shortcut")
            if firstStatus == noErr {
                check(
                    second.register(registrationProbe, identifier: 2)
                        == eventHotKeyExistsErr,
                    "Carbon reports shortcut conflicts"
                )
                first.unregister()
                check(
                    second.register(registrationProbe, identifier: 3) == noErr,
                    "Carbon registration succeeds after unregister"
                )
                second.unregister()
            }
        }

        let previous = valid!
        let candidate = validated(
            keyCode: 8,
            modifiers: [.shift, .command],
            keyLabel: "C"
        )!
        let rollbackDefaults = isolatedDefaults()
        rollbackDefaults.set(
            try? JSONEncoder().encode(previous),
            forKey: GlobalShortcutController.defaultsKey
        )
        let rollbackRegistrar = FakeGlobalHotKeyRegistrar(statuses: [
            OSStatus(eventHotKeyExistsErr), noErr
        ])
        let rollback = GlobalShortcutController(
            action: {},
            registrar: rollbackRegistrar,
            defaults: rollbackDefaults
        )
        rollback.beginRecording()
        rollback.assign(candidate)
        check(rollback.shortcut == previous, "failed replacement keeps previous shortcut")
        check(
            rollbackRegistrar.registered == [candidate, previous],
            "failed replacement re-registers previous shortcut"
        )

        let timeoutDefaults = isolatedDefaults()
        timeoutDefaults.set(
            try? JSONEncoder().encode(previous),
            forKey: GlobalShortcutController.defaultsKey
        )
        let timeoutRegistrar = FakeGlobalHotKeyRegistrar(statuses: [noErr, noErr])
        let timeout = GlobalShortcutController(
            action: {},
            registrar: timeoutRegistrar,
            defaults: timeoutDefaults
        )
        timeout.beginRecording()
        timeout.assign(candidate)
        check(timeout.pendingShortcut == candidate, "candidate waits for delivery confirmation")
        let timedOutIdentifier = timeoutRegistrar.identifiers.last!
        timeout.confirmationTimedOut(
            expected: candidate,
            registrationIdentifier: timedOutIdentifier
        )
        check(timeout.shortcut == previous, "undelivered candidate restores previous shortcut")
        check(timeout.pendingShortcut == nil, "timeout clears pending candidate")

        let confirmationDefaults = isolatedDefaults()
        let confirmationRegistrar = FakeGlobalHotKeyRegistrar(statuses: [noErr])
        var invoked = false
        let confirmation = GlobalShortcutController(
            action: { invoked = true },
            registrar: confirmationRegistrar,
            defaults: confirmationDefaults
        )
        confirmation.beginRecording()
        confirmation.assign(candidate)
        confirmationRegistrar.trigger(identifier: confirmationRegistrar.identifiers.last!)
        check(confirmation.shortcut == candidate, "delivered candidate becomes active")
        check(invoked, "confirmed shortcut invokes usage window action")
        let persisted = confirmationDefaults
            .data(forKey: GlobalShortcutController.defaultsKey)
            .flatMap { try? JSONDecoder().decode(GlobalShortcut.self, from: $0) }
        check(persisted == candidate, "only confirmed candidate is persisted")

        let staleDefaults = isolatedDefaults()
        let staleRegistrar = FakeGlobalHotKeyRegistrar(statuses: [noErr, noErr])
        let stale = GlobalShortcutController(
            action: {},
            registrar: staleRegistrar,
            defaults: staleDefaults
        )
        stale.beginRecording()
        stale.assign(candidate)
        let staleIdentifier = staleRegistrar.identifiers.last!
        stale.beginRecording()
        stale.assign(candidate)
        let currentIdentifier = staleRegistrar.identifiers.last!
        stale.confirmationTimedOut(
            expected: candidate,
            registrationIdentifier: staleIdentifier
        )
        staleRegistrar.trigger(identifier: staleIdentifier)
        check(stale.pendingShortcut == candidate, "stale work cannot alter newer attempt")
        staleRegistrar.trigger(identifier: currentIdentifier)
        check(stale.shortcut == candidate, "current registration confirms newer attempt")
        for suite in defaultsSuites {
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }

        FileHandle.standardError.write(Data(
            "verify-shortcut: \(fail == 0 ? "PASS" : "FAIL") — \(pass) ok, \(fail) failed\n".utf8
        ))
        if fail > 0 { exit(1) }
    }
}

protocol GlobalHotKeyRegistering: AnyObject {
    var onPress: (@MainActor (UInt32) -> Void)? { get set }
    func register(_ shortcut: GlobalShortcut, identifier: UInt32) -> OSStatus
    func unregister()
}

@MainActor
final class GlobalShortcutController: ObservableObject {
    @Published private(set) var shortcut: GlobalShortcut?
    @Published private(set) var pendingShortcut: GlobalShortcut?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRecording = false

    fileprivate static let defaultsKey = "globalUsageWindowShortcut"
    private static let confirmationTimeoutNanoseconds: UInt64 = 8_000_000_000

    private let registrar: GlobalHotKeyRegistering
    private let defaults: UserDefaults
    private let action: @MainActor () -> Void
    private var confirmationTask: Task<Void, Never>?
    private var nextRegistrationIdentifier: UInt32 = 0
    private var activeRegistrationIdentifier: UInt32?
    private var pendingRegistrationIdentifier: UInt32?

    var confirmationMessage: String? {
        pendingShortcut.map {
            "Press \($0.displayName) again to confirm BarPilot receives it."
        }
    }

    init(
        action: @escaping @MainActor () -> Void,
        registrar: GlobalHotKeyRegistering? = nil,
        defaults: UserDefaults = .standard
    ) {
        let registrar = registrar ?? GlobalHotKeyRegistrar()
        self.registrar = registrar
        self.defaults = defaults
        self.action = action
        registrar.onPress = { [weak self] identifier in
            self?.hotKeyPressed(registrationIdentifier: identifier)
        }
        if let data = defaults.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode(GlobalShortcut.self, from: data),
           GlobalShortcut.validated(
               keyCode: saved.keyCode,
               modifiers: saved.modifierFlags,
               keyLabel: saved.keyLabel
           ) == saved {
            shortcut = saved
        }
    }

    func start() {
        guard let shortcut else { return }
        if register(shortcut).status != noErr {
            errorMessage = "That shortcut couldn’t be registered. Choose another combination."
        }
    }

    func stop() {
        confirmationTask?.cancel()
        confirmationTask = nil
        unregister()
    }

    func beginRecording() {
        confirmationTask?.cancel()
        confirmationTask = nil
        pendingShortcut = nil
        pendingRegistrationIdentifier = nil
        isRecording = true
        errorMessage = nil
        unregister()
    }

    func cancelRecording() {
        guard isRecording else { return }
        isRecording = false
        errorMessage = nil
        restoreCurrentShortcut()
    }

    func assign(_ candidate: GlobalShortcut) {
        isRecording = false
        confirmationTask?.cancel()
        confirmationTask = nil
        let registration = register(candidate)
        let status = registration.status
        guard status == noErr else {
            if restoreCurrentShortcut() {
                errorMessage = "That shortcut couldn’t be registered. Choose another combination."
            }
            return
        }
        pendingShortcut = candidate
        pendingRegistrationIdentifier = registration.identifier
        errorMessage = nil
        confirmationTask = Task { [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: Self.confirmationTimeoutNanoseconds
                )
            } catch {
                return
            }
            self?.confirmationTimedOut(
                expected: candidate,
                registrationIdentifier: registration.identifier
            )
        }
    }

    func clear() {
        guard !isRecording else { return }
        confirmationTask?.cancel()
        confirmationTask = nil
        unregister()
        pendingShortcut = nil
        pendingRegistrationIdentifier = nil
        shortcut = nil
        errorMessage = nil
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    func reportInvalidCombination() {
        errorMessage = "Use at least two modifiers, including ⌘, ⌥ or ⌃."
    }

    func cancelEditing() {
        if isRecording {
            cancelRecording()
            return
        }
        guard pendingShortcut != nil else { return }
        confirmationTask?.cancel()
        confirmationTask = nil
        pendingShortcut = nil
        pendingRegistrationIdentifier = nil
        unregister()
        errorMessage = nil
        restoreCurrentShortcut()
    }

    func confirmationTimedOut(
        expected: GlobalShortcut,
        registrationIdentifier: UInt32
    ) {
        guard pendingShortcut == expected,
              pendingRegistrationIdentifier == registrationIdentifier,
              activeRegistrationIdentifier == registrationIdentifier else {
            return
        }
        confirmationTask?.cancel()
        confirmationTask = nil
        pendingShortcut = nil
        pendingRegistrationIdentifier = nil
        unregister()
        if restoreCurrentShortcut() {
            errorMessage = "BarPilot didn’t receive that shortcut. It may already be in use."
        }
    }

    private func hotKeyPressed(registrationIdentifier: UInt32) {
        guard activeRegistrationIdentifier == registrationIdentifier else { return }
        if let candidate = pendingShortcut {
            guard pendingRegistrationIdentifier == registrationIdentifier else {
                return
            }
            confirmationTask?.cancel()
            confirmationTask = nil
            pendingShortcut = nil
            pendingRegistrationIdentifier = nil
            shortcut = candidate
            errorMessage = nil
            if let data = try? JSONEncoder().encode(candidate) {
                defaults.set(data, forKey: Self.defaultsKey)
            }
        }
        action()
    }

    @discardableResult
    private func restoreCurrentShortcut() -> Bool {
        guard let shortcut else { return true }
        if register(shortcut).status != noErr {
            errorMessage = "The previous shortcut couldn’t be restored. Choose another combination."
            return false
        }
        return true
    }

    private func register(
        _ shortcut: GlobalShortcut
    ) -> (status: OSStatus, identifier: UInt32) {
        nextRegistrationIdentifier &+= 1
        if nextRegistrationIdentifier == 0 { nextRegistrationIdentifier = 1 }
        let identifier = nextRegistrationIdentifier
        activeRegistrationIdentifier = nil
        let status = registrar.register(shortcut, identifier: identifier)
        if status == noErr { activeRegistrationIdentifier = identifier }
        return (status, identifier)
    }

    private func unregister() {
        activeRegistrationIdentifier = nil
        registrar.unregister()
    }
}

/// Carbon invokes its handler on the application event loop. The callback and
/// every mutation of this registrar are therefore main-thread confined, but the
/// legacy C API cannot express that contract to Swift's Sendable checker.
private final class GlobalHotKeyRegistrar: GlobalHotKeyRegistering, @unchecked Sendable {
    private static let signature: OSType = 0x42504C54 // "BPLT"

    var onPress: (@MainActor (UInt32) -> Void)?
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var handlerStatus = OSStatus(eventInternalErr)
    private var currentIdentifier: UInt32?

    init() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else {
                    return OSStatus(eventNotHandledErr)
                }
                var identifier = EventHotKeyID(signature: 0, id: 0)
                let readStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &identifier
                )
                guard readStatus == noErr,
                      identifier.signature == GlobalHotKeyRegistrar.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                let registrar = Unmanaged<GlobalHotKeyRegistrar>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                guard registrar.currentIdentifier == identifier.id else {
                    return OSStatus(eventNotHandledErr)
                }
                Task { @MainActor in registrar.onPress?(identifier.id) }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    func register(_ shortcut: GlobalShortcut, identifier: UInt32) -> OSStatus {
        unregister()
        guard handlerStatus == noErr else { return handlerStatus }
        let hotKeyIdentifier = EventHotKeyID(
            signature: Self.signature,
            id: identifier
        )
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            hotKeyIdentifier,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        if status == noErr { currentIdentifier = identifier }
        return status
    }

    func unregister() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        currentIdentifier = nil
    }

    deinit {
        unregister()
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}

private final class FakeGlobalHotKeyRegistrar: GlobalHotKeyRegistering {
    var onPress: (@MainActor (UInt32) -> Void)?
    private var statuses: [OSStatus]
    private(set) var registered: [GlobalShortcut] = []
    private(set) var identifiers: [UInt32] = []

    init(statuses: [OSStatus]) {
        self.statuses = statuses
    }

    func register(_ shortcut: GlobalShortcut, identifier: UInt32) -> OSStatus {
        registered.append(shortcut)
        identifiers.append(identifier)
        return statuses.isEmpty ? noErr : statuses.removeFirst()
    }

    func unregister() {}

    @MainActor
    func trigger(identifier: UInt32) {
        onPress?(identifier)
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: GlobalShortcut?
    let isRecording: Bool
    let beginRecording: () -> Void
    let cancelRecording: () -> Void
    let assign: (GlobalShortcut) -> Void
    let reportInvalid: () -> Void

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        button.onBegin = beginRecording
        button.onCancel = cancelRecording
        button.onAssign = assign
        button.onInvalid = reportInvalid
        button.shortcut = shortcut
        return button
    }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        button.onBegin = beginRecording
        button.onCancel = cancelRecording
        button.onAssign = assign
        button.onInvalid = reportInvalid
        button.shortcut = shortcut
        button.setRecording(isRecording)
    }
}

final class ShortcutRecorderButton: NSButton {
    var shortcut: GlobalShortcut? { didSet { updateTitle() } }
    var onBegin: (() -> Void)?
    var onCancel: (() -> Void)?
    var onAssign: ((GlobalShortcut) -> Void)?
    var onInvalid: (() -> Void)?
    private(set) var isRecordingShortcut = false
    private var windowResignObserver: NSObjectProtocol?

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(begin)
        font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        focusRingType = .default
        updateTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var acceptsFirstResponder: Bool { true }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let windowResignObserver {
            NotificationCenter.default.removeObserver(windowResignObserver)
            self.windowResignObserver = nil
        }
        guard let newWindow else { return }
        windowResignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: newWindow,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cancelIfRecording()
            }
        }
    }

    @objc private func begin() {
        guard !isRecordingShortcut else { return }
        guard window?.makeFirstResponder(self) == true else { return }
        setRecording(true)
        onBegin?()
    }

    func setRecording(_ recording: Bool) {
        isRecordingShortcut = recording
        updateTitle()
    }

    @discardableResult
    func capture(_ event: NSEvent) -> Bool {
        guard isRecordingShortcut, event.type == .keyDown else { return false }
        switch event.keyCode {
        case 53:
            finishRecording()
            onCancel?()
        case 51, 117:
            finishRecording()
            onCancel?()
        default:
            guard let shortcut = GlobalShortcut.capture(from: event) else {
                NSSound.beep()
                onInvalid?()
                return true
            }
            finishRecording()
            onAssign?(shortcut)
        }
        return true
    }

    override func keyDown(with event: NSEvent) {
        if !capture(event) { super.keyDown(with: event) }
    }

    override func resignFirstResponder() -> Bool {
        let wasRecording = isRecordingShortcut
        let result = super.resignFirstResponder()
        if result, wasRecording {
            cancelIfRecording()
        }
        return result
    }

    private func cancelIfRecording() {
        guard isRecordingShortcut else { return }
        finishRecording()
        onCancel?()
    }

    private func finishRecording() {
        isRecordingShortcut = false
        updateTitle()
    }

    private func updateTitle() {
        title = isRecordingShortcut
            ? "Type shortcut…"
            : shortcut?.displayName ?? "Record Shortcut"
        toolTip = isRecordingShortcut
            ? "Press Escape to cancel."
            : "Click, then press a shortcut using at least two modifiers."
    }

}
