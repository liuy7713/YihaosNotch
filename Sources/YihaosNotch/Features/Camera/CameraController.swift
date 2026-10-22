import AppKit
import AVFoundation

/// Wraps the capture session. All session work happens on a private serial queue,
/// as AVFoundation requires.
final class CaptureSession: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.yihao.YihaosNotch.camera")
    private var configured = false

    func start() {
        queue.async { [self] in
            configureIfNeeded()
            if !session.isRunning { session.startRunning() }
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
    }
    /// True while the mirror is on screen. The permission prompt can outlive the
    /// mirror (the notch closes while you click Allow), so the camera starts only if
    /// the mirror is still showing once access is granted.
    @ObservationIgnored private var wantsRunning = false

    func activate() {
        wantsRunning = true
        // Re-read each time, so access granted later in System Settings is picked up.
        access = Self.currentAccess()
        switch access {
        case .granted:
            capture.start()
        case .notDetermined:
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                access = granted ? .granted : .denied
                if granted, wantsRunning { capture.start() }
            }
        case .denied:
            break
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
