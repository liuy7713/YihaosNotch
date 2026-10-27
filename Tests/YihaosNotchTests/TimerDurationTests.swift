import Testing
@testable import YihaosNotch

/// The custom timer tile's stops, and how scrolling becomes steps.
struct TimerDurationTests {
    @Test func stopsRunFromAMinuteToThreeHours() {
        #expect(TimerDurations.stops.first == 1)
        #expect(TimerDurations.stops.last == TimerService.maxMinutes)
        #expect(TimerDurations.stops == TimerDurations.stops.sorted())
        #expect(TimerDurations.stops.contains(TimerDurations.defaultCustom))
    }

    @Test func singleMinutesThenFivesThenQuarterHours() {
        #expect(TimerDurations.stops == Array(1...10) + [15, 20, 25, 30, 35, 40, 45, 50, 55, 60]
            + [75, 90, 105, 120, 135, 150, 165, 180])
    }

    @Test(arguments: [(9, 1, 10), (10, 1, 15), (15, -1, 10), (60, 1, 75), (75, 1, 90),
                      (1, -1, 1), (180, 1, 180), (60, -6, 30), (60, -12, 8)])
    func adjust(_ from: Int, _ steps: Int, _ expected: Int) {
        #expect(TimerDurations.adjust(from, by: steps) == expected)
    }

    @Test func aValueBetweenStopsMovesToItsNeighbours() {
        #expect(TimerDurations.adjust(22, by: 1) == 25)
        #expect(TimerDurations.adjust(22, by: -1) == 20)
        #expect(TimerDurations.adjust(500, by: -1) == 165)
    }

    @Test func aWheelMovesOneStopPerNotchHoweverHardItSpins() {
        var stepper = ScrollStepper()
        #expect(stepper.steps(up: 1, precise: false, phase: .none, time: 0) == 1)
        #expect(stepper.steps(up: -1, precise: false, phase: .none, time: 0.1) == -1)
        #expect(stepper.steps(up: 40, precise: false, phase: .none, time: 0.2) == 1)
    }

    @Test func trackpadTravelGivesOneStopAtATime() {
        var stepper = ScrollStepper(pointsPerStep: 24)
        #expect(stepper.steps(up: 0, precise: true, phase: .began, time: 0) == 0)
        #expect(stepper.steps(up: 20, precise: true, phase: .changed, time: 0.1) == 0)
        #expect(stepper.steps(up: 10, precise: true, phase: .changed, time: 0.2) == 1)
        // A big accelerated swipe is still one stop, and the excess isn't saved up.
        #expect(stepper.steps(up: 200, precise: true, phase: .changed, time: 0.3) == 1)
        #expect(stepper.steps(up: 1, precise: true, phase: .changed, time: 0.4) == 0)
    }

    @Test func goingBackFirstUndoesUnfinishedTravel() {
        var stepper = ScrollStepper(pointsPerStep: 24)
        #expect(stepper.steps(up: 20, precise: true, phase: .changed, time: 0) == 0)
        #expect(stepper.steps(up: -20, precise: true, phase: .changed, time: 0.1) == 0)
        #expect(stepper.steps(up: -24, precise: true, phase: .changed, time: 0.2) == -1)
    }

    @Test func stopsComeNoFasterThanTheSpeedLimit() {
        var stepper = ScrollStepper(minimumInterval: 0.04)
        #expect(stepper.steps(up: 1, precise: false, phase: .none, time: 1.00) == 1)
        #expect(stepper.steps(up: 1, precise: false, phase: .none, time: 1.02) == 0)
        #expect(stepper.steps(up: 1, precise: false, phase: .none, time: 1.05) == 1)
    }

    @Test func momentumAndNonsenseAreIgnored() {
        var stepper = ScrollStepper()
        #expect(stepper.steps(up: 100, precise: true, phase: .momentum, time: 0) == 0)
        #expect(stepper.steps(up: .nan, precise: true, phase: .changed, time: 0) == 0)
        #expect(stepper.steps(up: .infinity, precise: false, phase: .none, time: 0) == 0)
    }

    @Test func liftingTheFingersStartsAfresh() {
        var stepper = ScrollStepper(pointsPerStep: 24)
        _ = stepper.steps(up: 20, precise: true, phase: .changed, time: 0)
        _ = stepper.steps(up: 0, precise: true, phase: .ended, time: 0.1)
        #expect(stepper.steps(up: 20, precise: true, phase: .changed, time: 0.2) == 0)
    }
}
