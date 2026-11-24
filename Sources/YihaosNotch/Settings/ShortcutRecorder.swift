import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Shows a global shortcut and records a new one: click it, then press the keys. Esc,
/// clicking anywhere else or leaving the window keeps the old one.
struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo
    @Binding var isRecording: Bool

    /// Modifiers held so far while recording, shown as they're pressed.
    @State private var held: UInt32 = 0
    @State private var monitor: Any?
    /// A click that ended recording also reaches the button; it mustn't start it again.
    @State private var stoppedByClick: TimeInterval = -1

    var body: some View {
        Button {
            if isRecording {
                stop()
            } else if ProcessInfo.processInfo.systemUptime - stoppedByClick > 0.3 {
                start()
            }
        } label: {
            Text(label)
                .monospacedDigit()
                .frame(minWidth: 84)
                .contentTransition(.identity)
        }
        .help(isRecording ? "Press the new shortcut, or Esc to keep \(combo.display)" : "Click to change")
        .accessibilityLabel("Shortcut")
        .accessibilityValue(isRecording ? "Recording" : combo.display)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in stop() }
        .onDisappear { stop() }
    }

    private var label: String {
        guard isRecording else { return combo.display }
        return held == 0 ? "Type Shortcut" : KeyCombo.symbols(for: held)
    }

    private func start() {
        held = 0
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown]
        ) { event in
            let type = event.type
            let isEscape = type == .keyDown && Int(event.keyCode) == kVK_Escape
            let recorded = type == .keyDown ? KeyCombo(event: event) : nil
            let modifiers = KeyCombo.carbonModifiers(event.modifierFlags)
            let time = event.timestamp
            return MainActor.assumeIsolated { () -> Bool in
                switch type {
                case .flagsChanged:
                    held = modifiers
                    return true
                case .keyDown:
                    if isEscape {
                        stop()
                    } else if let recorded {
                        combo = recorded
                        stop()
                    } else {
                        // A plain key, or only ⌥/⇧: not something to take from every app.
                        NSSound.beep()
                    }
                    return false
                default:
                    stoppedByClick = time
                    stop()
                    return true
                }
            } ? event : nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        held = 0
        if isRecording { isRecording = false }
    }
}
