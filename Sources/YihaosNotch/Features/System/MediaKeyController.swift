import AppKit
import ApplicationServices
import os

/// `log stream --predicate 'subsystem == "com.yihao.YihaosNotch"' --level debug`
private let log = Logger(subsystem: "com.yihao.YihaosNotch", category: "MediaKeys")

/// Replaces the system volume and brightness pop-ups with the notch.
///
/// An event tap catches the volume, mute and brightness keys before macOS does, applies
/// the change itself and reports it, so the system pop-up never appears. Event taps need
/// Accessibility permission, so this is opt-in from Settings. The keys are left to macOS
/// whenever the notch can't show the change (panel open, notch hidden), without
/// permission, and for outputs whose volume or mute can't be set.
@MainActor
@Observable
final class MediaKeyController {
    private(set) var hasPermission = AXIsProcessTrusted()
    private(set) var isRunning = false

    @ObservationIgnored var onVolume: ((_ level: Float, _ muted: Bool) -> Void)?
    @ObservationIgnored var onBrightness: ((_ level: Float) -> Void)?
    /// Whether the closed notch is on screen to show the change. When it isn't, keys
    /// go to macOS so there's always some feedback.
    @ObservationIgnored var canShowHUD: () -> Bool = { true }

    @ObservationIgnored private var wanted = false
    @ObservationIgnored private var tap: CFMachPort?
    @ObservationIgnored private var source: CFRunLoopSource?
    @ObservationIgnored private var brightnessTap: BrightnessKeyTap?
    @ObservationIgnored private let externalKeyboards = ExternalKeyboards()
    @ObservationIgnored private var permissionPoll: Task<Void, Never>?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    /// Keys whose key-down was swallowed; only their key-ups are swallowed, so macOS
    /// never sees half a key press.
    @ObservationIgnored private var swallowedDowns: Set<MediaKey.Code> = []

    /// System volume and brightness keys move in sixteenths; Shift+Option gives quarter steps.
    private static let step: Float = 1 / 16
    private static let fineStep: Float = 1 / 64

