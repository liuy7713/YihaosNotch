import AppKit
import CoreGraphics
import Foundation
import Synchronization
import os

private let log = Logger(subsystem: "com.yihao.YihaosNotch", category: "CleanKeyboard")

/// Swallows every keyboard, trackpad and mouse event for one cleaning session.
///
/// One tap at the HID level, where input enters the window server, so nothing gets past
/// it to any app. It runs on its own thread, and its callback does a fixed, tiny amount
/// of work: it reads the deadlines from atomics and asks `CleaningPolicy`. The one
/// exception is reading a system key (the power button, media keys), which needs the
/// main thread; that wait is capped, one at a time, and skipped while the main thread
/// is slow (see `systemDefined`). So the keyboard comes back at the deadline even if
/// the rest of the app is stuck.
///
/// Layers that end a session, from the inside out:
/// 1. the callback itself passes everything once the deadline (plus the drain) is past;
/// 2. the main thread stops it at the deadline, and on sleep, lock and so on;
/// 3. a watchdog on its own queue turns the tap off 2 s after the deadline at the latest,
///    and quits the app if even that fails;
/// 4. macOS turns off a tap that stops answering, and quitting always removes it.
///
/// A new one is made for every session and never reused.
final class CleaningTap: @unchecked Sendable {
    let armed = Atomic<Bool>(false)
    let deadline = Atomic<UInt64>(0)
    let drainUntil = Atomic<UInt64>(0)
    let hardDeadline = Atomic<UInt64>(0)
    private let reported = Atomic<Bool>(false)
    /// Set by the main thread when it runs the watchdog's ping.
    private let mainAnswered = Atomic<Bool>(true)
    /// A system key is being read on the main thread.
    private let decoding = Atomic<Bool>(false)
    /// Only ever touched on the tap's thread: after a read timed out, system keys aren't
    /// read (just let through) until this time.
    private var decodeBackoffUntil: UInt64 = 0

    /// Called (on the main queue, once) when the tap stopped by itself or was stopped
    /// by the watchdog.
    private let onStopped: @Sendable () -> Void
    /// Called from the watchdog before it forces the tap off or quits, to show the
    /// pointer again; must be safe on any thread.
    private let emergency: @Sendable () -> Void
    /// Called (on the main queue) when Caps Lock was pressed during cleaning: the
    /// tap can swallow the press but not the toggle, so it's put back at once.
    private let onCapsLock: @Sendable () -> Void

    /// The tap and its run loop, touched only under `lock`: the main thread stops them
    /// while the tap's thread or the watchdog may be using them.
    private let lock = NSLock()
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var watchdog: DispatchSourceTimer?
    /// Only ever touched on the tap's thread (set before the tap exists).
    fileprivate var memory = CleaningPolicy.Memory()
    /// Only ever touched on the watchdog's queue.
    private var watchdogState = Watchdog.State()

    init(onStopped: @escaping @Sendable () -> Void, emergency: @escaping @Sendable () -> Void,
         onCapsLock: @escaping @Sendable () -> Void) {
        self.onStopped = onStopped
        self.emergency = emergency
        self.onCapsLock = onCapsLock
    }

    fileprivate func capsLockPressed() {
        let onCapsLock = onCapsLock
        DispatchQueue.main.async { onCapsLock() }
    }

    /// Starts swallowing input until `deadline`. False if macOS refused the tap, or
    /// took the keyboard away from it (secure input); nothing is left running then.
    func start(deadline: UInt64, drainUntil: UInt64, hardDeadline: UInt64,
               heldKeys: Set<Int64>, heldButtons: Set<Int64>) -> Bool {
        memory = CleaningPolicy.Memory(heldKeys: heldKeys, heldButtons: heldButtons)
        self.deadline.store(deadline, ordering: .sequentiallyConsistent)
        self.drainUntil.store(drainUntil, ordering: .sequentiallyConsistent)
        self.hardDeadline.store(hardDeadline, ordering: .sequentiallyConsistent)
        armed.store(true, ordering: .sequentiallyConsistent)

        // Every event type. At the head of the HID tap point, so this sees input first.
        guard let port = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: CGEventMask.max,
                                           callback: cleaningTapCallback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            armed.store(false, ordering: .sequentiallyConsistent)
            log.error("cleaning tap could not be created")
            return false
        }
        lock.withLock { tap = port }
        nonisolated(unsafe) let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        let ready = DispatchSemaphore(value: 0)
        // The thread keeps this object alive until its run loop stops.
        let thread = Thread { [self] in
            let loop = CFRunLoopGetCurrent()
            lock.withLock { runLoop = loop }
            CFRunLoopAddSource(loop, source, .commonModes)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "Clean Keyboard"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        CGEvent.tapEnable(tap: port, enable: true)
        startWatchdog()

        // With secure input on, macOS can quietly leave a tap without the keyboard.
        if Self.keyboardIsTapped() == false {
            log.error("cleaning tap has no keyboard events; giving up")
            stop()
            return false
        }
        log.info("cleaning started")
        return true
    }

