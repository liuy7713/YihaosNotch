import AppKit
import AVFoundation
import EventKit
import IOKit.ps
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
    ///
    /// It names the event the app really sends (get data) rather than wildcards: with
    /// wildcards, macOS can report "would need consent" without ever showing the prompt.
    nonisolated static func state(of bundleID: String, ask: Bool) -> PermissionState {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        let status = AEDeterminePermissionToAutomateTarget(
            target.aeDesc, AEEventClass(kAECoreSuite), AEEventID(kAEGetData), ask)
        switch Int(status) {
        case Int(noErr): return .allowed
        case errAEEventNotPermitted: return .denied
        case errAEEventWouldRequireUserConsent: return .notAsked
        default: return .notRunning
        }
    }
}

/// What the welcome screen shows for each permission, re-read every second while its
/// permissions page is showing, so changes made in System Settings appear straight away.
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

    let installedPlayers = MusicSource.allCases.filter { $0.appURL != nil }

    func startWatching() {
        watcher?.cancel()
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stopWatching() {
        watcher?.cancel()
        watcher = nil
    }

    /// Assigns only what changed: every assignment re-renders the page, even of an equal value.
    func refresh() async {
        let calendar: PermissionState = switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .allowed
        case .notDetermined: .notAsked
        default: .denied
        }
        let camera: PermissionState = switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .allowed
        case .notDetermined: .notAsked
        default: .denied
        }
        let launchAtLogin = SMAppService.mainApp.status == .enabled
        if calendar != self.calendar { self.calendar = calendar }
        if camera != self.camera { self.camera = camera }
        if launchAtLogin != self.launchAtLogin { self.launchAtLogin = launchAtLogin }
        guard !askingMusic else { return }
        let music = await musicState(asking: false)
        if music != self.music, !askingMusic { self.music = music }
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
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        // Registered, but macOS wants it approved in Login Items first.
        if enabled, status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    /// One state for both players: a running player still to be asked comes first (so
    /// Allow asks it even if the other was denied), then denied, then allowed.
    private func musicState(asking: Bool) async -> PermissionState {
        var states: [PermissionState] = []
        for player in installedPlayers {
            let bundleID = player.bundleID
            let state = await Task.detached { Automation.state(of: bundleID, ask: asking) }.value
            if state == .allowed { allowedPlayers.insert(player) }
            states.append(state == .notRunning && allowedPlayers.contains(player) ? .allowed : state)
        }
        if states.contains(.notAsked) { return .notAsked }
        if states.contains(.denied) { return .denied }
        if states.contains(.allowed) { return .allowed }
        return .notRunning
    }

    /// Where the app is running from, if that's somewhere it shouldn't be: straight from
    /// the disk image, or a quarantined copy macOS has moved aside ("translocated").
    /// Either way it disappears later, along with "Open at login".
    static var isRunningFromDiskImage: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/")
    }

    /// Laptops have an internal battery; desktop Macs never have a notch.
    static var isLaptop: Bool {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        return sources.contains { source in
            let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            return description?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }

    static func openPrivacySettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
