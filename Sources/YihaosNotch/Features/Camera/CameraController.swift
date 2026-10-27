import AppKit
import AVFoundation

/// Wraps the capture session. All session work happens on a private serial queue,
/// as AVFoundation requires.
final class CaptureSession: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.yihao.YihaosNotch.camera")
    private var configured = false
    private var device: AVCaptureDevice?

    /// Starts the session and reports on the main actor whether it's running (it may
    /// not be: no camera, or one held exclusively by another app), and the camera.
    func start(completion: @escaping @MainActor @Sendable (_ running: Bool, _ device: AVCaptureDevice?) -> Void) {
        queue.async { [self] in
            configureIfNeeded()
            if !session.isRunning { session.startRunning() }
            let running = session.isRunning
            nonisolated(unsafe) let device = self.device
            Task { @MainActor in completion(running, device) }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configureIfNeeded() {
        guard !configured else { return }
        // Prefer the built-in FaceTime camera over Continuity Camera.
        let builtIn = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified
        ).devices.first
        guard let device = builtIn ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device)
        else { return }
        session.beginConfiguration()
        // 720p is plenty for a mirror a few hundred points wide, and lighter than `.high`.
        session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .medium
        if session.canAddInput(input) { session.addInput(input) }
        session.commitConfiguration()
        self.device = device
        configured = true
    }
}

/// The camera only runs while the mirror is on screen.
@MainActor
@Observable
final class CameraController {
    enum Access { case notDetermined, granted, denied }

    private(set) var access: Access = CameraController.currentAccess()
    /// True once the session is actually running, so the picture can fade in rather
    /// than showing black while the camera warms up.
    private(set) var isLive = false
    /// The camera couldn't be started (missing, or in use elsewhere), so the mirror
    /// says so instead of waiting on a placeholder.
    private(set) var isUnavailable = false
    /// The camera can do Center Stage (follow and frame you as you move): the 12 MP
    /// Center Stage cameras, the Studio Display, an iPhone as webcam.
    private(set) var supportsCenterStage = false
    /// Center Stage is actually framing the picture right now.
    private(set) var isCenterStageActive = false
    @ObservationIgnored private var centerStageObservation: NSKeyValueObservation?
    @ObservationIgnored let capture = CaptureSession()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        for (name, live) in [(AVCaptureSession.didStartRunningNotification, true),
                             (AVCaptureSession.didStopRunningNotification, false)] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: capture.session, queue: .main
            ) { _ in
                MainActor.assumeIsolated { self.isLive = live }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: capture.session, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                self.isLive = false
                self.isUnavailable = true
            }
        })
    }
    /// True while the mirror is on screen. The permission prompt can outlive the
    /// mirror (the notch closes while you click Allow), so the camera starts only if
    /// the mirror is still showing once access is granted.
    @ObservationIgnored private var wantsRunning = false

    func activate() {
        wantsRunning = true
        // Re-read each time, so access granted later in System Settings is picked up.
        access = Self.currentAccess()
        isUnavailable = false
        switch access {
        case .granted:
            startCapture()
        case .notDetermined:
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                access = granted ? .granted : .denied
                if granted, wantsRunning { startCapture() }
            }
        case .denied:
            break
        }
    }

    private func startCapture() {
        capture.start { running, device in
            guard self.wantsRunning else { return }
            self.isUnavailable = !running
            if let device { self.prepareCenterStage(for: device) }
        }
    }

    // MARK: Center Stage

    /// Turns Center Stage on or off for this app and remembers the choice. It's the
    /// same switch as Video Effects in Control Center ("cooperative" control), so the
    /// two stay in step.
    func setCenterStage(_ enabled: Bool) {
        AppSettings.shared.cameraCenterStage = enabled
        applyCenterStage()
    }

    private func prepareCenterStage(for device: AVCaptureDevice) {
        supportsCenterStage = device.activeFormat.isCenterStageSupported
        guard supportsCenterStage else { return }
        applyCenterStage()
        isCenterStageActive = device.isCenterStageActive
        // Follows changes made from Control Center too, and keeps the choice in step.
        centerStageObservation = device.observe(\.isCenterStageActive, options: [.new]) { _, change in
            let active = change.newValue ?? false
            Task { @MainActor in
                self.isCenterStageActive = active
                if self.wantsRunning { AppSettings.shared.cameraCenterStage = active }
            }
        }
    }

    private func applyCenterStage() {
        guard supportsCenterStage else { return }
        AVCaptureDevice.centerStageControlMode = .cooperative
        AVCaptureDevice.isCenterStageEnabled = AppSettings.shared.cameraCenterStage
    }

    func deactivate() {
        wantsRunning = false
        centerStageObservation = nil
        capture.stop()
    }

    func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!
        NSWorkspace.shared.open(url)
    }

    private static func currentAccess() -> Access {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }
}
