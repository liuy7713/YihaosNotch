import AppKit
import SwiftUI

@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    static let shared = WelcomeWindowController()

    /// Called when the welcome window closes, by its button or its close button.
    var onFinish: (() -> Void)?

    private var window: NSWindow?
    private var permissions: WelcomePermissions?
    private var makeView: ((_ permissions: WelcomePermissions, _ finish: @escaping () -> Void) -> WelcomeView)?

    func configure(settings: AppSettings, calendar: CalendarService, mediaKeys: MediaKeyController) {
        makeView = { permissions, finish in
            WelcomeView(settings: settings, calendar: calendar, mediaKeys: mediaKeys,
                        permissions: permissions, onFinish: finish)
        }
    }

    func show() {
        if window == nil, let makeView {
            let permissions = WelcomePermissions()
            let hosting = NSHostingController(rootView: makeView(permissions) { [weak self] in self?.window?.close() })
            hosting.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "Welcome to Yihao's Notch"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.backgroundColor = .black
            window.appearance = NSAppearance(named: .darkAqua)
            window.isReleasedWhenClosed = false
            window.delegate = self
            // Only the close button: the others would just sit there disabled.
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.center()
            self.window = window
            self.permissions = permissions
        }
        // The app normally has no Dock icon, so a welcome window buried under other
        // windows would be unreachable. It gets one while the welcome is open.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        permissions?.stopWatching()
        permissions = nil
        window = nil
        NSApp.setActivationPolicy(.accessory)
        onFinish?()
    }
}
