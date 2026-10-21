import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings.shared
    private let nowPlaying = NowPlayingService()
    private let battery = BatteryService()
    private let calendar = CalendarService()
    private let camera = CameraController()
    private var viewModel: NotchViewModel!
    private var controller: NotchController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        viewModel = NotchViewModel(settings: settings, nowPlaying: nowPlaying, calendar: calendar)

        battery.onPowerEvent = { [viewModel, settings] event in
            guard settings.showBatteryActivity else { return }
            viewModel?.flash(event)
        }

        let root = NotchRootView()
            .environment(viewModel)
            .environment(settings)
            .environment(nowPlaying)
            .environment(battery)
            .environment(calendar)
            .environment(camera)

        let controller = NotchController(viewModel: viewModel, settings: settings, content: AnyView(root))
        controller.onOpen = { [nowPlaying, calendar] in
            nowPlaying.refreshPosition()
            calendar.noteOpened()
        }
        controller.start()
        self.controller = controller

        nowPlaying.start()
        battery.start()
        if settings.calendarEnabled { calendar.start() }
    }

    // Opening the app again (e.g. from Finder or Spotlight) shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show(settings: settings, calendar: calendar)
        return false
    }
}
