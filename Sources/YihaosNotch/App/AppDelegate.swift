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
        viewModel = NotchViewModel(settings: settings, nowPlaying: nowPlaying, calendar: calendar, timer: timer)
        SettingsWindowController.shared.configure(settings: settings, calendar: calendar, mediaKeys: mediaKeys)

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
        controller.start()
        self.controller = controller
        mediaKeys.canShowHUD = { [weak controller] in controller?.canShowLiveActivity ?? false }

        nowPlaying.start()
        battery.start()
        if settings.calendarEnabled { calendar.start() }
        headphones.start()
        // Silent at launch: the permission prompt only ever comes from the Settings toggle.
        if settings.replaceSystemHUD { mediaKeys.enable(prompt: false) }
        runPreviewFlags()
    }

    /// Development aids for checking visuals without pressing keys or clicking:
    /// `--preview-timer` starts a 25-minute timer and shows the timer view when the panel
    /// opens; `--preview-swap` (below); `--preview-hud` cycles the volume, brightness and headphone indicators with
    /// sample values (the real volume and brightness are never touched).
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

    // Opening the app again (e.g. from Finder or Spotlight) shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return false
    }
}
