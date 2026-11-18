import AppKit
import Carbon.HIToolbox
import IOKit
import IOKit.hidsystem
import SwiftUI
import Synchronization
import os

private let log = Logger(subsystem: "com.yihao.YihaosNotch", category: "CleanKeyboard")

/// What a cleaning session really does to the Mac (see `CleaningSystem`).
@MainActor
final class LiveCleaningSystem: CleaningSystem {
    weak var session: CleanKeyboardSession?
    /// Keeps the notch panel open (or lets it close).
    var holdPanel: (Bool) -> Void = { _ in }
    /// The cleaning deadline for the notch's wings, nil when not cleaning.
    var showWings: (UInt64?) -> Void = { _ in }

    private let settings: AppSettings
    private let mediaKeys: MediaKeyController
    private let updates: UpdateService

    private var tap: CleaningTap?
    /// Which tap is current, so a late report from an earlier one is ignored.
    private var tapID: UUID?
    /// Keeps a refusal card up for a moment after a session it ended.
    private var refusalHold: Task<Void, Never>?
    private var lastPhase: CleanKeyboardSession.Phase = .idle
    private let cursor = CleaningCursor()
    private var capsLockWasOn: Bool?
    private var overlay: CleaningOverlay?
    private var previousApp: NSRunningApplication?
    private var savedMenu: NSMenu?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var activity: NSObjectProtocol?
    private var screenFrame: CGRect?
    private static let dockHolder = "Clean Keyboard"

    init(settings: AppSettings, mediaKeys: MediaKeyController, updates: UpdateService) {
        self.settings = settings
        self.mediaKeys = mediaKeys
        self.updates = updates
    }

    func now() -> UInt64 { Monotonic.now() }

    func after(nanoseconds: UInt64, _ action: @escaping @MainActor () -> Void) -> CleaningTimer {
        TaskTimer(task: Task { @MainActor in
            // The continuous clock, like the deadlines: time asleep counts.
            try? await Task.sleep(for: .nanoseconds(Int64(min(nanoseconds, UInt64(Int64.max)))),
                                  tolerance: .milliseconds(10), clock: .continuous)
            guard !Task.isCancelled else { return }
            action()
        })
    }

    func refusal() -> CleanKeyboardSession.Phase? {
        guard AXIsProcessTrusted() else { return .needsPermission(prompted: false) }
        if isSecureInputOn() { return .refused(.secureInput) }
        guard ScreenLocator.builtInScreen != nil else { return .refused(.noScreen) }
        if updates.state == .installing { return .refused(.updating) }
        return nil
    }

    func isSecureInputOn() -> Bool { IsSecureEventInputEnabled() }

    func handsOff() -> Bool { Self.heldKeys().isEmpty && Self.heldButtons().isEmpty }

    // MARK: Starting

