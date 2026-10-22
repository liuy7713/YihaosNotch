import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var makeView: (() -> SettingsView)?

    /// Called once at launch with the services the settings window controls.
    func configure(settings: AppSettings, calendar: CalendarService, mediaKeys: MediaKeyController) {
        makeView = { SettingsView(settings: settings, calendar: calendar, mediaKeys: mediaKeys) }
    }

    func show() {
        if window == nil, let makeView {
            let hosting = NSHostingController(rootView: makeView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "Yihao's Notch"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Dropping the window when it closes gives back its memory (about 16 MB); it's
    /// rebuilt the next time Settings opens.
    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
