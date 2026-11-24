import AppKit
import Carbon.HIToolbox

/// A key with modifiers, as Carbon's hot-key API takes it, plus what the key prints
/// (for showing it, since the key code alone depends on the keyboard layout).
struct KeyCombo: Codable, Equatable, Sendable {
    var keyCode: UInt32
    /// Carbon flags: `controlKey`, `optionKey`, `shiftKey`, `cmdKey`.
    var modifiers: UInt32
    var key: String

    static let joinMeetingDefault = KeyCombo(keyCode: UInt32(kVK_ANSI_J),
                                             modifiers: UInt32(controlKey | optionKey), key: "J")

    /// "⌃⌥J", in the order macOS menus use.
    var display: String { Self.symbols(for: modifiers) + key }

    static func symbols(for modifiers: UInt32) -> String {
        let order: [(Int, String)] = [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
        return order.filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined()
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result = 0
        if flags.contains(.control) { result |= controlKey }
        if flags.contains(.option) { result |= optionKey }
        if flags.contains(.shift) { result |= shiftKey }
        if flags.contains(.command) { result |= cmdKey }
        return UInt32(result)
    }

    /// A global shortcut takes the keys from every app, so it needs ⌃ or ⌘ and one more
    /// modifier: ⌘J alone belongs to apps, and ⌥ or ⇧ with a letter types a character.
    static func isAcceptable(modifiers: UInt32) -> Bool {
        let held = [controlKey, optionKey, shiftKey, cmdKey].filter { modifiers & UInt32($0) != 0 }.count
        return held >= 2 && modifiers & UInt32(controlKey | cmdKey) != 0
    }

    /// Names for keys that print nothing useful. Others use the character they type.
    static func name(forKeyCode code: Int) -> String? {
        switch code {
        case kVK_Space: "Space"
        case kVK_Return: "↩"
        case kVK_Tab: "⇥"
        case kVK_Delete: "⌫"
        case kVK_ForwardDelete: "⌦"
        case kVK_LeftArrow: "←"
        case kVK_RightArrow: "→"
        case kVK_UpArrow: "↑"
        case kVK_DownArrow: "↓"
        case kVK_Home: "↖"
        case kVK_End: "↘"
        case kVK_PageUp: "⇞"
        case kVK_PageDown: "⇟"
        case kVK_F1: "F1"
        case kVK_F2: "F2"
        case kVK_F3: "F3"
        case kVK_F4: "F4"
        case kVK_F5: "F5"
        case kVK_F6: "F6"
        case kVK_F7: "F7"
        case kVK_F8: "F8"
        case kVK_F9: "F9"
        case kVK_F10: "F10"
        case kVK_F11: "F11"
        case kVK_F12: "F12"
        default: nil
        }
    }

    /// The combination a key press makes, or nil if it can't be a global shortcut.
    init?(event: NSEvent) {
        let modifiers = Self.carbonModifiers(event.modifierFlags)
        guard event.type == .keyDown, Self.isAcceptable(modifiers: modifiers) else { return nil }
        let key = Self.name(forKeyCode: Int(event.keyCode))
            ?? event.characters(byApplyingModifiers: [])?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        // Other function keys type private-use characters, which show as boxes.
        guard let key, !key.isEmpty, !key.unicodeScalars.contains(where: { (0xE000...0xF8FF).contains($0.value) })
        else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers, key: key)
    }

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }
}

/// One system-wide shortcut through Carbon's `RegisterEventHotKey`. Unlike an event tap
/// it needs no permission and sees no other keys: macOS tells the app only when this
/// exact combination is pressed.
@MainActor
final class GlobalHotKey {
    var onPress: (() -> Void)?

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    nonisolated private static let signature: OSType = 0x594E_4F54 // "YNOT"

    /// Registers `combo` in place of any earlier one. False if macOS refused it (some
    /// combinations are reserved, or taken exclusively by another app).
    func register(_ combo: KeyCombo) -> Bool {
        unregister()
        guard installHandler() else { return false }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers,
                                         EventHotKeyID(signature: Self.signature, id: 1),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        hotKey = ref
        return true
    }

    func unregister() {
        guard let hotKey else { return }
        UnregisterEventHotKey(hotKey)
        self.hotKey = nil
    }

    /// Carbon calls back on the main thread, as the app's event target is the main run loop.
    private func installHandler() -> Bool {
        if handler != nil { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let read = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                         EventParamType(typeEventHotKeyID), nil,
                                         MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard read == noErr, id.signature == GlobalHotKey.signature else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.onPress?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        return status == noErr
    }
}