    func enterLeadIn(seconds: Int, onEscape: @escaping @MainActor () -> Void) {
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == getpid() ? nil : front
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                         reason: "Clean Keyboard")
        // No menu while it runs: ⌘, or ⌘Q in the lead-in would open Settings or close
        // a window over the countdown.
        savedMenu = NSApp.mainMenu
        NSApp.mainMenu = NSMenu()
        // In front, so the overlay gets the keyboard (Esc cancels, nothing else types
        // anywhere during the lead-in) and the pointer can be hidden. An app without a
        // Dock icon is refused that since macOS 14; with one, for these few seconds, it
        // isn't (see DockPresence).
        DockPresence.shared.show(for: Self.dockHolder)
        if let session, let screen = ScreenLocator.builtInScreen {
            screenFrame = screen.frame
            let overlay = CleaningOverlay(session: session, frame: screen.frame, onEscape: onEscape)
            overlay.show()
            self.overlay = overlay
            Task { [weak overlay] in
                try? await Task.sleep(for: .milliseconds(150))
                log.info("lead-in: app active=\(NSApp.isActive) overlay key=\(overlay?.isKey ?? false)")
            }
        }
        observeInterruptions()
        log.info("lead-in for \(seconds) s of cleaning")
    }

    func pauseMediaKeys() { mediaKeys.pause() }

    func saveCapsLock() { capsLockWasOn = CapsLock.isOn }

    func startBlocking(deadline: UInt64, drainUntil: UInt64, hardDeadline: UInt64) -> Bool {
        let cursor = cursor
        let id = UUID()
        let tap = CleaningTap(
            onStopped: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.tapID == id else { return }
                    self.interrupt("the cleaning tap stopped")
                }
            },
            emergency: { cursor.release() })
        tapID = id
        guard tap.start(deadline: deadline, drainUntil: drainUntil, hardDeadline: hardDeadline,
                        heldKeys: Self.heldKeys(), heldButtons: Self.heldButtons())
        else {
            tapID = nil
            return false
        }
        self.tap = tap
        return true
    }

    func hideCursor() { cursor.hide() }

    // MARK: Ending

    func stopBlocking(drain: Bool) {
        guard let tap else { return }
        self.tap = nil
        tapID = nil
        guard drain else {
            tap.stop()
            return
        }
        // The tap lets everything through after the drain and stops itself on the next
        // event; this removes it even if no event comes. A cloth still on Caps Lock in
        // the drain toggles it too, so it's put back once more.
        let capsLock = capsLockWasOn
        Task {
            try? await Task.sleep(for: .seconds(CleanKeyboardSession.drainSeconds + 0.1), clock: .continuous)
            tap.stop()
            if let capsLock { Self.restore(capsLock: capsLock) }
        }
    }

    func releaseCursor() { cursor.release() }

    /// A tap can't stop Caps Lock toggling; put it back as it was. (Kept, so the end
    /// of the drain can do it again.)
    func restoreCapsLock() {
        guard let wasOn = capsLockWasOn else { return }
        Self.restore(capsLock: wasOn)
    }

    private static func restore(capsLock wasOn: Bool) {
        if CapsLock.isOn != wasOn, !CapsLock.set(wasOn) {
            log.error("couldn't put Caps Lock back")
        }
    }

    func leave(completed: Bool) {
        removeObservers()
        overlay?.hide(animated: completed)
        overlay = nil
        if let savedMenu { NSApp.mainMenu = savedMenu }
        savedMenu = nil
        // Only if nothing else has taken over meanwhile.
        if NSApp.isActive, let previousApp, !previousApp.isTerminated {
            NSApp.yieldActivation(to: previousApp)
            previousApp.activate(from: .current, options: [])
        }
        previousApp = nil
        DockPresence.shared.hide(for: Self.dockHolder)
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        screenFrame = nil
        log.info("cleaning ended\(completed ? "" : " early")")
    }

    func resumeMediaKeys() { mediaKeys.resume() }

    func finishedFeedback() {
        guard settings.hapticsEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    func phaseChanged(_ phase: CleanKeyboardSession.Phase) {
        let previous = lastPhase
        lastPhase = phase
        refusalHold?.cancel()
        refusalHold = nil
        if case .cleaning(let until, _) = phase { showWings(until) } else { showWings(nil) }
        // A refusal that ended a session (secure input, say) stays a few seconds,
        // wherever the pointer is, so the keyboard doesn't just flicker off and on.
        if previous.isRunning, !phase.holdsPanel, phase != .idle {
            holdPanel(true)
            refusalHold = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                self?.holdPanel(false)
            }
            return
        }
        holdPanel(phase.holdsPanel)
    }

    // MARK: Interruptions

    /// Anything that means the user has gone, or the screen has changed, ends it.
    private func observeInterruptions() {
        removeObservers()
        let end: @Sendable (Notification) -> Void = { [weak self] note in
            let reason = note.name.rawValue
            MainActor.assumeIsolated { self?.interrupt(reason) }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main, using: end)))
        }
        let distributed = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screensaver.didstart"] {
            observers.append((distributed, distributed.addObserver(forName: .init(name), object: nil, queue: .main,
                                                                   using: end)))
        }
        let local = NotificationCenter.default
        observers.append((local, local.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                                   queue: .main, using: end)))
        // The built-in screen went away or changed size (lid closed, resolution).
        observers.append((local, local.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, ScreenLocator.builtInScreen?.frame != self.screenFrame else { return }
                self.interrupt("the built-in screen changed")
            }
        }))
    }

    private func interrupt(_ reason: String) {
        log.info("ending early: \(reason, privacy: .public)")
        session?.interrupt()
    }

    private func removeObservers() {
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
    }

    // MARK: Keys and buttons held

    /// Keys down right now (Caps Lock left out: it reads as down while it's on).
    static func heldKeys() -> Set<Int64> {
        Set((0..<128).filter { code in
            code != kVK_CapsLock && CGEventSource.keyState(.hidSystemState, key: CGKeyCode(code))
        }.map(Int64.init))
    }

    static func heldButtons() -> Set<Int64> {
        let pressed = NSEvent.pressedMouseButtons
        return Set((0..<32).filter { pressed & (1 << $0) != 0 }.map(Int64.init))
    }
}

