import AppKit
import ApplicationServices

/// Replaces the system volume and brightness pop-ups with the notch.
///
/// An event tap catches the volume, mute and brightness keys before macOS does, applies
/// the change itself and reports it, so the system pop-up never appears. Event taps need
/// Accessibility permission, so this is opt-in from Settings. Without permission, or for
/// an output whose volume can't be set, the keys are left to macOS as usual.
@MainActor
@Observable
final class MediaKeyController {
    private(set) var hasPermission = AXIsProcessTrusted()
    private(set) var isRunning = false

    @ObservationIgnored var onVolume: ((_ level: Float, _ muted: Bool) -> Void)?
    @ObservationIgnored var onBrightness: ((_ level: Float) -> Void)?

    @ObservationIgnored private var tap: CFMachPort?
    @ObservationIgnored private var source: CFRunLoopSource?
    @ObservationIgnored private var permissionPoll: Task<Void, Never>?

    /// System volume and brightness keys move in sixteenths; Shift+Option gives quarter steps.
    private static let step: Float = 1 / 16
    private static let fineStep: Float = 1 / 64

    /// Starts intercepting if permission is granted. Otherwise asks for it, and starts
    /// as soon as it's granted in System Settings (checked for a couple of minutes).
    func enable() {
        hasPermission = AXIsProcessTrusted()
        if hasPermission {
            startTap()
            return
        }
        // The value of kAXTrustedCheckOptionPrompt, which Swift 6 won't read as a global.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        permissionPoll?.cancel()
        permissionPoll = Task {
            for _ in 0..<120 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                if AXIsProcessTrusted() {
                    hasPermission = true
                    startTap()
                    return
                }
            }
        }
    }

    func disable() {
        permissionPoll?.cancel()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        source = nil
        isRunning = false
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    private func startTap() {
        guard tap == nil else { return }
        // NX_SYSDEFINED (14) carries the media and brightness keys.
        let mask = CGEventMask(1) << 14
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: mediaKeyTapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        isRunning = true
    }

    // MARK: Key handling

    /// macOS turns a tap off if a callback is slow or on some user input; turn it back on.
    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// Returns true to swallow the key so the system pop-up doesn't also appear.
    fileprivate func handle(_ key: MediaKey) -> Bool {
        let flags = NSEvent.ModifierFlags(rawValue: key.modifiers)
        // Option alone with these keys opens the matching System Settings pane; leave it.
        if flags.contains(.option) && !flags.contains(.shift) { return false }
        let step = flags.contains(.option) && flags.contains(.shift) ? Self.fineStep : Self.step

        switch key.code {
        case .soundUp, .soundDown, .mute:
            guard let device = AudioOutput.defaultDevice, AudioOutput.canSetVolume(of: device),
                  let volume = AudioOutput.volume(of: device)
            else { return false }
            // Swallow the key-up as well, but act only on key-down (and its repeats).
            guard key.isDown else { return true }
            var muted = AudioOutput.isMuted(device)
            var level = volume
            switch key.code {
            case .soundUp:
                level = (volume + step).quantized(to: step)
                if muted { AudioOutput.setMuted(false, of: device); muted = false }
            case .soundDown:
                level = (volume - step).quantized(to: step)
            default:
                muted.toggle()
                AudioOutput.setMuted(muted, of: device)
            }
            if key.code != .mute { AudioOutput.setVolume(level, of: device) }
            onVolume?(min(max(level, 0), 1), muted || level <= 0)
            return true

        case .brightnessUp, .brightnessDown:
            guard DisplayBrightness.isAvailable, let current = DisplayBrightness.level else { return false }
            guard key.isDown else { return true }
            let level = min(max((current + (key.code == .brightnessUp ? step : -step)).quantized(to: step), 0), 1)
            DisplayBrightness.setLevel(level)
            onBrightness?(level)
            return true
        }
    }
}

/// A media key event, reduced to plain values so it can cross into main-actor code.
fileprivate struct MediaKey: Sendable {
    enum Code: Int {
        // NX_KEYTYPE_* values from IOKit's ev_keymap.h.
        case soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
    }

    let code: Code
    let isDown: Bool
    let modifiers: UInt

    init?(_ event: CGEvent) {
        guard let nsEvent = NSEvent(cgEvent: event), nsEvent.type == .systemDefined, nsEvent.subtype.rawValue == 8,
              let code = Code(rawValue: (nsEvent.data1 & 0xFFFF0000) >> 16)
        else { return nil }
        self.code = code
        isDown = ((nsEvent.data1 & 0xFF00) >> 8) == 0x0A
        modifiers = nsEvent.modifierFlags.rawValue
    }
}

private func mediaKeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                 refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<MediaKeyController>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { controller.reenable() }
        return Unmanaged.passUnretained(event)
    }
    guard let key = MediaKey(event) else { return Unmanaged.passUnretained(event) }
    // The tap's run-loop source is on the main run loop, so this is the main thread.
    let swallow = MainActor.assumeIsolated { controller.handle(key) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}

private extension Float {
    /// Snaps to the step grid, so levels stay on the same sixteenths as macOS's own.
    func quantized(to step: Float) -> Float {
        (self / step).rounded() * step
    }
}
