import AppKit
import SwiftUI

@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    static let shared = WelcomeWindowController()

    /// Called when the welcome window closes, by its button or its close button.
    var onFinish: (() -> Void)?

    private var window: NSWindow?
    private var permissions: WelcomePermissions?
    private var settings: AppSettings?
    private var makeView: ((_ page: Int, _ permissions: WelcomePermissions, _ finish: @escaping () -> Void) -> WelcomeView)?

    func configure(settings: AppSettings, calendar: CalendarService, mediaKeys: MediaKeyController) {
        self.settings = settings
        makeView = { page, permissions, finish in
            WelcomeView(settings: settings, calendar: calendar, mediaKeys: mediaKeys,
                        permissions: permissions, onFinish: finish, startPage: page)
        }
    }

    /// Opens the welcome at `page` (Settings' Help opens it at the tour, page 1). If
    /// it's already open, it's just brought forward where it is.
    func show(page: Int = WelcomeView.previewPage) {
        if window == nil, let makeView {
            let permissions = WelcomePermissions(firstRun: settings?.needsWelcome ?? true)
            let hosting = NSHostingController(rootView: makeView(page, permissions) { [weak self] in self?.window?.close() })
            hosting.sizingOptions = [.preferredContentSize]
            let window = EscapeClosingWindow(contentViewController: hosting)
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
        // A Dock icon while it's open: it can't be buried out of reach, and it gets the
        // keyboard (see DockPresence).
        DockPresence.shared.show(for: "welcome")
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        permissions?.stopWatching()
        permissions?.applyLaunchAtLogin()
        permissions = nil
        window = nil
        DockPresence.shared.hide(for: "welcome")
        onFinish?()
    }
}
