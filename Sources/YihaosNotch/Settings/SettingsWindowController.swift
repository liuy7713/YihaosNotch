import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show(settings: AppSettings, calendar: CalendarService) {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(settings: settings, calendar: calendar))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Yihao's Notch"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
