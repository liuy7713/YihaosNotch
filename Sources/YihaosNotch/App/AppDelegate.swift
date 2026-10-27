import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings.shared
    private let nowPlaying = NowPlayingService()
    private let battery = BatteryService()
    private let calendar = CalendarService()
    private let camera = CameraController()
    private let timer = TimerService()
    private let mediaKeys = MediaKeyController()
    private let headphones = HeadphoneMonitor()
    private var viewModel: NotchViewModel!
    private var controller: NotchController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard SingleInstance.claim() else {
            NSApp.terminate(nil)
            return
        }
        viewModel = NotchViewModel(settings: settings, nowPlaying: nowPlaying, calendar: calendar, timer: timer)
        SettingsWindowController.shared.configure(settings: settings, calendar: calendar, mediaKeys: mediaKeys)
        WelcomeWindowController.shared.configure(settings: settings, calendar: calendar, mediaKeys: mediaKeys)
        WelcomeWindowController.shared.onFinish = { [weak self] in self?.welcomeFinished() }

        battery.onPowerEvent = { [viewModel, settings] event in
            guard settings.showBatteryActivity else { return }
            viewModel?.flash(event)
        }
        mediaKeys.onVolume = { [viewModel] level, muted in
            viewModel?.flash(.volume(level: level, muted: muted), seconds: 1.5)
        }
        mediaKeys.onBrightness = { [viewModel] level in
            viewModel?.flash(.brightness(level: level), seconds: 1.5)
        }
        headphones.onConnect = { [viewModel, settings] name, symbol in
            guard settings.showHeadphonesActivity else { return }
            viewModel?.flash(.headphones(name: name, symbol: symbol), seconds: 3)
        }
        timer.onFinish = { [viewModel] in
            viewModel?.flash(.timerDone, seconds: 6)
        }

        let root = NotchRootView()
            .environment(viewModel)
            .environment(settings)
            .environment(nowPlaying)
            .environment(battery)
            .environment(calendar)
            .environment(camera)
            .environment(timer)

        let controller = NotchController(viewModel: viewModel, settings: settings, content: AnyView(root))
        controller.onOpen = { [nowPlaying, calendar] in
            nowPlaying.refreshPosition()
            calendar.noteOpened()
        }
        controller.onUserLeft = { [camera] in camera.deactivate() }
        controller.start()
        self.controller = controller
        SettingsWindowController.shared.onShow = { [weak controller] in controller?.dismissPanel() }
        NSApp.mainMenu = Self.makeMainMenu()
        mediaKeys.canShowHUD = { [weak controller] in controller?.canShowLiveActivity ?? false }

        // Until the welcome screen is done, nothing that would raise a permission prompt
        // runs: it asks for each one itself, with a reason. (Reading the players sends
        // them Apple events, which prompts.)
        let welcoming = settings.needsWelcome
        if !welcoming { nowPlaying.start() }
        battery.start()
        // Never asks at launch (which is often login): the welcome, the notch's Connect
        // Calendar button and Settings ask, when the user is looking.
        if settings.calendarEnabled { calendar.start(requestingAccess: false) }
        headphones.start()
        // Silent at launch: the permission prompt only ever comes from a toggle.
        if settings.replaceSystemHUD { mediaKeys.enable(prompt: false) }
        if welcoming || CommandLine.arguments.contains("--preview-welcome") {
            WelcomeWindowController.shared.show()
        }
        // Development aid: `--preview-settings` opens Settings at launch.
        if CommandLine.arguments.contains("--preview-settings") { SettingsWindowController.shared.show() }
        runPreviewFlags()
    }

    private func welcomeFinished() {
        guard settings.needsWelcome else { return }
        settings.completeWelcome()
        nowPlaying.start()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.6))
            self?.controller?.greet()
        }
    }

    /// Development aids for checking visuals without pressing keys or clicking:
    /// `--preview-timer` starts a 25-minute timer and shows the timer view when the panel
    /// opens; `--preview-swap` (below); `--preview-hud` cycles the volume, brightness, headphone and charging indicators
    /// (the charging one shows the real power state) with sample values (the real volume and brightness are never touched).
    private func runPreviewFlags() {
        let arguments = CommandLine.arguments
        if arguments.contains("--preview-timer") {
            timer.start(minutes: 25)
            Task { [viewModel] in
                try? await Task.sleep(for: .seconds(0.5))
                viewModel?.showingTimer = true
            }
        }
        // `--preview-swap` flips the right column between calendar and timer every 2 s,
        // for checking the swap transition (the camera is deliberately left out).
        if arguments.contains("--preview-swap") {
            Task { [viewModel] in
                while true {
                    try? await Task.sleep(for: .seconds(2))
                    viewModel?.showingTimer.toggle()
                }
            }
        }
        if arguments.contains("--preview-hud") {
            Task { [viewModel] in
                let samples: [LiveActivity] = [
                    .volume(level: 0.5, muted: false),
                    .brightness(level: 0.75),
                    .headphones(name: "AirPods Pro", symbol: HeadphoneMonitor.symbol(for: "AirPods Pro")),
                    .charging(level: 0),
                ]
                while true {
                    for sample in samples {
                        try? await Task.sleep(for: .seconds(2))
                        viewModel?.flash(sample, seconds: 1.8)
                    }
                }
            }
        }
    }

    /// Shown only while Settings or the welcome is open (the app has a menu bar only
    /// then). It gives those windows the standard keys: ⌘, for Settings, ⌘W to close,
    /// and editing.
    ///
    /// ⌘Q closes the window rather than quitting: with a Dock icon showing, it's an
    /// easy way to dismiss Settings, but quitting would silently stop the notch until
    /// the next login. Quit is still in this menu, Settings and the Dock menu.
    private static func makeMainMenu() -> NSMenu {
        func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title)
            items.forEach(submenu.addItem)
            item.submenu = submenu
            return item
        }
        let main = NSMenu()
        main.addItem(menu("Yihao's Notch", [
            NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ","),
            .separator(),
            NSMenuItem(title: "Quit Yihao's Notch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""),
            closeOnCommandQ,
        ]))
        main.addItem(menu("Edit", [
            NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
            NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
            NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
        ]))
        main.addItem(menu("Window", [
            NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"),
        ]))
        return main
    }

    private static var closeOnCommandQ: NSMenuItem {
        let item = NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "q")
        item.isHidden = true
        item.allowsKeyEquivalentWhenHidden = true
        return item
    }

    @objc private func showSettings() {
        SettingsWindowController.shared.show()
    }

    // Opening the app again (e.g. from Finder or Spotlight) shows Settings, or the
    // welcome if it hasn't been finished.
    // An update dragged over the running copy reaches it here too, so that starts the
    // new version instead.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if SingleInstance.relaunchIfUpdated() { return false }
        if settings.needsWelcome {
            WelcomeWindowController.shared.show()
        } else {
            SettingsWindowController.shared.show()
        }
        return false
    }
}
