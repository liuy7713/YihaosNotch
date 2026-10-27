import AppKit
import SwiftUI

/// The lengths the custom timer tile moves through: every minute to 20, every five to
/// an hour, then a few long ones. Fixed stops rather than acceleration, so the same
/// gesture always lands on the same value.
enum TimerDurations {
    static let stops: [Int] = Array(1...20) + Array(stride(from: 25, through: 60, by: 5)) + [75, 90, 120, 150, 180]

    static let defaultCustom = 60

    /// Moves `steps` stops from `minutes`, stopping at either end. A value between
    /// stops (from an older version, say) moves to the neighbouring stop first.
    static func adjust(_ minutes: Int, by steps: Int) -> Int {
        guard steps != 0 else { return minutes }
        let above = stops.firstIndex { $0 >= minutes } ?? stops.count - 1
        let index: Int
        if stops[above] == minutes {
            index = above + steps
        } else {
            // Between stops[above - 1] and stops[above].
            index = steps > 0 ? above + steps - 1 : above + steps
        }
        return stops[min(max(index, 0), stops.count - 1)]
    }

    /// The custom tile's number: minutes below an hour, then "1h 15", "2h".
    static func label(_ minutes: Int) -> String {
        guard minutes >= 60 else { return "\(minutes)" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)"
    }
}

/// Turns scroll-wheel and trackpad movement into whole steps. Pure, so it can be tested.
struct ScrollStepper {
    enum Phase { case began, changed, ended, momentum, none }

    /// Trackpad travel per step. macOS already accelerates precise deltas, so slow
    /// movement gives single steps and a quick swipe several.
    var pointsPerStep: Double = 14
    /// A free-spinning wheel or a hard flick moves at most this far per event.
    var maxStepsPerEvent = 5
    private(set) var accumulated: Double = 0

    /// `up` is travel with natural scrolling already undone: positive for fingers up or
    /// the wheel rolled away. Returns the steps to take (negative for down).
    mutating func steps(up: Double, precise: Bool, phase: Phase) -> Int {
        switch phase {
        // Momentum after the fingers lift would run past the value they chose.
        case .momentum: return 0
        case .began: accumulated = 0
        case .ended:
            accumulated = 0
            return 0
        case .changed, .none: break
        }
        guard up.isFinite, up != 0 else { return 0 }
        guard precise else {
            // A notched wheel: one step per notch, a few more when spun fast.
            let notches = min(max(Int(up.magnitude.rounded(.up)), 1), maxStepsPerEvent)
            return up > 0 ? notches : -notches
        }
        accumulated += up
        let whole = Int((accumulated / pointsPerStep).rounded(.towardZero))
        // The remainder carries over, so reversing direction first undoes it.
        accumulated -= Double(whole) * pointsPerStep
        return min(max(whole, -maxStepsPerEvent), maxStepsPerEvent)
    }
}

extension ScrollStepper.Phase {
    init(_ event: NSEvent) {
        if !event.momentumPhase.isEmpty {
            self = .momentum
        } else if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            self = .began
        } else if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            self = .ended
        } else if event.phase.contains(.changed) {
            self = .changed
        } else {
            // Mouse wheels have no phase.
            self = .none
        }
    }
}

extension View {
    /// Calls `action` with whole steps as the user scrolls over this view: up or away
    /// is positive. SwiftUI has no scroll-wheel modifier on macOS, so a local event
    /// monitor runs, only while the pointer is over the view, and takes those scrolls.
    func onScrollSteps(_ action: @escaping @MainActor (Int) -> Void) -> some View {
        modifier(ScrollStepsModifier(action: action))
    }
}

private struct ScrollStepsModifier: ViewModifier {
    let action: @MainActor (Int) -> Void

    @State private var monitor: Any?
    @State private var stepper = ScrollStepper()

    func body(content: Content) -> some View {
        content
            .onHover { $0 ? install() : remove() }
            .onDisappear { remove() }
    }

    private func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            // Only the notch's own panel, and mostly vertical scrolls.
            guard event.window is NotchPanel, abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
            else { return event }
            let deltaY = Double(event.scrollingDeltaY)
            // As in NotchController.scrolled: natural scrolling flips the sign.
            let up = event.isDirectionInvertedFromDevice ? -deltaY : deltaY
            let precise = event.hasPreciseScrollingDeltas
            let phase = ScrollStepper.Phase(event)
            MainActor.assumeIsolated {
                let steps = stepper.steps(up: up, precise: precise, phase: phase)
                if steps != 0 { action(steps) }
            }
            return nil
        }
    }

    private func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        stepper = ScrollStepper()
    }
}
