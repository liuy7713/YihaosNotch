import AppKit

/// A single countdown timer. While it runs, the closed notch shows it in the wings.
@MainActor
@Observable
final class TimerService {
    enum Phase: Equatable {
        case idle
        case running(end: Date)
        case paused(remaining: TimeInterval)
    }

    private(set) var phase: Phase = .idle
    /// The full length, for the progress bar.
    private(set) var total: TimeInterval = 0

    @ObservationIgnored var onFinish: (() -> Void)?
    @ObservationIgnored private var fireTimer: Timer?
    @ObservationIgnored private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    init() {
        // Run-loop timers don't count time spent asleep, so a timer that should have
        // ended during sleep would fire late. Re-check on wake and on clock changes.
        let resync: @Sendable (Notification) -> Void = { _ in
            MainActor.assumeIsolated { self.resync() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: resync)))
        observers.append((NotificationCenter.default, NotificationCenter.default.addObserver(
            forName: .NSSystemClockDidChange, object: nil, queue: .main, using: resync)))
    }

    /// Longest timer: three hours, the custom tile's last stop. Past an hour the wings
    /// show "1h 30" (see `compactCountdownText`), as narrow as "mm:ss".
    nonisolated static let maxMinutes = 180

    var isActive: Bool { phase != .idle }

    var isPaused: Bool {
        if case .paused = phase { true } else { false }
    }

    func remaining(at date: Date = .now) -> TimeInterval {
        switch phase {
        case .idle: 0
        case .running(let end): max(end.timeIntervalSince(date), 0)
        case .paused(let remaining): remaining
        }
    }

    func start(minutes: Int) {
        total = TimeInterval(min(max(minutes, 1), Self.maxMinutes) * 60)
        run(for: total)
    }

    func pause() {
        guard case .running = phase else { return }
        phase = .paused(remaining: remaining())
        fireTimer?.invalidate()
    }

    func resume() {
        guard case .paused(let remaining) = phase else { return }
        run(for: remaining)
    }

    func addMinute() {
        let cap = TimeInterval(Self.maxMinutes * 60)
        let added = min(remaining() + 60, cap)
        total = max(total, added)
        switch phase {
        case .running: run(for: added)
        case .paused: phase = .paused(remaining: added)
        case .idle: break
        }
    }

    func cancel() {
        fireTimer?.invalidate()
        phase = .idle
    }

    /// Finishes a timer whose end has passed, or re-arms the one-shot for the time left.
    private func resync() {
        guard case .running(let end) = phase else { return }
        if end <= .now { finish() } else { run(for: end.timeIntervalSinceNow) }
    }

    private func run(for seconds: TimeInterval) {
        let end = Date.now + seconds
        phase = .running(end: end)
        fireTimer?.invalidate()
        // A one-shot timer at the end: nothing ticks while the countdown runs; the views
        // that show it schedule their own once-a-second redraw while visible.
        let timer = Timer(fire: end, interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { self.finish() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        fireTimer = timer
    }

    private func finish() {
        guard isActive else { return }
        fireTimer?.invalidate()
        phase = .idle
        NSSound(named: "Glass")?.play()
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        onFinish?()
    }
}

extension TimeInterval {
    /// 754 → "12:34", 5400 → "1:30:00". Rounds up, so a timer shows 0:00 only when
    /// it's done. An hour exactly is still "60:00", as the 60-minute preset starts.
    var countdownText: String {
        let total = Int(self.rounded(.up))
        guard total > 3600 else { return String(format: "%d:%02d", total / 60, total % 60) }
        return String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
    }

    /// For the wings and the header, which have room for "mm:ss" only: past an hour,
    /// "1h 30", with the minutes rounded up so it never reads less than what's left.
    var compactCountdownText: String {
        let total = Int(self.rounded(.up))
        guard total > 3600 else { return countdownText }
        let minutes = (total + 59) / 60
        return String(format: "%dh %02d", minutes / 60, minutes % 60)
    }
}
