import AppKit
import SwiftUI

/// The lengths the custom timer tile moves through: single minutes to 10, fives to an
/// hour, then quarter hours to three. The step only changes where people switch units
/// anyway, and fixed stops (rather than acceleration) mean the same gesture always
/// lands on the same value.
enum TimerDurations {
    static let stops: [Int] = Array(1...10) + Array(stride(from: 15, through: 60, by: 5))
        + Array(stride(from: 75, through: 180, by: 15))

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
}

/// Turns scroll-wheel and trackpad movement into single steps, like a picker wheel:
/// one stop per wheel notch or per stretch of trackpad travel, never several at once,
/// so every stop can be felt and seen. Pure, so it can be tested.
struct ScrollStepper {
    enum Phase { case began, changed, ended, momentum, none }

    /// Trackpad travel per stop. macOS accelerates quick swipes, so travel beyond one
    /// stop per event is dropped rather than saved up.
    var pointsPerStep: Double = 24
    /// A speed limit (25 stops a second), so a hard flick or a free-spinning wheel
    /// can't run through the whole scale.
    var minimumInterval: TimeInterval = 0.04
    private(set) var accumulated: Double = 0
    private var lastStep: TimeInterval = -.infinity

    /// `up` is travel with natural scrolling already undone: positive for fingers up or
    /// the wheel rolled away. `time` is the event's timestamp. Returns 1, -1 or 0.
    mutating func steps(up: Double, precise: Bool, phase: Phase, time: TimeInterval) -> Int {
        switch phase {
        // Momentum after the fingers lift would run past the value they chose.
        case .momentum: return 0
        case .began: accumulated = 0
        case .ended:
            accumulated = 0
            return 0
        case .changed, .none: break
        }
        guard up.isFinite, up != 0, time.isFinite else { return 0 }
        let direction: Int
        if precise {
            // Reversing first undoes travel not yet turned into a stop.
            accumulated = min(max(accumulated + up, -pointsPerStep), pointsPerStep)
            guard abs(accumulated) >= pointsPerStep else { return 0 }
            direction = accumulated > 0 ? 1 : -1
        } else {
            // A notched wheel: one stop per notch, however hard it's spun.
            direction = up > 0 ? 1 : -1
        }
        guard time - lastStep >= minimumInterval else { return 0 }
        lastStep = time
        accumulated = 0
        return direction
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
            let time = event.timestamp
            MainActor.assumeIsolated {
                let steps = stepper.steps(up: up, precise: precise, phase: phase, time: time)
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
