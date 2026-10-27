import AppKit
import SwiftUI

/// Owns the overlay panel and turns pointer movement into notch state changes.
///
/// Hover mode: resting on the notch arms it (it swells slightly), and after
/// `hoverDelay` it opens with a haptic tick. Click mode: hovering only arms it, and a
/// click opens it. In both modes a two-finger swipe down on the notch opens it
/// immediately, and moving away closes it.
@MainActor
final class NotchController {
    var onOpen: (() -> Void)?

    private let viewModel: NotchViewModel
    private let settings: AppSettings
    private let content: AnyView
    private var panel: NotchPanel?
    private var gesturePanel: NotchGesturePanel?
    /// Downward finger travel accumulated during the current scroll gesture.
    private var swipeDistance: CGFloat = 0
    private var screenFrame: CGRect = .zero
    private var observers: [NSObjectProtocol] = []
    private var armTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var safetyTimer: Timer?
    /// Global mouse-move monitor, installed only while armed or open. When closed,
    /// the gesture window's tracking area reports the pointer reaching the notch, so
    /// mouse movement elsewhere on the system costs the app nothing.
    private var moveMonitor: Any?
    /// Global click monitor, for closing the panel on a click elsewhere. Like the move
    /// monitor it exists only while armed or open, so clicks elsewhere don't wake the
    /// app the rest of the time.
    private var clickMonitor: Any?
    /// After waking from sleep, a pointer that was left resting on the notch shouldn't
    /// open it by itself.
    private var armSuppressedUntil = Date.distantPast
    /// While set, the panel stays open wherever the pointer is (see `greet`).
    private var greetingUntil = Date.distantPast

    /// Development aid: `--preview-open` opens the panel at launch and keeps it open,
    /// so it can be screenshotted without hovering.
    private let pinnedOpen = CommandLine.arguments.contains("--preview-open")
    /// Development aid: `--preview-cycle` opens and closes the notch on a loop, so the
    /// animations can be recorded and tuned. Pointer-driven closing is off in this mode,
    /// so the panel really stays open for the full interval.
    private let previewCycle = CommandLine.arguments.contains("--preview-cycle")
    /// Development aid: `--simulate-notch 140x24` lays everything out as if the notch
    /// were that size in points, to check other MacBooks and display scalings (a 14"
    /// ranges from about 140×24 at "Larger Text" to 225×38 at "More Space").
    private let simulatedNotch: CGSize? = {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--simulate-notch"), index + 1 < arguments.count
        else { return nil }
        let parts = arguments[index + 1].split(separator: "x").compactMap { Double($0) }
        return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : nil
    }()

    /// Room around the open shape for its shadow. The panel window is exactly the open
    /// hit area, so clicks just outside the visible panel are never swallowed by a
    /// transparent margin.
    private let sidePadding: CGFloat = 10
    private let bottomPadding: CGFloat = 14

    init(viewModel: NotchViewModel, settings: AppSettings, content: AnyView) {
        self.viewModel = viewModel
        self.settings = settings
        self.content = content
    }