    init() {
        // Permission is often granted (or revoked) in System Settings while this app is
        // in the background; re-check whenever the app becomes active again.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { self.refreshPermission() }
        }
    }

    isolated deinit {
        // The tap holds an unretained pointer to self; remove it first.
        stopTap()
    }

    /// Turns interception on. `prompt` shows the system Accessibility request if
    /// permission is missing; that only happens from the Settings toggle, never at launch.
    func enable(prompt: Bool) {
        wanted = true
        refreshPermission()
        guard !hasPermission else { return }
        if prompt {
            // The value of kAXTrustedCheckOptionPrompt, which Swift 6 won't read as a global.
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        // This app is rarely active, so the activation check alone can miss a grant made
        // in System Settings (or one lost to a new signing identity and given back).
        // Watch for it until it arrives: every second at first, then every 5 s, and
        // after 10 minutes every 30 s.
        permissionPoll?.cancel()
        permissionPoll = Task {
            var checks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(checks < 120 ? 1 : checks < 216 ? 5 : 30))
                checks += 1
                guard !Task.isCancelled else { return }
                if AXIsProcessTrusted() {
                    refreshPermission()
                    return
                }
            }
        }
    }

    func disable() {
        wanted = false
        permissionPoll?.cancel()
        stopTap()
    }

    /// Starts the tap once permission is there, or tears it down if it was revoked.
    func refreshPermission() {
        hasPermission = AXIsProcessTrusted()
        log.info("permission trusted=\(self.hasPermission) wanted=\(self.wanted) running=\(self.isRunning)")
        if hasPermission, wanted { startTap() }
        if !hasPermission { stopTap() }
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    private func startTap() {
        guard tap == nil else { return }
        // NX_SYSDEFINED (14) carries the media keys, and the built-in keyboard's
        // brightness keys.
        let mask = CGEventMask(1) << 14
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: mediaKeyTapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            log.error("event tap could not be created")
            return
        }
        log.info("event tap started")
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        isRunning = true

        // A Magic Keyboard's brightness keys arrive as key presses instead, so while
        // an external keyboard is connected a second tap watches for those.
        externalKeyboards.onChange = { [weak self] _ in self?.updateBrightnessTap() }
        externalKeyboards.start()
        updateBrightnessTap()
    }

    /// The tap that sees every key press runs only while it's needed: the media-key
    /// tap is on and an external keyboard is connected.
    private func updateBrightnessTap() {
        guard isRunning, externalKeyboards.isConnected else {
            if brightnessTap != nil { log.info("brightness key tap stopped") }
            brightnessTap?.stop()
            brightnessTap = nil
            return
        }
        guard brightnessTap == nil else { return }
        let brightnessKeys = BrightnessKeyTap { [weak self] up, isDown, isRepeat, modifiers in
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    self?.handle(MediaKey(code: up ? .brightnessUp : .brightnessDown,
                                          isDown: isDown, isRepeat: isRepeat, modifiers: modifiers)) ?? false
                }
            }
        }
        if brightnessKeys.start() {
            brightnessTap = brightnessKeys
            log.info("brightness key tap started (external keyboard connected)")
        } else {
            log.error("brightness key tap could not be created")
        }
    }

    private func stopTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        source = nil
        isRunning = false
        externalKeyboards.stop()
        updateBrightnessTap()
        swallowedDowns.removeAll()
    }

    // MARK: Key handling

    /// macOS turns a tap off if a callback is slow, on some user input, or when
    /// permission is revoked. Turn it back on, unless permission is gone.
    fileprivate func tapWasDisabled() {
        guard AXIsProcessTrusted() else {
            refreshPermission()
            return
        }
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// Returns true to swallow the event so the system pop-up doesn't also appear.
    fileprivate func handle(_ key: MediaKey) -> Bool {
        let swallowed = decide(key)
        log.debug("key \(key.code.rawValue) down=\(key.isDown) repeat=\(key.isRepeat) swallowed=\(swallowed)")
        return swallowed
    }

    private func decide(_ key: MediaKey) -> Bool {
        // A key-up follows its key-down's fate, whatever has changed in between.
        guard key.isDown else { return swallowedDowns.remove(key.code) != nil }
        // A held key's repeats follow the original press: handled only if it was, and
        // never for mute, which would otherwise flicker between muted and unmuted.
        if key.isRepeat {
            guard swallowedDowns.contains(key.code) else { return false }
            if key.code == .mute { return true }
        }

        guard key.isRepeat || canShowHUD() else { return false }
        let flags = NSEvent.ModifierFlags(rawValue: key.modifiers)
        // Option alone with these keys opens the matching System Settings pane; leave it.
        if flags.contains(.option) && !flags.contains(.shift) { return false }
        let step = flags.contains(.option) && flags.contains(.shift) ? Self.fineStep : Self.step

        let handled = switch key.code {
        case .soundUp, .soundDown, .mute: adjustVolume(key.code, step: step)
        case .brightnessUp, .brightnessDown:
            // On an external display, macOS knows how to dim that one (an Apple
            // display, say); this app only ever sets the built-in screen.
            pointerIsOnBuiltInScreen && adjustBrightness(up: key.code == .brightnessUp, step: step)
        }
        if handled { swallowedDowns.insert(key.code) }
        return handled
    }

    private var pointerIsOnBuiltInScreen: Bool {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) else { return true }
        return screen == ScreenLocator.builtInScreen
    }

    private func adjustVolume(_ code: MediaKey.Code, step: Float) -> Bool {
        guard let device = AudioOutput.defaultDevice, AudioOutput.canSetVolume(of: device),
              let volume = AudioOutput.volume(of: device)
        else { return false }
        let canMute = AudioOutput.canSetMute(of: device)
        // Without a settable mute, a mute key we handled would show "muted" while the
        // audio kept playing; let macOS deal with it instead.
        if code == .mute && !canMute { return false }

        var level = volume
        switch code {
        case .soundUp:
            level = min((volume + step).quantized(to: step), 1)
            if canMute, AudioOutput.isMuted(device) { AudioOutput.setMuted(false, of: device) }
            AudioOutput.setVolume(level, of: device)
        case .soundDown:
            level = max((volume - step).quantized(to: step), 0)
            AudioOutput.setVolume(level, of: device)
        default:
            AudioOutput.setMuted(!AudioOutput.isMuted(device), of: device)
        }
        // Report what the device actually did, not what was asked.
        let muted = canMute && AudioOutput.isMuted(device)
        onVolume?(AudioOutput.volume(of: device) ?? level, muted || level <= 0)
        return true
    }

    private func adjustBrightness(up: Bool, step: Float) -> Bool {
        guard DisplayBrightness.isAvailable, let current = DisplayBrightness.level else { return false }
        let level = min(max((current + (up ? step : -step)).quantized(to: step), 0), 1)
        DisplayBrightness.setLevel(level)
        onBrightness?(level)
        return true
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
    let isRepeat: Bool
    let modifiers: UInt

    init(code: Code, isDown: Bool, isRepeat: Bool, modifiers: UInt) {
        self.code = code
        self.isDown = isDown
        self.isRepeat = isRepeat
        self.modifiers = modifiers
    }

    init?(_ event: CGEvent) {
        guard let nsEvent = NSEvent(cgEvent: event), nsEvent.type == .systemDefined, nsEvent.subtype.rawValue == 8,
              let code = Code(rawValue: (nsEvent.data1 & 0xFFFF0000) >> 16)
        else { return nil }
        self.code = code
        isDown = ((nsEvent.data1 & 0xFF00) >> 8) == 0x0A
        isRepeat = (nsEvent.data1 & 0x1) != 0
        modifiers = nsEvent.modifierFlags.rawValue
    }
}

