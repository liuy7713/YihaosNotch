import Foundation
import Observation

/// Clean Keyboard: turns the keyboard and trackpad off for a short while, so they can
/// be wiped without typing or clicking anything.
///
/// The steps: checks (permission, secure input, the screen, no update installing),
/// then a 3 s lead-in ("Lift your hands", Esc or Cancel stops it), then a wait until
/// nothing is held down (3 s at most), then cleaning until the deadline, then "Back on".
/// Sleep, the screen locking (the Touch ID button does that), a display change, the
/// app quitting or the tap stopping all end it early.
///
/// Ending always undoes everything, in the same order, whichever way it ends, and
/// undoing twice does nothing. Everything that touches the system goes through
/// `CleaningSystem`, so the steps can be tested with a fake.
@MainActor
@Observable
final class CleanKeyboardSession {
    enum Phase: Equatable {
        case idle
        /// Accessibility isn't granted; `prompted` once the system dialog was asked for.
        case needsPermission(prompted: Bool)
        case refused(Refusal)
        case leadIn(until: UInt64, seconds: Int)
        /// The lead-in is over but a key or button is still down.
        case waitingForHands
        case cleaning(until: UInt64, seconds: Int)
        case done

        /// Panel content showing (the panel is held open for the running ones).
        var isShowing: Bool { self != .idle }
        var isRunning: Bool {
            switch self {
            case .leadIn, .waitingForHands, .cleaning: true
            default: false
            }
        }
        var holdsPanel: Bool { isRunning || self == .done }

        /// The countdown's deadline and the session's length, while there is one.
        var countdown: (until: UInt64, seconds: Int)? {
            switch self {
            case .leadIn(let until, let seconds), .cleaning(let until, let seconds): (until, seconds)
            default: nil
            }
        }

        /// The whole seconds the countdown shows at `now`: rounded up, never 0.
        func secondsShown(at now: UInt64 = Monotonic.now()) -> Int? {
            guard let (until, _) = countdown else { return nil }
            return max(until > now ? Int((Double(until - now) / 1_000_000_000).rounded(.up)) : 0, 1)
        }

        /// How much of the cleaning time is left, 0–1 (1 before it starts).
        func fractionLeft(at now: UInt64 = Monotonic.now()) -> Double {
            switch self {
            case .leadIn, .waitingForHands: return 1
            case .cleaning(let until, let seconds):
                guard until > now, seconds > 0 else { return 0 }
                return min(Double(until - now) / Double(Monotonic.nanoseconds(Double(seconds))), 1)
            default: return 0
            }
        }
    }

    enum Refusal: Equatable {
        case secureInput, noScreen, updating, tapFailed

        var title: String {
            switch self {
            case .secureInput: "Typing is protected right now"
            case .noScreen: "Open the lid first"
            case .updating: "An update is installing"
            case .tapFailed: "Couldn't turn the keyboard off"
            }
        }

        var detail: String {
            switch self {
            case .secureInput:
                "A password field or Secure Keyboard Entry (in Terminal, say) is on, and macOS lets no app pause the keyboard then. Close the field or turn that off, then try again."
            case .noScreen: "Clean Keyboard shows its countdown on the built-in screen."
            case .updating: "Try again once Yihao's Notch has restarted."
            case .tapFailed: "macOS didn't allow it this time. Nothing was turned off; try again."
            }
        }
    }

    /// How a running session ended.
    enum Ending: Equatable {
        case completed
        case cancelled
        case interrupted
        /// Ends on a card instead (a refusal, or the permission card).
        case showing(Phase)
    }

    private(set) var phase: Phase = .idle {
        didSet { if phase != oldValue { system.phaseChanged(phase) } }
    }

    static let leadInSeconds: Double = 3
    /// Longest wait for hands to lift after the lead-in; then it starts anyway (keys
    /// already down are let up).
    static let handsWait: Double = 3
    /// After the deadline, a held key's repeats and release are still held back.
    static let drainSeconds: Double = 1
    /// The watchdog turns the tap off this long after the deadline, whatever happens.
    static let hardDeadlineSeconds: Double = 2
    /// "Back on" stays this long.
    static let doneSeconds: Double = 2
    static let durationRange = 5...60

    @ObservationIgnored private let system: CleaningSystem
    /// Seconds to clean for, read when a session starts.
    @ObservationIgnored private let seconds: () -> Int
    @ObservationIgnored private var timers: [CleaningTimer] = []
    @ObservationIgnored private var handsWaitStarted: UInt64 = 0
    /// This session's length, read once when it's chosen.
    @ObservationIgnored private var sessionSeconds = 30
    /// Set once input is off, so ending knows what to undo.
    @ObservationIgnored private var blocking = false

    init(system: CleaningSystem, seconds: @escaping () -> Int) {
        self.system = system
        self.seconds = seconds
    }

    static func clampedSeconds(_ seconds: Int) -> Int {
        min(max(seconds, durationRange.lowerBound), durationRange.upperBound)
    }

    // MARK: Starting

    /// "Clean Keyboard" was chosen.
    func request() {
        guard !phase.isRunning, phase != .done else { return }
        if let refusal = system.refusal() {
            phase = refusal
            return
        }
        cancelTimers()
        sessionSeconds = Self.clampedSeconds(seconds())
        let until = system.now() + Monotonic.nanoseconds(Self.leadInSeconds)
        phase = .leadIn(until: until, seconds: sessionSeconds)
        system.enterLeadIn(seconds: sessionSeconds, onEscape: { [weak self] in self?.cancel() })
        schedule(at: until) { [weak self] in self?.leadInFinished() }
    }