    /// Turns the tap off and removes it. Safe to call more than once, from the main
    /// thread.
    func stop() {
        armed.store(false, ordering: .sequentiallyConsistent)
        let (port, loop) = lock.withLock {
            defer { (tap, runLoop) = (nil, nil) }
            return (tap, runLoop)
        }
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
            log.info("cleaning tap removed")
        }
        if let loop { CFRunLoopStop(loop) }
        lock.withLock {
            watchdog?.cancel()
            watchdog = nil
        }
    }

    // MARK: On the tap's thread

    /// The window server is called outside the lock, so a slow call can't hold up
    /// the watchdog. (Once `stop` has taken the tap, a late call here does nothing:
    /// the port is invalidated.)
    fileprivate func setEnabled(_ enabled: Bool) {
        if let tap = lock.withLock({ tap }) { CGEvent.tapEnable(tap: tap, enable: enabled) }
    }

    /// The session is over as far as the tap is concerned: everything passes from now on.
    fileprivate func stopFromTap() {
        armed.store(false, ordering: .sequentiallyConsistent)
        setEnabled(false)
        report()
    }

    private func report() {
        guard !reported.exchange(true, ordering: .sequentiallyConsistent) else { return }
        let onStopped = onStopped
        DispatchQueue.main.async { onStopped() }
    }

    // MARK: Watchdog

    private func startWatchdog() {
        let queue = DispatchQueue(label: "com.yihao.YihaosNotch.clean-watchdog", qos: .userInteractive)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.watch() }
        lock.withLock { watchdog = timer }
        timer.resume()
    }

    private func watch() {
        let enabled = lock.withLock { tap }.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
        let answered = mainAnswered.exchange(false, ordering: .sequentiallyConsistent)
        DispatchQueue.main.async { [weak self] in self?.mainAnswered.store(true, ordering: .sequentiallyConsistent) }
        let action = Watchdog.tick(now: Monotonic.now(),
                                   hardDeadline: hardDeadline.load(ordering: .sequentiallyConsistent),
                                   armed: armed.load(ordering: .sequentiallyConsistent),
                                   tapEnabled: enabled, mainAnswered: answered, state: &watchdogState)
        switch action {
        case .none:
            break
        case .endSession:
            log.error("watchdog: the cleaning tap was turned off; ending")
            armed.store(false, ordering: .sequentiallyConsistent)
            report()
        case .forceDisable:
            log.fault("watchdog: cleaning ran past its deadline; turning the tap off")
            armed.store(false, ordering: .sequentiallyConsistent)
            setEnabled(false)
            emergency()
            report()
        case .terminate:
            log.fault("watchdog: the tap won't turn off or the app is hung; quitting so input comes back")
            emergency()
            // Straight out, without the clean-up `exit` runs on this thread while others
            // may hold locks it needs. The tap goes with the process.
            _exit(1)
        }
    }

    // MARK: Checks

    /// Whether this app's HID tap is on and receiving key presses, or nil if macOS
    /// doesn't say. (The volume and brightness taps are paused during cleaning, so a
    /// HID tap of ours is this one.)
    private static func keyboardIsTapped() -> Bool? {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { return nil }
        var list = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        guard CGGetEventTapList(count, &list, &count) == .success else { return nil }
        let ours = list.prefix(Int(count)).filter { $0.tappingProcess == getpid() && $0.tapPoint == .cghidEventTap }
        guard !ours.isEmpty else { return nil }
        let keyDown = CGEventMask(1) << CGEventType.keyDown.rawValue
        return ours.contains { $0.enabled && $0.eventsOfInterest & keyDown != 0 }
    }
}

