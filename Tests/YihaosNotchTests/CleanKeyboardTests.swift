import Foundation
import Testing
@testable import YihaosNotch

/// The cleaning tap's rules, without a tap.
struct CleaningPolicyTests {
    typealias Policy = CleaningPolicy
    let deadline: UInt64 = 10_000
    let drain: UInt64 = 11_000

    private func decide(_ input: Policy.Input, at now: UInt64, armed: Bool = true,
                        memory: inout Policy.Memory) -> Policy.Decision {
        Policy.decide(input, now: now, deadline: deadline, drainUntil: drain, armed: armed, memory: &memory)
    }

    @Test(arguments: [Policy.Input.keyDown(code: 0, isRepeat: false), .keyUp(code: 0), .flagsChanged(code: 56),
                      .buttonUp(0), .other])
    func everythingIsSwallowedBeforeTheDeadline(_ input: Policy.Input) {
        var memory = Policy.Memory()
        #expect(decide(input, at: 5_000, memory: &memory) == .swallow)
    }

    @Test func aKeyHeldWhenCleaningBeganIsLetUpOnce() {
        var memory = Policy.Memory(heldKeys: [12, 56], heldButtons: [0])
        #expect(decide(.keyDown(code: 12, isRepeat: true), at: 1, memory: &memory) == .swallow)
        #expect(decide(.keyUp(code: 12), at: 2, memory: &memory) == .pass)
        #expect(decide(.keyUp(code: 12), at: 3, memory: &memory) == .swallow)
        #expect(decide(.flagsChanged(code: 56), at: 4, memory: &memory) == .pass)
        #expect(decide(.buttonUp(0), at: 5, memory: &memory) == .pass)
        #expect(decide(.buttonUp(0), at: 6, memory: &memory) == .swallow)
        // Its repeats during cleaning weren't counted as a new press.
        #expect(memory.swallowedKeys.isEmpty)
    }

    @Test func aKeyHeldOverTheEndDoesNotStartTyping() {
        var memory = Policy.Memory()
        #expect(decide(.keyDown(code: 7, isRepeat: false), at: 9_000, memory: &memory) == .swallow)
        // In the drain: its repeats and its release stay swallowed…
        #expect(decide(.keyDown(code: 7, isRepeat: true), at: 10_100, memory: &memory) == .swallow)
        #expect(decide(.keyUp(code: 7), at: 10_200, memory: &memory) == .swallow)
        // …while anything else, and a fresh press, gets through.
        #expect(decide(.keyDown(code: 8, isRepeat: false), at: 10_300, memory: &memory) == .pass)
        #expect(decide(.other, at: 10_400, memory: &memory) == .pass)
        #expect(decide(.keyUp(code: 8), at: 10_500, memory: &memory) == .pass)
    }

    @Test func aFreshPressInTheDrainIsTheUsersAgain() {
        var memory = Policy.Memory()
        _ = decide(.keyDown(code: 7, isRepeat: false), at: 9_000, memory: &memory)
        _ = decide(.keyUp(code: 7), at: 9_100, memory: &memory)
        #expect(decide(.keyDown(code: 7, isRepeat: false), at: 10_100, memory: &memory) == .pass)
        #expect(decide(.keyUp(code: 7), at: 10_200, memory: &memory) == .pass)
    }

    @Test func afterTheDrainEverythingPassesAndTheTapStops() {
        var memory = Policy.Memory()
        #expect(decide(.keyDown(code: 1, isRepeat: false), at: 11_000, memory: &memory) == .passAndStop)
        #expect(decide(.other, at: 99_000, memory: &memory) == .passAndStop)
    }

    @Test func disarmedPassesAndStopsEvenBeforeTheDeadline() {
        var memory = Policy.Memory()
        #expect(decide(.keyDown(code: 1, isRepeat: false), at: 1, armed: false, memory: &memory) == .passAndStop)
        #expect(decide(.tapDisabledByTimeout, at: 1, armed: false, memory: &memory) == .passAndStop)
    }

    @Test func aTimedOutTapComesBackOnlyBeforeTheDeadline() {
        var memory = Policy.Memory()
        #expect(decide(.tapDisabledByTimeout, at: 9_999, memory: &memory) == .reenable)
        #expect(decide(.tapDisabledByTimeout, at: 10_000, memory: &memory) == .passAndStop)
    }

