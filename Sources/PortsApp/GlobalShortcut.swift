import Carbon.HIToolbox
import Observation
import PortsCore

/// The system-wide shortcut ⌃⌥⌘R. Carbon hot keys need no Accessibility permission, unlike global NSEvent monitors.
@MainActor @Observable
final class GlobalShortcut {
    static let shared = GlobalShortcut()
    /// Key symbols read the same in every language, so this is never localized.
    let display = "⌃⌥⌘R"
    /// Another app holds the combination, so pressing it would never reach this one.
    private(set) var registrationFailed = false
    /// 'BYTE', so the handler only takes its own key.
    nonisolated private static let hotKeyID = EventHotKeyID(signature: 0x4259_5445, id: 1)
    @ObservationIgnored private var hotKey: EventHotKeyRef?
    @ObservationIgnored private var handler: EventHandlerRef?
    @ObservationIgnored private var action: (@MainActor () -> Void)?

    private init() {}

    /// Registers or removes the hot key. Turning it on again retries a registration that failed.
    func update(enabled: Bool, action: @escaping @MainActor () -> Void) {
        self.action = action
        guard enabled else { return unregister() }
        guard hotKey == nil else { return }
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        // Exclusive, so a combination another app already registered fails instead of reaching both apps.
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_R), UInt32(cmdKey | optionKey | controlKey), Self.hotKeyID, GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive), &ref)
        registrationFailed = status != noErr
        if status == noErr {
            hotKey = ref
            PortsLog.lifecycle.notice("Global shortcut registered")
        } else {
            PortsLog.lifecycle.error("Global shortcut registration failed: \(status, privacy: .public)")
        }
    }

    private func unregister() {
        registrationFailed = false
        guard let hotKey else { return }
        UnregisterEventHotKey(hotKey)
        self.hotKey = nil
        PortsLog.lifecycle.notice("Global shortcut unregistered")
    }

    /// Installed once and kept: without a registered hot key no event arrives.
    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                var pressedID = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &pressedID)
                guard status == noErr, pressedID.signature == GlobalShortcut.hotKeyID.signature,
                    pressedID.id == GlobalShortcut.hotKeyID.id
                else { return OSStatus(eventNotHandledErr) }
                // Application events arrive on the main thread.
                MainActor.assumeIsolated { GlobalShortcut.shared.pressed() }
                return noErr
            }, 1, &pressed, nil, &handler)
        if status != noErr {
            PortsLog.lifecycle.error("Global shortcut handler not installed: \(status, privacy: .public)")
        }
    }

    private func pressed() {
        PortsLog.lifecycle.debug("Global shortcut pressed")
        action?()
    }
}
