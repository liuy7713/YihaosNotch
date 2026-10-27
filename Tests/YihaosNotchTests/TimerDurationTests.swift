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

    @Test(arguments: [(19, 1, 20), (20, 1, 25), (25, -1, 20), (60, 1, 75), (90, 1, 120),
                      (1, -1, 1), (180, 1, 180), (10, 3, 13), (60, -9, 19)])
    func adjust(_ from: Int, _ steps: Int, _ expected: Int) {
        #expect(TimerDurations.adjust(from, by: steps) == expected)
    }

    @Test func aValueBetweenStopsMovesToItsNeighbours() {
        #expect(TimerDurations.adjust(22, by: 1) == 25)
        #expect(TimerDurations.adjust(22, by: -1) == 20)
        #expect(TimerDurations.adjust(500, by: -1) == 150)
    }

    @Test(arguments: [(45, "45"), (60, "1h"), (75, "1h 15"), (150, "2h 30"), (180, "3h")])
    func label(_ minutes: Int, _ expected: String) {
        #expect(TimerDurations.label(minutes) == expected)
    }

    @Test func aWheelMovesOneStepPerNotch() {
        var stepper = ScrollStepper()
        #expect(stepper.steps(up: 1, precise: false, phase: .none) == 1)
        #expect(stepper.steps(up: -1, precise: false, phase: .none) == -1)
        #expect(stepper.steps(up: 40, precise: false, phase: .none) == stepper.maxStepsPerEvent)
    }

    @Test func trackpadTravelAddsUpAndCarriesTheRemainder() {
        var stepper = ScrollStepper(pointsPerStep: 14)
        #expect(stepper.steps(up: 0, precise: true, phase: .began) == 0)
        #expect(stepper.steps(up: 10, precise: true, phase: .changed) == 0)
        #expect(stepper.steps(up: 10, precise: true, phase: .changed) == 1)
        // 6 pt left over; going back first undoes that.
        #expect(stepper.steps(up: -10, precise: true, phase: .changed) == 0)
        #expect(stepper.steps(up: -14, precise: true, phase: .changed) == -1)
    }

    @Test func momentumAndNonsenseAreIgnored() {
        var stepper = ScrollStepper()
        #expect(stepper.steps(up: 100, precise: true, phase: .momentum) == 0)
        #expect(stepper.steps(up: .nan, precise: true, phase: .changed) == 0)
        #expect(stepper.steps(up: .infinity, precise: false, phase: .none) == 0)
    }

    @Test func liftingTheFingersStartsAfresh() {
        var stepper = ScrollStepper(pointsPerStep: 14)
        _ = stepper.steps(up: 10, precise: true, phase: .changed)
        _ = stepper.steps(up: 0, precise: true, phase: .ended)
        #expect(stepper.steps(up: 10, precise: true, phase: .changed) == 0)
    }
}