    /// Pressing Touch ID locks the Mac: the one way out early, so it's never swallowed.
    @Test func thePowerButtonAlwaysGetsThrough() {
        var memory = Policy.Memory()
        #expect(decide(.powerKey, at: 1, memory: &memory) == .pass)
        #expect(decide(.powerKey, at: 10_500, memory: &memory) == .pass)
    }

    @Test func aTapMacOSTookAwayIsNeverTurnedBackOn() {
        var memory = Policy.Memory()
        #expect(decide(.tapDisabledByUserInput, at: 1, memory: &memory) == .passAndStop)
    }
}

struct WatchdogTests {
    let hard: UInt64 = 100_000_000_000
    typealias State = Watchdog.State

    private func tick(_ now: UInt64, armed: Bool, enabled: Bool, _ state: inout State) -> Watchdog.Action {
        Watchdog.tick(now: now, hardDeadline: hard, armed: armed, tapEnabled: enabled, state: &state)
    }

    @Test func quietWhileAllIsWell() {
        var state = State()
        #expect(tick(1, armed: true, enabled: true, &state) == .none)
        #expect(tick(1, armed: false, enabled: false, &state) == .none)
    }

    @Test func aTapThatStaysOffEndsTheSessionOnTheSecondCheck() {
        var state = State()
        #expect(tick(1, armed: true, enabled: false, &state) == .none)
        #expect(tick(2, armed: true, enabled: false, &state) == .endSession)
    }

    @Test func aTapBackOnStartsTheCountAgain() {
        var state = State()
        _ = tick(1, armed: true, enabled: false, &state)
        _ = tick(2, armed: true, enabled: true, &state)
        #expect(tick(3, armed: true, enabled: false, &state) == .none)
    }

    @Test func pastTheHardDeadlineItForcesTheTapOff() {
        var state = State()
        #expect(tick(hard, armed: true, enabled: true, &state) == .forceDisable)
        #expect(tick(hard + 1, armed: false, enabled: true, &state) == .forceDisable)
        #expect(tick(hard + 2, armed: false, enabled: false, &state) == .none)
    }

    @Test func aTapThatWontTurnOffQuitsTheAppFiveSecondsAfterForcing() {
        var state = State()
        let forced = hard + 1_000
        #expect(tick(forced, armed: false, enabled: true, &state) == .forceDisable)
        #expect(tick(forced + Watchdog.terminateGrace - 1, armed: false, enabled: true, &state) == .forceDisable)
        #expect(tick(forced + Watchdog.terminateGrace, armed: false, enabled: true, &state) == .terminate)
    }

    /// After sleep, the first check may come long past the deadline: it still tries
    /// turning the tap off before quitting.
    @Test func aLateFirstCheckForcesBeforeQuitting() {
        var state = State()
        #expect(tick(hard + 60 * Watchdog.terminateGrace, armed: true, enabled: true, &state) == .forceDisable)
    }
}

/// Records what a session does, on a clock that only moves when told to.
@MainActor
private final class FakeCleaningSystem: CleaningSystem {
    var time: UInt64 = 1_000_000_000_000
    var calls: [String] = []
    var refusalToGive: CleanKeyboardSession.Phase?
    var secureInput = false
    var hands = true
    var blockingWorks = true
    var deadline: UInt64?
    var phases: [CleanKeyboardSession.Phase] = []
    var escape: (@MainActor () -> Void)?

    final class FakeTimer: CleaningTimer {
        var cancelled = false
        func cancel() { cancelled = true }
    }

    private var pending: [(at: UInt64, timer: FakeTimer, action: @MainActor () -> Void)] = []

    func advance(_ seconds: Double) {
        let target = time + Monotonic.nanoseconds(seconds)
        while let next = pending.indices
            .filter({ !pending[$0].timer.cancelled && pending[$0].at <= target })
            .min(by: { pending[$0].at < pending[$1].at }) {
            let item = pending.remove(at: next)
            time = max(time, item.at)
            item.action()
        }
        time = target
    }

