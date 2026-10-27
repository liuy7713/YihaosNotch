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
    /// not be: no camera, or one held exclusively by another app), and whether the
    /// camera's format can do Center Stage.
    func start(completion: @escaping @MainActor @Sendable (_ running: Bool, _ centerStageSupported: Bool) -> Void) {
        queue.async { [self] in
            configureIfNeeded()
            if !session.isRunning { session.startRunning() }
            let running = session.isRunning
            let supported = device?.activeFormat.isCenterStageSupported ?? false
            Task { @MainActor in completion(running, supported) }
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
    /// The camera can do Center Stage (follow and frame you as you move), as the
    /// built-in 12 MP Center Stage cameras can.
    private(set) var supportsCenterStage = false
    /// Center Stage is switched on for this app: the user's choice, which Control
    /// Center's Video Effects can change too. (Whether it's framing at this moment
    /// depends on the camera's current format, so it isn't what's shown or saved.)
    private(set) var isCenterStageEnabled = AppSettings.shared.cameraCenterStage
    @ObservationIgnored private let centerStageWatcher = CenterStageWatcher()
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
        // Before the camera starts, so the first frame is already framed rather than
        // zooming in a moment after the mirror appears. Harmless on cameras without it.
        applyCenterStage()
        capture.start { running, centerStageSupported in
            guard self.wantsRunning else { return }
            self.isUnavailable = !running
            self.supportsCenterStage = centerStageSupported
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

    private func applyCenterStage() {
        AVCaptureDevice.centerStageControlMode = .cooperative
        AVCaptureDevice.isCenterStageEnabled = AppSettings.shared.cameraCenterStage
        isCenterStageEnabled = AVCaptureDevice.isCenterStageEnabled
        // Control Center can switch it while the mirror is open; that's the user's
        // choice too, so it's followed and remembered.
        centerStageWatcher.onChange = { [weak self] enabled in
            guard let self else { return }
            isCenterStageEnabled = enabled
            AppSettings.shared.cameraCenterStage = enabled
        }
    }

    func deactivate() {
        wantsRunning = false
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

/// Observes the class-level `AVCaptureDevice.isCenterStageEnabled` (key
/// "centerStageEnabled"), which Control Center writes in cooperative mode. Swift's
/// block-based KVO only works on instances, so this is the classic kind. `onChange`
/// is only set and called on the main thread.
private final class CenterStageWatcher: NSObject, @unchecked Sendable {
    var onChange: (@MainActor (Bool) -> Void)?
    private let target = AVCaptureDevice.self as AnyObject as! NSObject

    override init() {
        super.init()
        target.addObserver(self, forKeyPath: "centerStageEnabled", options: [.new], context: nil)
    }

    deinit {
        target.removeObserver(self, forKeyPath: "centerStageEnabled")
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        let enabled = change?[.newKey] as? Bool ?? AVCaptureDevice.isCenterStageEnabled
        // In order, and only when the value differs from what's shown.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onChange?(enabled) }
        }
    }
}
