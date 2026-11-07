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
    func configure(settings: AppSettings, calendar: CalendarService, mediaKeys: MediaKeyController,
                   updates: UpdateService) {
        makeView = { SettingsView(settings: settings, calendar: calendar, mediaKeys: mediaKeys, updates: updates) }
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
            if !window.setFrameUsingName(frameName) { window.placeUnderNotch() }
            window.setFrameAutosaveName(frameName)
            self.window = window
        }
        DockPresence.shared.show(for: "settings")
        window?.makeKeyAndOrderFront(nil)
    }

    /// Dropping the window when it closes gives back its memory (about 16 MB); it's
    /// rebuilt the next time Settings opens.
    func windowWillClose(_ notification: Notification) {
        window = nil
        DockPresence.shared.hide(for: "settings")
    }
}

/// Gives the app a Dock icon while any of its windows is open, and activates it.
///
/// The app normally has no Dock icon, and since macOS 14 such an app asking to be
/// activated is turned down while another app is in use: its window appears, but the
/// keyboard stays with the app beneath, so ⌘W, Esc and ⌘Q go there instead. With a
/// Dock icon the request is honoured (as for any app whose settings are open), and
/// the window can also be reached with ⌘Tab.
@MainActor
final class DockPresence {
    static let shared = DockPresence()
    private var holders: Set<String> = []

    func show(for holder: String) {
        holders.insert(holder)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func hide(for holder: String) {
        holders.remove(holder)
        if holders.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }
}

extension NSWindow {
    /// Centred beneath the notch on the built-in display, so it reads as having come
    /// from it (and never lands on an external display that happens to be main).
    func placeUnderNotch() {
        guard let screen = ScreenLocator.builtInScreen ?? NSScreen.main else {
            center()
            return
        }
        // Centred on the notch, which is the middle of the whole screen (a Dock at the
        // side moves the middle of the usable area).
        setFrameTopLeftPoint(NSPoint(x: screen.frame.midX - frame.width / 2,
                                     y: screen.visibleFrame.maxY - 24))
    }
}

/// Closes on Esc, as a settings or onboarding window should. (⌘W comes from the
/// app's main menu.)
final class EscapeClosingWindow: NSWindow {
    /// When false, Esc and ⌘W are ignored and only the close button closes the window:
    /// on the first welcome a stray key would otherwise skip the whole setup.
    var closesFromKeyboard = true

    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }

    override func performClose(_ sender: Any?) {
        if !closesFromKeyboard, NSApp.currentEvent?.type == .keyDown { return }
        super.performClose(sender)
    }
}
