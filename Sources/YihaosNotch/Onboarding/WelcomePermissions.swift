import AppKit
import AVFoundation
import EventKit
import ServiceManagement

enum PermissionState: Equatable {
    case notAsked, allowed, denied
    /// Music and Spotify only: macOS can ask about controlling an app only while it's
    /// running, so with neither open there's nothing to ask yet.
    case notRunning
}

enum Automation {
    /// Whether this app may control the app with `bundleID` through Apple events. With
    /// `ask`, macOS shows its consent prompt if the user hasn't decided; that call waits
    /// for their answer, so this must run off the main thread.
    nonisolated static func state(of bundleID: String, ask: Bool) -> PermissionState {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask)
        switch Int(status) {
        case Int(noErr): return .allowed
        case errAEEventNotPermitted: return .denied
        case errAEEventWouldRequireUserConsent: return .notAsked
        default: return .notRunning
        }
    }
}

/// What the welcome screen shows for each permission, re-read every second while it's
/// open so changes made in System Settings appear straight away.
@MainActor
@Observable
final class WelcomePermissions {
    private(set) var calendar: PermissionState = .notAsked
    private(set) var camera: PermissionState = .notAsked
    private(set) var music: PermissionState = .notRunning
    private(set) var launchAtLogin = false
    private(set) var askingMusic = false

    /// Players last seen allowed, kept so quitting one doesn't hide that it's allowed.
    @ObservationIgnored private var allowedPlayers: Set<MusicSource> = []
    @ObservationIgnored private var watcher: Task<Void, Never>?

    var installedPlayers: [MusicSource] { MusicSource.allCases.filter { $0.appURL != nil } }

    func startWatching() {
        watcher?.cancel()
        watcher = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stopWatching() {
        watcher?.cancel()
        watcher = nil
    }

    func refresh() async {
        calendar = switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .allowed
        case .notDetermined: .notAsked
        default: .denied
        }
        camera = switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .allowed
        case .notDetermined: .notAsked
        default: .denied
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        guard !askingMusic else { return }
        music = await musicState(asking: false)
    }

    func requestCalendar(using service: CalendarService) {
        service.requestAccess()
    }

    func requestCamera() {
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .video)
            await refresh()
        }
    }

    /// Asks about each running player in turn (macOS shows one prompt per app).
    func requestMusic() {
        guard !askingMusic else { return }
        askingMusic = true
        Task {
            music = await musicState(asking: true)
            askingMusic = false
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        if enabled {
            try? SMAppService.mainApp.register()
        } else {
            try? SMAppService.mainApp.unregister()
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// One state for both players: denied if either is, allowed if one is and neither is
    /// denied, otherwise whether there's a running player to ask.
    private func musicState(asking: Bool) async -> PermissionState {
        var states: [PermissionState] = []
        for player in installedPlayers {
            let bundleID = player.bundleID
            let state = await Task.detached { Automation.state(of: bundleID, ask: asking) }.value
            if state == .allowed { allowedPlayers.insert(player) }
            states.append(state == .notRunning && allowedPlayers.contains(player) ? .allowed : state)
        }
        if states.contains(.denied) { return .denied }
        if states.contains(.notAsked) { return .notAsked }
        if states.contains(.allowed) { return .allowed }
        return .notRunning
    }

    static func openPrivacySettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