private struct TaskTimer: CleaningTimer {
    let task: Task<Void, Never>
    func cancel() { task.cancel() }
}

/// Hides the pointer while cleaning. Showing it again works from any thread, once
/// (the watchdog may do it), so hides and shows always balance.
final class CleaningCursor: Sendable {
    private let hidden = Atomic<Bool>(false)

    @MainActor
    func hide() {
        guard !hidden.load(ordering: .sequentiallyConsistent) else { return }
        // Only works while this app is in front; if it isn't, the pointer just stays.
        if CGDisplayHideCursor(CGMainDisplayID()) == .success {
            hidden.store(true, ordering: .sequentiallyConsistent)
        }
    }

    func release() {
        guard hidden.exchange(false, ordering: .sequentiallyConsistent) else { return }
        CGDisplayShowCursor(CGMainDisplayID())
    }
}

/// Caps Lock's state, and setting it. The cleaning tap can swallow the key press but
/// not the toggle, which happens in the keyboard driver.
enum CapsLock {
    /// Read from the keyboard driver, where `set` writes it; the event system's view
    /// if the driver can't be asked.
    static var isOn: Bool {
        var state = false
        if withConnection({ IOHIDGetModifierLockState($0, Int32(kIOHIDCapsLockState), &state) }) { return state }
        return CGEventSource.flagsState(.hidSystemState).contains(.maskAlphaShift)
    }

    static func set(_ on: Bool) -> Bool {
        withConnection { IOHIDSetModifierLockState($0, Int32(kIOHIDCapsLockState), on) }
    }

    private static func withConnection(_ body: (io_connect_t) -> kern_return_t) -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connection) == KERN_SUCCESS
        else { return false }
        defer { IOServiceClose(connection) }
        return body(connection) == KERN_SUCCESS
    }
}

// MARK: Overlay

/// A light dim over the built-in screen with a big countdown. It takes the keyboard
/// focus during the lead-in, so Esc cancels and no other key reaches anything, and it
/// never takes clicks (if it were ever left behind, it couldn't get in the way).
@MainActor
final class CleaningOverlay {
    private let panel: CleaningOverlayPanel

    init(session: CleanKeyboardSession, frame: CGRect, onEscape: @escaping @MainActor () -> Void) {
        panel = CleaningOverlayPanel(frame: frame)
        panel.onEscape = onEscape
        panel.contentView = NSHostingView(rootView: CleaningOverlayView().environment(session))
    }

    var isKey: Bool { panel.isKeyWindow }

    func show() {
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            panel.animator().alphaValue = 1
        }
    }

    func hide(animated: Bool) {
        panel.onEscape = nil
        guard animated else {
            panel.orderOut(nil)
            return
        }
        let panel = panel
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        }
    }
}

final class CleaningOverlayPanel: NSPanel {
    var onEscape: (@MainActor () -> Void)?

    init(frame: CGRect) {
        // Non-activating, so it can take the keyboard even if macOS declines to bring
        // the app forward.
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                   defer: false)
        becomesKeyOnlyIfNeeded = false
        // Over the menu bar, under the notch's own panel.
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Keys are swallowed until it's gone (for the fade at the end, until the previous
    /// app has the keyboard back).
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            if event.keyCode == UInt16(kVK_Escape) { onEscape?() }
        case .keyUp, .flagsChanged:
            break
        default:
            super.sendEvent(event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == UInt16(kVK_Escape) { onEscape?() }
        return true
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}
