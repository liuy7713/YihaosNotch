import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    /// Called as Settings appears, so the open panel can fold away rather than sit on
    /// top of the window beneath it.
    var onShow: (() -> Void)?

    private var window: NSWindow?
    private var makeView: (() -> SettingsView)?
    private let frameName = "Settings"

    /// Called once at launch with the services the settings window controls.
    func configure(settings: AppSettings, calendar: CalendarService, mediaKeys: MediaKeyController) {
        makeView = { SettingsView(settings: settings, calendar: calendar, mediaKeys: mediaKeys) }
    }

    func show() {
        onShow?()
        if window == nil, let makeView {
            let hosting = NSHostingController(rootView: makeView())
            // The window is sized here, once and exactly, rather than by SwiftUI after it
            // appears (which shifts it sideways as it settles).
            hosting.sizingOptions = []
            let window = EscapeClosingWindow(contentViewController: hosting)
            window.title = "Yihao's Notch Settings"
            // Framed like the welcome window: black, a transparent title bar, and only
            // the close button.
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.backgroundColor = .black
            window.appearance = NSAppearance(named: .darkAqua)
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            // The view's size plus the transparent title bar it sits beneath (the content
            // runs under the title bar, so the content size is the whole window).
            let content = NSRect(x: 0, y: 0, width: SettingsView.width, height: SettingsView.height)
            window.setContentSize(NSWindow.frameRect(forContentRect: content, styleMask: [.titled, .closable]).size)
            // Wherever the user last left it; the first time, just under the notch.
            if !window.setFrameUsingName(frameName) { placeUnderNotch(window) }
            window.setFrameAutosaveName(frameName)
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Centred beneath the notch on the built-in display, so it reads as having come
    /// from it (and never lands on an external display that happens to be main).
    private func placeUnderNotch(_ window: NSWindow) {
        guard let screen = ScreenLocator.builtInScreen ?? NSScreen.main else {
            window.center()
            return
        }
        // Centred on the notch, which is the middle of the whole screen (a Dock at the
        // side moves the middle of the usable area).
        window.setFrameTopLeftPoint(NSPoint(x: screen.frame.midX - window.frame.width / 2,
                                            y: screen.visibleFrame.maxY - 24))
    }

    /// Dropping the window when it closes gives back its memory (about 16 MB); it's
    /// rebuilt the next time Settings opens.
    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

/// Closes on Esc, as a settings or onboarding window should. (⌘W comes from the
/// app's hidden main menu.)
final class EscapeClosingWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}
