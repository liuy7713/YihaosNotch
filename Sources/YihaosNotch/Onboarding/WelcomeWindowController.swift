import AppKit
import SwiftUI

@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    static let shared = WelcomeWindowController()

    /// Called when the welcome window closes, by its button or its close button.
    var onFinish: (() -> Void)?

    private var window: NSWindow?
    private var makeView: ((_ finish: @escaping () -> Void) -> WelcomeView)?

    func configure(settings: AppSettings, calendar: CalendarService, mediaKeys: MediaKeyController) {
        makeView = { finish in
            WelcomeView(settings: settings, calendar: calendar, mediaKeys: mediaKeys, onFinish: finish)
        }
    }

    func show() {
        if window == nil, let makeView {
            let hosting = NSHostingController(rootView: makeView { [weak self] in self?.window?.close() })
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
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        onFinish?()
    }
}