    /// The system Accessibility dialog was asked for (from the permission card).
    func notePermissionPrompted() {
        if case .needsPermission = phase { phase = .needsPermission(prompted: true) }
    }

    private func leadInFinished() {
        guard case .leadIn = phase else { return }
        // Things may have changed in three seconds (a password field, say).
        if let refusal = system.refusal() {
            finish(.showing(refusal))
            return
        }
        handsWaitStarted = system.now()
        waitForHands()
    }

    private func waitForHands() {
        guard phase.isRunning, !blocking else { return }
        if system.handsOff() || system.now() >= handsWaitStarted + Monotonic.nanoseconds(Self.handsWait) {
            beginCleaning()
        } else {
            phase = .waitingForHands
            schedule(at: system.now() + Monotonic.nanoseconds(0.05)) { [weak self] in self?.waitForHands() }
        }
    }

    private func beginCleaning() {
        let seconds = sessionSeconds
        let deadline = system.now() + Monotonic.nanoseconds(Double(seconds))
        system.pauseMediaKeys()
        system.saveCapsLock()
        blocking = true
        guard system.startBlocking(deadline: deadline,
                                   drainUntil: deadline + Monotonic.nanoseconds(Self.drainSeconds),
                                   hardDeadline: deadline + Monotonic.nanoseconds(Self.hardDeadlineSeconds))
        else {
            finish(.showing(.refused(.tapFailed)))
            return
        }
        system.hideCursor()
        phase = .cleaning(until: deadline, seconds: seconds)
        // Activating this app can end someone else's secure input, or not; and a
        // password dialog can open mid-way. Either way the keyboard isn't really off
        // then, and the cloth would type into the password field.
        watchSecureInput(after: 0.2)
        schedule(at: deadline) { [weak self] in self?.finish(.completed) }
    }

    private func watchSecureInput(after seconds: Double) {
        schedule(at: system.now() + Monotonic.nanoseconds(seconds)) { [weak self] in
            guard let self, case .cleaning = phase else { return }
            if system.isSecureInputOn() {
                finish(.showing(.refused(.secureInput)))
            } else {
                watchSecureInput(after: 0.5)
            }
        }
    }

    // MARK: Ending

    /// Esc or the Cancel button, during the lead-in.
    func cancel() {
        switch phase {
        case .leadIn, .waitingForHands: finish(.cancelled)
        default: break
        }
    }

    /// Sleep, lock, a display change, the tap stopping: ends whatever is running.
    func interrupt() {
        finish(.interrupted)
    }

    /// The panel closed: a card (permission, refusal) goes with it.
    func panelClosed() {
        switch phase {
        case .needsPermission, .refused: phase = .idle
        default: break
        }
    }

    /// The card's close button.
    func dismiss() {
        panelClosed()
    }

    /// Puts everything back. Runs once per session; later calls do nothing.
    private func finish(_ ending: Ending) {
        guard phase.isRunning else { return }
        cancelTimers()
        let wasBlocking = blocking
        blocking = false
        // Input first, so whatever happens next, the keyboard and trackpad work.
        if wasBlocking {
            system.stopBlocking(drain: ending == .completed)
            system.releaseCursor()
            system.restoreCapsLock()
        }
        system.leave(completed: ending == .completed)
        if wasBlocking { system.resumeMediaKeys() }

        switch ending {
        case .completed:
            phase = .done
            system.finishedFeedback()
            schedule(at: system.now() + Monotonic.nanoseconds(Self.doneSeconds)) { [weak self] in
                guard let self, phase == .done else { return }
                phase = .idle
            }
        case .showing(let card):
            phase = card
        case .cancelled, .interrupted:
            phase = .idle
        }
    }

    // MARK: Timers

    private func schedule(at time: UInt64, _ action: @escaping @MainActor () -> Void) {
        let now = system.now()
        timers.append(system.after(nanoseconds: time > now ? time - now : 0, action))
    }

    private func cancelTimers() {
        timers.forEach { $0.cancel() }
        timers.removeAll()
    }
}

@MainActor
protocol CleaningTimer {
    func cancel()
}

/// Everything a session does to the Mac. `LiveCleaningSystem` does it for real.
@MainActor
protocol CleaningSystem: AnyObject {
    func now() -> UInt64
    func after(nanoseconds: UInt64, _ action: @escaping @MainActor () -> Void) -> CleaningTimer
    /// Why it can't start now, as the phase to show; nil if it can.
    func refusal() -> CleanKeyboardSession.Phase?
    func isSecureInputOn() -> Bool
    /// No key or mouse button is down.
    func handsOff() -> Bool

    /// Remembers the app in front, brings this one forward and shows the dimmed overlay.
    func enterLeadIn(seconds: Int, onEscape: @escaping @MainActor () -> Void)
    func pauseMediaKeys()
    func saveCapsLock()
    func startBlocking(deadline: UInt64, drainUntil: UInt64, hardDeadline: UInt64) -> Bool
    func hideCursor()

    /// Stops swallowing input: at once, or after the drain (a normal end).
    func stopBlocking(drain: Bool)
    func releaseCursor()
    func restoreCapsLock()
    /// Removes the overlay and gives the previous app its focus back.
    func leave(completed: Bool)
    func resumeMediaKeys()
    func finishedFeedback()
    func phaseChanged(_ phase: CleanKeyboardSession.Phase)
}