    func now() -> UInt64 { time }
    func after(nanoseconds: UInt64, _ action: @escaping @MainActor () -> Void) -> CleaningTimer {
        let timer = FakeTimer()
        pending.append((time + nanoseconds, timer, action))
        return timer
    }
    func refusal() -> CleanKeyboardSession.Phase? { refusalToGive }
    func isSecureInputOn() -> Bool { secureInput }
    func handsOff() -> Bool { hands }
    func enterLeadIn(seconds: Int, onEscape: @escaping @MainActor () -> Void) {
        calls.append("enterLeadIn(\(seconds))")
        escape = onEscape
    }
    func pauseMediaKeys() { calls.append("pauseMediaKeys") }
    func saveCapsLock() { calls.append("saveCapsLock") }
    func startBlocking(deadline: UInt64, drainUntil: UInt64, hardDeadline: UInt64) -> Bool {
        calls.append("startBlocking")
        self.deadline = deadline
        return blockingWorks
    }
    func hideCursor() { calls.append("hideCursor") }
    func stopBlocking(drain: Bool) { calls.append("stopBlocking(drain: \(drain))") }
    func releaseCursor() { calls.append("releaseCursor") }
    func restoreCapsLock() { calls.append("restoreCapsLock") }
    func leave(completed: Bool) { calls.append("leave(completed: \(completed))") }
    func resumeMediaKeys() { calls.append("resumeMediaKeys") }
    func finishedFeedback() { calls.append("feedback") }
    func phaseChanged(_ phase: CleanKeyboardSession.Phase) { phases.append(phase) }
}

@MainActor
struct CleanKeyboardSessionTests {
    private let system = FakeCleaningSystem()

    private func session(seconds: Int = 30) -> CleanKeyboardSession {
        CleanKeyboardSession(system: system) { seconds }
    }

    private static let starting = ["enterLeadIn(30)", "pauseMediaKeys", "saveCapsLock", "startBlocking", "hideCursor"]