private func mediaKeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                 refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<MediaKeyController>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { controller.tapWasDisabled() }
        return Unmanaged.passUnretained(event)
    }
    guard let key = MediaKey(event) else {
        // Shows what arrives if a key this app expects ever comes in another form.
        if type.rawValue == 14, let nsEvent = NSEvent(cgEvent: event) {
            log.debug("unhandled system event subtype=\(nsEvent.subtype.rawValue) data1=\(String(nsEvent.data1, radix: 16))")
        }
        return Unmanaged.passUnretained(event)
    }
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

// MARK: Magic Keyboard brightness keys

/// Apple's external keyboards (Magic Keyboard) send their brightness keys as ordinary
/// key presses with key codes 144 (up) and 145 (down), not as media-key events.
///
/// Catching them takes a tap that sees every key press, so it runs on its own thread:
/// typing never waits on the main thread, and every other key is passed straight back
/// with nothing read but its key code. Only 144 and 145 hop to the main thread, where
/// `handler` decides (as for any media key) whether the notch shows the change.
///
/// `stop()` runs on the main thread while the tap's thread may be re-enabling the tap,
/// so the tap and its run loop are only touched under `lock`. (Unchecked because Core
/// Foundation's types aren't marked Sendable.)
final class BrightnessKeyTap: @unchecked Sendable {
    typealias Handler = @Sendable (_ up: Bool, _ isDown: Bool, _ isRepeat: Bool, _ modifiers: UInt) -> Bool

    static let brightnessUp: Int64 = 144
    static let brightnessDown: Int64 = 145

    fileprivate let handler: Handler
    private let lock = NSLock()
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Creates the tap and its thread; false if macOS refused the tap.
    func start() -> Bool {
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        // At the HID level, where these key presses are seen before macOS acts on them.
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: brightnessKeyTapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        lock.withLock { self.tap = tap }
        nonisolated(unsafe) let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let loop = CFRunLoopGetCurrent()
            lock.withLock { runLoop = loop }
            CFRunLoopAddSource(loop, source, .commonModes)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "Brightness keys"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        let (tap, runLoop) = lock.withLock {
            defer { (self.tap, self.runLoop) = (nil, nil) }
            return (self.tap, self.runLoop)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoop { CFRunLoopStop(runLoop) }
    }

    /// macOS turns a tap off if a callback is slow or on some user input; turn it back
    /// on unless permission is gone (the main tap notices that and stops everything).
    fileprivate func reenable() {
        guard let tap = lock.withLock({ self.tap }), AXIsProcessTrusted() else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }
}

private func brightnessKeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                      refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let owner = Unmanaged<BrightnessKeyTap>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        owner.reenable()
        return Unmanaged.passUnretained(event)
    }
    let code = event.getIntegerValueField(.keyboardEventKeycode)
    guard code == BrightnessKeyTap.brightnessUp || code == BrightnessKeyTap.brightnessDown else {
        return Unmanaged.passUnretained(event)
    }
    let swallow = owner.handler(code == BrightnessKeyTap.brightnessUp, type == .keyDown,
                                event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                                UInt(event.flags.rawValue))
    return swallow ? nil : Unmanaged.passUnretained(event)
}