extension CleaningPolicy.Input {
    /// Reads only what the policy needs: the type, and a key code or button number.
    /// (System keys, type 14, are read by `CleaningTap.systemDefined`.)
    init(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout: self = .tapDisabledByTimeout
        case .tapDisabledByUserInput: self = .tapDisabledByUserInput
        case .keyDown:
            self = .keyDown(code: event.getIntegerValueField(.keyboardEventKeycode),
                            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
        case .keyUp: self = .keyUp(code: event.getIntegerValueField(.keyboardEventKeycode))
        case .flagsChanged: self = .flagsChanged(code: event.getIntegerValueField(.keyboardEventKeycode))
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            self = .buttonUp(event.getIntegerValueField(.mouseEventButtonNumber))
        default: self = .other
        }
    }
}

extension CleaningTap {
    static let systemKeyEvent = CGEventType(rawValue: 14)!

    /// NX_SYSDEFINED events (media keys, the power button) only say what they are
    /// through `NSEvent`, which must be made on the main thread (off it, macOS kills
    /// the app on a Caps Lock press). So the main thread reads it, with a short limit.
    /// If it's busy, the event is let through, as the power button must never be lost;
    /// and while one read is waiting, or for a second after one timed out, the next
    /// aren't queued behind it, so a slow main thread can't back up input.
    fileprivate func systemDefined(_ event: CGEvent) -> CleaningPolicy.Input {
        Self.withModifiers(readSystemKey(event), event)
    }

    private func readSystemKey(_ event: CGEvent) -> CleaningPolicy.Input {
        let start = Monotonic.now()
        guard start >= decodeBackoffUntil,
              decoding.compareExchange(expected: false, desired: true, ordering: .sequentiallyConsistent).exchanged
        else { return .powerKey }
        final class Reading: @unchecked Sendable {
            var subtype = -1
            var data1 = 0
        }
        let reading = Reading()
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) let event = event
        DispatchQueue.main.async { [self] in
            if let nsEvent = NSEvent(cgEvent: event), nsEvent.type == .systemDefined {
                reading.subtype = Int(nsEvent.subtype.rawValue)
                reading.data1 = nsEvent.data1
                log.debug("system key: subtype \(reading.subtype) data1 \(String(reading.data1, radix: 16), privacy: .public)")
            }
            self.decoding.store(false, ordering: .sequentiallyConsistent)
            done.signal()
        }
        guard done.wait(timeout: .now() + .milliseconds(50)) == .success else {
            decodeBackoffUntil = start + Monotonic.nanoseconds(1)
            log.info("system key not read in time; let through")
            return .powerKey
        }
        return CleaningPolicy.systemDefined(subtype: reading.subtype, data1: reading.data1)
    }

    /// Control, Command or Option with the power button restart or shut down without
    /// asking; with a palm on them, it's held back.
    private static func withModifiers(_ input: CleaningPolicy.Input, _ event: CGEvent) -> CleaningPolicy.Input {
        guard input == .powerKey,
              !event.flags.intersection([.maskControl, .maskCommand, .maskAlternate]).isEmpty
        else { return input }
        return .powerKeyWithModifiers
    }
}

private func cleaningTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                 refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let owner = Unmanaged<CleaningTap>.fromOpaque(refcon).takeUnretainedValue()
    let input = type == CleaningTap.systemKeyEvent
        ? owner.systemDefined(event)
        : CleaningPolicy.Input(type: type, event: event)
    let decision = CleaningPolicy.decide(input,
                                         now: Monotonic.now(),
                                         deadline: owner.deadline.load(ordering: .sequentiallyConsistent),
                                         drainUntil: owner.drainUntil.load(ordering: .sequentiallyConsistent),
                                         armed: owner.armed.load(ordering: .sequentiallyConsistent),
                                         memory: &owner.memory)
    switch decision {
    case .swallow:
        if input == .flagsChanged(code: CleaningPolicy.capsLockCode) { owner.capsLockPressed() }
        return nil
    case .pass:
        return Unmanaged.passUnretained(event)
    case .reenable:
        owner.setEnabled(true)
        return Unmanaged.passUnretained(event)
    case .passAndStop:
        owner.stopFromTap()
        return Unmanaged.passUnretained(event)
    }
}