    func start() {
        layout()
        observeShape()

        let relayout: @Sendable (Notification) -> Void = { _ in
            MainActor.assumeIsolated { self.layout() }
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: relayout))
        // Windows above the menu bar can lose their ordering after sleep or a Space switch.
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                self.armSuppressedUntil = .now + 1
                self.layout()
            }
        })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main, using: relayout))

        if pinnedOpen { open() }
        if previewCycle { runPreviewCycle() }
    }

    private func runPreviewCycle() {
        Task {
            while true {
                try? await Task.sleep(for: .seconds(1.5))
                open()
                try? await Task.sleep(for: .seconds(1.5))
                close()
            }
        }
    }

    /// True while the closed notch is on screen and could show a live activity, i.e.
    /// not hidden (lid closed, no notch) and not covered by the open panel.
    var canShowLiveActivity: Bool {
        screenFrame != .zero && viewModel.state != .open
    }

    // MARK: Layout

    /// Places the panels at the top centre of the built-in display, or hides them and
    /// resets when that display or its notch isn't available (lid closed, or a scaled
    /// resolution without a notch).
    private func layout() {
        guard let screen = ScreenLocator.builtInScreen,
              let notch = simulatedNotch ?? ScreenLocator.notchSize(on: screen)
        else {
            hideAndReset()
            return
        }
        viewModel.notchSize = notch
        screenFrame = screen.frame

        let width = viewModel.openSize.width + viewModel.openTopRadius * 2 + sidePadding * 2
        let height = viewModel.openSize.height + bottomPadding
        let frame = CGRect(x: screenFrame.midX - width / 2, y: screenFrame.maxY - height,
                           width: width, height: height)

        let panel = self.panel ?? {
            let p = NotchPanel(contentRect: frame)
            let host = NotchHostingView(rootView: content)
            host.onPointerCrossing = { [weak self] in self?.pointerMoved() }
            p.contentView = host
            self.panel = p
            return p
        }()
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()

        let gesturePanel = self.gesturePanel ?? {
            let p = NotchGesturePanel(
                onCrossing: { [weak self] in self?.pointerMoved() },
                onScroll: { [weak self] event in self?.scrolled(event) },
                onClick: { [weak self] in self?.open() }
            )
            self.gesturePanel = p
            return p
        }()
        gesturePanel.orderFrontRegardless()
        updateGesturePanel()

        // A pointer already sitting where a panel just moved gets no "entered" event.
        pointerMoved()
    }

    private func hideAndReset() {
        armTask?.cancel()
        closeTask?.cancel()
        closeTask = nil
        stopPointerTracking()
        viewModel.state = .closed
        viewModel.showingCamera = false
        viewModel.showingTimer = false
        panel?.ignoresMouseEvents = true
        panel?.orderOut(nil)
        gesturePanel?.orderOut(nil)
        screenFrame = .zero
    }

    /// Keeps the invisible gesture window matched to the visible black shape, so a
    /// click on the notch or its live-activity wings lands on us and never on the
    /// menu-bar item hidden underneath.
    private func updateGesturePanel() {
        guard let gesturePanel, screenFrame != .zero else { return }
        let notch = viewModel.notchSize
        let rect: CGRect
        switch viewModel.state {
        case .open:
            gesturePanel.ignoresMouseEvents = true
            return
        case .arming:
            rect = topCenteredRect(width: viewModel.closedWidth + 20, height: notch.height + 6)
        case .closed:
            // Covers the whole closed shape, so its tracking area can report the pointer
            // arriving (see `moveMonitor`). Over a bare notch it also covers the notch's
            // rounded bottom corners: a few menu-bar pixels, at 0.01 alpha.
            rect = topCenteredRect(width: viewModel.closedWidth, height: notch.height)
        }
        gesturePanel.setFrame(rect, display: false)
        gesturePanel.ignoresMouseEvents = false
    }

    /// Re-runs `updateGesturePanel` whenever the shape's size or state changes.
    private func observeShape() {
        withObservationTracking {
            _ = viewModel.state
            _ = viewModel.closedWidth
        } onChange: {
            Task { @MainActor in
                self.updateGesturePanel()
                self.observeShape()
            }
        }
    }

    // MARK: Hit areas (screen coordinates)

    private func topCenteredRect(width: CGFloat, height: CGFloat) -> CGRect {
        // +1 so the very top row of pixels counts as inside.
        CGRect(x: screenFrame.midX - width / 2, y: screenFrame.maxY - height, width: width, height: height + 1)
    }

    private var closedHitRect: CGRect {
        topCenteredRect(width: viewModel.closedWidth + 12, height: viewModel.notchSize.height + 2)
    }

    private var armedHitRect: CGRect {
        topCenteredRect(width: viewModel.closedWidth + 44, height: viewModel.notchSize.height + 14)
    }

    private var openHitRect: CGRect {
        topCenteredRect(width: viewModel.openSize.width + viewModel.openTopRadius * 2 + sidePadding * 2,
                        height: viewModel.openSize.height + bottomPadding)
    }

    // MARK: Pointer handling

    private func pointerMoved() {
        guard screenFrame != .zero else { return }
        let p = NSEvent.mouseLocation
        switch viewModel.state {
        case .closed:
            guard p.y > screenFrame.maxY - 60, closedHitRect.contains(p),
                  Date.now >= armSuppressedUntil
            else { return }
            // Dragging a file or a selection past the notch shouldn't open it.
            guard NSEvent.pressedMouseButtons == 0 else { return }
            arm()
        case .arming:
            if !armedHitRect.contains(p) { disarm() }
        case .open:
            if openHitRect.contains(p) {
                closeTask?.cancel()
                closeTask = nil
            } else if closeTask == nil, !previewCycle, Date.now >= greetingUntil {
                scheduleClose()
            }
        }
    }

    /// Clicks on the notch itself land on the gesture window (see `updateGesturePanel`),
    /// so the global monitor only matters for closing the panel on an outside click.
    private func clickedElsewhere() {
        guard viewModel.state == .open, !previewCycle, !openHitRect.contains(NSEvent.mouseLocation) else { return }
        close()
    }

    /// Two-finger swipe down on the notch opens it straight away. Momentum events and
    /// mostly sideways scrolls are ignored.
    private func scrolled(_ event: NSEvent) {
        guard viewModel.state != .open else { return }
        if event.phase == .began || event.phase == .mayBegin { swipeDistance = 0 }
        guard event.momentumPhase.isEmpty else { return }

        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 10
            // With natural scrolling, fingers moving down produce positive deltas.
            swipeDistance += event.isDirectionInvertedFromDevice ? delta : -delta
        }
        if swipeDistance > 6 {
            swipeDistance = 0
            open()
        }
        if event.phase == .ended || event.phase == .cancelled { swipeDistance = 0 }
    }

    /// Folds the panel away (Settings is opening beneath it). The pointer may still be
    /// near the notch, so it isn't allowed to reopen it straight away.
    func dismissPanel() {
        guard viewModel.state == .open else { return }
        armSuppressedUntil = .now + 1
        close()
    }

    /// Opens the panel for a few seconds wherever the pointer is, so someone who has
    /// just finished the welcome screen sees where the app lives.
    func greet() {
        greetingUntil = .now + 2.5
        open()
        Task {
            try? await Task.sleep(for: .seconds(2.6))
            pointerMoved()
        }
    }

    private func arm() {
        viewModel.state = .arming
        startPointerTracking()
        guard settings.openTrigger == .hover else { return }
        armTask?.cancel()
        armTask = Task { [weak self, delay = settings.hoverDelay] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.viewModel.state == .arming else { return }
            self.open()
        }
    }

    private func disarm() {
        armTask?.cancel()
        viewModel.state = .closed
        stopPointerTracking()
    }

    private func open() {
        armTask?.cancel()
        closeTask?.cancel()
        closeTask = nil
        guard viewModel.state != .open, screenFrame != .zero else { return }
        viewModel.showingCamera = false
        viewModel.showingTimer = false
        viewModel.state = .open
        panel?.ignoresMouseEvents = false
        if settings.hapticsEnabled {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        startPointerTracking()
        onOpen?()
    }

    private func scheduleClose() {
        let grace = settings.openTrigger == .hover ? 0.15 : 0.4
        closeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(grace))
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }

    private func close() {
        guard !pinnedOpen else { return }
        closeTask?.cancel()
        closeTask = nil
        viewModel.state = .closed
        panel?.ignoresMouseEvents = true
        stopPointerTracking()
    }

    /// While armed or open: a global monitor follows the pointer over other apps, and
    /// tracking areas on both windows report it crossing ours. The slow poll only guards
    /// against a missed event leaving the notch stuck armed or open.
    private func startPointerTracking() {
        if moveMonitor == nil {
            moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { _ in
                MainActor.assumeIsolated { self.pointerMoved() }
            }
        }
        if clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { _ in
                MainActor.assumeIsolated { self.clickedElsewhere() }
            }
        }
        guard safetyTimer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { self.pointerMoved() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        safetyTimer = timer
    }

    private func stopPointerTracking() {
        if let moveMonitor { NSEvent.removeMonitor(moveMonitor) }
        moveMonitor = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        safetyTimer?.invalidate()
        safetyTimer = nil
    }
}
