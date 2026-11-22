import Foundation

/// Time for Clean Keyboard: nanoseconds that keep counting while the Mac sleeps, the
/// same clock `ContinuousClock` uses. Every deadline in a session is on this clock, so
/// the tap's thread, the watchdog and the main thread agree, and a nap doesn't stretch
/// a session.
enum Monotonic {
    @inline(__always)
    static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) }

    static func nanoseconds(_ seconds: Double) -> UInt64 { UInt64(max(seconds, 0) * 1_000_000_000) }
}

/// What the cleaning tap does with each event. Kept apart from the tap so every rule
/// can be tested without one.
///
/// Before the deadline everything is swallowed, except the release of a key or button
/// that was already down when cleaning began (so nothing is left stuck down). Then, for
/// a short drain, the repeats and release of a key pressed during cleaning are still
/// swallowed (a finger resting on a key mustn't start typing the moment it ends);
/// anything else passes. After that, or once disarmed, events pass and the tap stops.
enum CleaningPolicy {
    enum Input: Equatable {
        case keyDown(code: Int64, isRepeat: Bool)
        case keyUp(code: Int64)
        /// A modifier key or Caps Lock, pressed or released.
        case flagsChanged(code: Int64)
        case buttonUp(Int64)
        /// The power (Touch ID) button: always let through, as pressing it locks the
        /// Mac, the one way to end cleaning early.
        case powerKey
        /// The power button with Control, Command or Option down: held back while
        /// cleaning, as those make it restart or shut down without saving.
        case powerKeyWithModifiers
        /// Everything else: pointer movement, clicks, scrolling, gestures, media keys.
        case other
        case tapDisabledByTimeout
        case tapDisabledByUserInput
    }

    enum Decision: Equatable {
        case swallow
        case pass
        /// macOS turned the tap off for being slow; turn it back on.
        case reenable
        /// Let it through and turn the tap off for good: the session is over.
        case passAndStop
    }

    /// What the tap remembers during one session (only ever touched on its thread).
    struct Memory: Equatable {
        /// Keys and buttons down when cleaning began; their release is let through.
        var heldKeys: Set<Int64> = []
        var heldButtons: Set<Int64> = []
        /// Keys pressed during cleaning, so their repeats and release can be held back
        /// during the drain.
        var swallowedKeys: Set<Int64> = []
    }

    /// Caps Lock's key code: its toggle happens in the keyboard driver, before any tap,
    /// so the tap reports it to be put straight back.
    static let capsLockCode: Int64 = 57

    /// An NX_SYSDEFINED event (media keys, the power button), from its subtype and
    /// data1 as `NSEvent` reads them. The power events always get through: the power
    /// key (1), sleep, restart and shut down (11–13), and 16, which is what the Touch ID
    /// button sends on a MacBook (seen on macOS 27, one per press). Eject (10) doesn't:
    /// it sits on the top row of external keyboards, under the cloth, and isn't a way out. Older
    /// keyboards send the power key as an auxiliary key (subtype 8) of type
    /// NX_POWER_KEY (6). Caps Lock can also come as an auxiliary key (type 4).
    static func systemDefined(subtype: Int, data1: Int) -> Input {
        switch subtype {
        case 1, 11...13, 16:
            return .powerKey
        case 8:
            switch (data1 & 0xFFFF0000) >> 16 {
            case 6: return .powerKey
            case 4: return .flagsChanged(code: capsLockCode)
            default: return .other
            }
        default:
            return .other
        }
    }

    static func decide(_ input: Input, now: UInt64, deadline: UInt64, drainUntil: UInt64, armed: Bool,
                       memory: inout Memory) -> Decision {
        switch input {
        case .tapDisabledByTimeout:
            // Only while cleaning is meant to be on; never past the deadline.
            return armed && now < deadline ? .reenable : .passAndStop
        case .tapDisabledByUserInput:
            // macOS took the tap away (secure input, say). Never fight that.
            return .passAndStop
        case .powerKey:
            return armed ? .pass : .passAndStop
        case .powerKeyWithModifiers:
            guard armed else { return .passAndStop }
            return now < deadline ? .swallow : .pass
        default:
            break
        }
        guard armed else { return .passAndStop }

        // A key or button held since before cleaning: its release always gets through.
        switch input {
        case .keyUp(let code), .flagsChanged(let code):
            if memory.heldKeys.remove(code) != nil { return .pass }
        case .buttonUp(let button):
            if memory.heldButtons.remove(button) != nil { return .pass }
        default:
            break
        }

        if now < deadline {
            if case .keyDown(let code, _) = input, !memory.heldKeys.contains(code) {
                memory.swallowedKeys.insert(code)
            }
            return .swallow
        }
        if now < drainUntil {
            switch input {
            case .keyDown(let code, true) where memory.swallowedKeys.contains(code):
                return .swallow
            case .keyDown(let code, false):
                // Pressed afresh: it's the user's again.
                memory.swallowedKeys.remove(code)
                return .pass
            case .keyUp(let code) where memory.swallowedKeys.remove(code) != nil:
                return .swallow
            default:
                return .pass
            }
        }
        return .passAndStop
    }
}

/// The watchdog's rules, checked twice a second on its own queue: it never waits on
/// the main thread, so a hang there can't keep the keyboard off. It does check the main
/// thread still answers: a hung app left in front, with its overlay key, would keep
/// the keyboard looking dead even with the tap gone.
enum Watchdog {
    enum Action: Equatable {
        case none
        /// The tap is off though it should be on: end the session (cleaning is over
        /// whether we like it or not, so say so).
        case endSession
        /// Past the hard deadline and still armed or on: turn it off from here.
        case forceDisable
        /// Turning it off didn't work: quit, which always releases the tap.
        case terminate
    }

    /// What the watchdog remembers between checks.
    struct State: Equatable {
        var disabledTicks = 0
        /// When it first forced the tap off.
        var forcedAt: UInt64?
        /// Checks in a row the main thread hasn't answered.
        var mainMissedTicks = 0
    }

    /// How long after forcing the tap off a tap still on makes the app quit.
    static let terminateGrace = Monotonic.nanoseconds(5)
    /// Past the hard deadline by this much with the main thread silent for
    /// `mainHangTicks` checks in a row (3 s), the app quits: hung, it would stay in
    /// front and keep the keyboard. (Counted in checks, not time, so time asleep, when
    /// neither runs, never counts as a hang.)
    static let mainHangGrace = Monotonic.nanoseconds(1)
    static let mainHangTicks = 6

    static func tick(now: UInt64, hardDeadline: UInt64, armed: Bool, tapEnabled: Bool,
                     mainAnswered: Bool = true, state: inout State) -> Action {
        state.mainMissedTicks = mainAnswered ? 0 : state.mainMissedTicks + 1
        if now >= hardDeadline &+ mainHangGrace, state.mainMissedTicks >= mainHangTicks {
            return .terminate
        }
        if now >= hardDeadline, armed || tapEnabled {
            // Always try turning it off first (the first check can come late, after
            // sleep), and quit only if it's still on well after that.
            guard let forcedAt = state.forcedAt else {
                state.forcedAt = now
                return .forceDisable
            }
            return tapEnabled && now >= forcedAt &+ terminateGrace ? .terminate : .forceDisable
        }
        if armed, !tapEnabled {
            // macOS turns a slow tap off and the tap turns itself back on at once; only
            // a tap that stays off for two checks in a row counts.
            state.disabledTicks += 1
            return state.disabledTicks >= 2 ? .endSession : .none
        }
        state.disabledTicks = 0
        return .none
    }
}