    @Test func aFullSessionUndoesEverythingInOrder() {
        let session = session()
        session.request()
        guard case .leadIn = session.phase else { Issue.record("no lead-in"); return }
        #expect(system.calls == ["enterLeadIn(30)"])

        system.advance(3)
        guard case .cleaning(let until, 30) = session.phase else { Issue.record("not cleaning"); return }
        #expect(until == system.deadline)
        #expect(system.calls == Self.starting)

        system.calls.removeAll()
        system.advance(30)
        #expect(session.phase == .done)
        #expect(system.calls == ["stopBlocking(drain: true)", "releaseCursor", "restoreCapsLock",
                                 "leave(completed: true)", "resumeMediaKeys", "feedback"])
        system.advance(2)
        #expect(session.phase == .idle)
    }

    @Test func theDeadlineIsTheChosenLengthAfterTheLeadIn() {
        let session = session(seconds: 15)
        session.request()
        let start = system.time
        system.advance(3)
        #expect(system.deadline == start + Monotonic.nanoseconds(3 + 15))
        system.advance(14.9)
        guard case .cleaning = session.phase else { Issue.record("ended early"); return }
        system.advance(0.2)
        #expect(session.phase == .done)
    }

    @Test(arguments: [(1, 5), (5, 5), (30, 30), (60, 60), (600, 60)])
    func lengthIsKeptBetweenFiveSecondsAndAMinute(_ asked: Int, _ used: Int) {
        #expect(CleanKeyboardSession.clampedSeconds(asked) == used)
    }

    @Test func anOverlongSettingStillStopsAtAMinute() {
        let session = session(seconds: 3600)
        session.request()
        system.advance(3)
        guard case .cleaning(_, let seconds) = session.phase else { Issue.record("not cleaning"); return }
        #expect(seconds == 60)
        system.advance(60)
        #expect(session.phase == .done)
    }

    @Test func aRefusalShowsAndStartsNothing() {
        system.refusalToGive = .refused(.secureInput)
        let session = session()
        session.request()
        #expect(session.phase == .refused(.secureInput))
        #expect(system.calls.isEmpty)
        session.panelClosed()
        #expect(session.phase == .idle)
    }

    @Test func withoutPermissionItAsksAndNeverStartsByItself() {
        system.refusalToGive = .needsPermission(prompted: false)
        let session = session()
        session.request()
        session.notePermissionPrompted()
        #expect(session.phase == .needsPermission(prompted: true))
        system.refusalToGive = nil
        system.advance(10)
        #expect(session.phase == .needsPermission(prompted: true))
        #expect(system.calls.isEmpty)
    }

    @Test func escapeInTheLeadInCancelsWithNothingToUndo() {
        let session = session()
        session.request()
        system.advance(1)
        system.escape?()
        #expect(session.phase == .idle)
        #expect(system.calls == ["enterLeadIn(30)", "leave(completed: false)"])
        // Its timers are gone too.
        system.advance(60)
        #expect(system.calls.count == 2)
    }

    @Test func escapeOnceCleaningHasStartedDoesNothing() {
        let session = session()
        session.request()
        system.advance(3)
        session.cancel()
        guard case .cleaning = session.phase else { Issue.record("cancelled while cleaning"); return }
    }

    @Test func anInterruptionUndoesEverythingAtOnceAndOnlyOnce() {
        let session = session()
        session.request()
        system.advance(10)
        system.calls.removeAll()
        session.interrupt()
        session.interrupt()
        #expect(session.phase == .idle)
        #expect(system.calls == ["stopBlocking(drain: false)", "releaseCursor", "restoreCapsLock",
                                 "leave(completed: false)", "resumeMediaKeys"])
        system.advance(60)
        #expect(system.calls.count == 5)
    }

    @Test func itWaitsForHandsThenStartsAnywayAfterThreeSeconds() {
        system.hands = false
        let session = session()
        session.request()
        system.advance(3.1)
        #expect(session.phase == .waitingForHands)
        system.advance(3)
        guard case .cleaning = session.phase else { Issue.record("never started"); return }
    }

    @Test func itStartsAsSoonAsHandsLift() {
        system.hands = false
        let session = session()
        session.request()
        system.advance(3.5)
        system.hands = true
        system.advance(0.1)
        guard case .cleaning = session.phase else { Issue.record("still waiting"); return }
    }

    @Test func aRefusalAtTheEndOfTheLeadInStopsBeforeAnythingIsOff() {
        let session = session()
        session.request()
        system.refusalToGive = .refused(.secureInput)
        system.advance(3)
        #expect(session.phase == .refused(.secureInput))
        #expect(system.calls == ["enterLeadIn(30)", "leave(completed: false)"])
        // Straight to the card, without the usual panel flashing up in between.
        #expect(!system.phases.contains(.idle))
    }

    @Test func permissionLostDuringTheLeadInShowsThePermissionCard() {
        let session = session()
        session.request()
        system.refusalToGive = .needsPermission(prompted: false)
        system.advance(3)
        #expect(session.phase == .needsPermission(prompted: false))
        #expect(!system.calls.contains("startBlocking"))
    }

    @Test func aTapThatFailsPutsBackWhatWasDone() {
        system.blockingWorks = false
        let session = session()
        session.request()
        system.advance(3)
        #expect(session.phase == .refused(.tapFailed))
        #expect(system.calls == ["enterLeadIn(30)", "pauseMediaKeys", "saveCapsLock", "startBlocking",
                                 "stopBlocking(drain: false)", "releaseCursor", "restoreCapsLock",
                                 "leave(completed: false)", "resumeMediaKeys"])
    }

    @Test func secureInputStillOnAfterStartingEndsIt() {
        let session = session()
        session.request()
        system.advance(3)
        system.secureInput = true
        system.advance(0.3)
        #expect(session.phase == .refused(.secureInput))
        #expect(system.calls.contains("stopBlocking(drain: false)"))
    }

    @Test func thePanelIsHeldFromTheLeadInUntilBackOnIsGone() {
        let session = session()
        session.request()
        system.advance(3 + 30 + 2)
        #expect(system.phases.map(\.holdsPanel) == [true, true, true, false])
    }

    @Test func noSecondSessionWhileOneRuns() {
        let session = session()
        session.request()
        system.advance(3)
        session.request()
        #expect(system.calls.filter { $0.hasPrefix("enterLeadIn") }.count == 1)
    }
}

@MainActor
struct CleanKeyboardSettingTests {
    @Test(arguments: [(15, 15), (30, 30), (60, 60), (0, 30), (45, 30), (-1, 30)])
    func onlyTheOfferedLengthsAreKept(_ stored: Int, _ used: Int) {
        #expect(AppSettings.cleanKeyboardSeconds(stored: stored) == used)
    }

    @Test func cleaningTakesTheWingsFromEverything() {
        let activity = NotchViewModel.prioritise(cleaning: 42, transient: .volume(level: 0.5, muted: false),
                                                 timerDone: true, timerRunning: true, hasTrack: true,
                                                 isPlaying: true, recentlyPlayed: true, event: nil)
        #expect(activity == .cleaning(until: 42))
    }
}
