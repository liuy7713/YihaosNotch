import ServiceManagement
import SwiftUI

/// The app's native controls, painted black to match the notch and the welcome
/// screen. Words follow the README: "the notch" is the closed state, "the panel" the
/// open one. Permission rows only appear when something is blocking a feature.
struct SettingsView: View {
    @Bindable var settings: AppSettings
    let calendar: CalendarService
    let mediaKeys: MediaKeyController

    @State private var loginItemStatus = SMAppService.mainApp.status
    @State private var choosingCalendars = false

    var body: some View {
        VStack(spacing: 0) {
            form
            footer
        }
        .frame(width: Self.width, height: Self.height)
        .background(Color.black)
        .preferredColorScheme(.dark)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Picks up an approval made in System Settings while this window was open.
            loginItemStatus = SMAppService.mainApp.status
        }
    }

    private var form: some View {
        Form {
            Section("General") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Open the panel by", selection: $settings.openTrigger) {
                        Text("Hovering").tag(OpenTrigger.hover)
                        Text("Clicking").tag(OpenTrigger.click)
                    }
                    .pickerStyle(.segmented)
                    Caption("Or swipe down on the notch with two fingers.")
                }
                if settings.openTrigger == .hover {
                    LabeledContent("Hover delay") {
                        HStack(spacing: 10) {
                            // No step, so no tick marks; the value snaps to tenths instead.
                            Slider(value: Binding(get: { settings.hoverDelay },
                                                  set: { settings.hoverDelay = ($0 * 10).rounded() / 10 }),
                                   in: 0.2...1.2)
                                .frame(width: 160)
                            Text(String(format: "%.1f s", settings.hoverDelay))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 36, alignment: .trailing)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Haptic feedback", isOn: $settings.hapticsEnabled)
                    Caption("When the panel opens and as you scroll through days.")
                }
                Toggle("Open at login", isOn: launchAtLogin)
                // macOS can accept the registration but hold it until the user approves
                // it in Login Items, so the switch alone would claim it's on.
                if loginItemStatus == .requiresApproval {
                    LabeledContent("Needs your approval in System Settings") {
                        Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
            }

            Section("Calendar") {
                Toggle("Show calendar in the panel", isOn: $settings.calendarEnabled)
                    .onChange(of: settings.calendarEnabled) { _, enabled in
                        // The user just switched it on, so asking now is in context.
                        if enabled { calendar.start(requestingAccess: true) } else { calendar.stop() }
                    }
                Picker("Countdown in the notch", selection: $settings.eventReminderMinutes) {
                    Text("Off").tag(0)
                    Text("2 min before").tag(2)
                    Text("5 min before").tag(5)
                    Text("10 min before").tag(10)
                }
                // The countdown comes from the calendar.
                .disabled(!settings.calendarEnabled)
                if settings.calendarEnabled, calendar.access == .granted, !calendar.calendars.isEmpty {
                    LabeledContent("Calendars") {
                        Button(calendarsSummary) { choosingCalendars = true }
                            .popover(isPresented: $choosingCalendars, arrowEdge: .trailing) {
                                CalendarPicker(calendars: calendar.calendars, hidden: $settings.hiddenCalendars)
                            }
                    }
                }
                if settings.calendarEnabled, calendar.access != .granted {
                    LabeledContent("Calendar access is off") {
                        if calendar.access == .notDetermined {
                            Button("Allow…") { calendar.requestAccess() }
                        } else {
                            Button("Open Privacy Settings…") { calendar.openPrivacySettings() }
                        }
                    }
                }
            }

            Section("Music") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Synced lyrics", isOn: $settings.showLyrics)
                    Caption("Looked up on LRCLIB using the track's title, artist, album and length.")
                }
            }

            Section("In the notch") {
                Toggle("Music while it's playing", isOn: $settings.showMusicActivity)
                Toggle("Charging and low battery", isOn: $settings.showBatteryActivity)
                Toggle("Headphones connecting", isOn: $settings.showHeadphonesActivity)
            }

            Section {
                Toggle("Show in the notch", isOn: $settings.replaceSystemHUD)
                    .onChange(of: settings.replaceSystemHUD) { _, enabled in
                        if enabled { mediaKeys.enable(prompt: true) } else { mediaKeys.disable() }
                    }
                if settings.replaceSystemHUD && !mediaKeys.isRunning {
                    LabeledContent("Needs Accessibility access") {
                        Button("Open Privacy Settings…") {
                            mediaKeys.refreshPermission()
                            mediaKeys.openAccessibilitySettings()
                        }
                    }
                }
            } header: {
                Text("Volume and brightness")
            } footer: {
                Caption("Replaces the macOS pop-up, without its sound. With an external keyboard, key presses are checked only for its brightness keys.")
                    .padding(.leading, 10)
            }

        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    /// Outside the scrolling form, so Quit is always in view (the tour promises the
    /// gear leads to it).
    private var footer: some View {
        HStack(spacing: 12) {
            Text("Yihao's Notch \(Self.version)")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
                .textSelection(.enabled)
            Spacer()
            Button("Show Tour…") { WelcomeWindowController.shared.show(page: 1) }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondary)
            Button("Quit") { NSApp.terminate(nil) }
                .controlSize(.small)
                .help("Stops the notch until Yihao's Notch is opened again")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    static let width: CGFloat = 480

    private var calendarsSummary: String {
        let shown = calendar.calendars.filter { !settings.hiddenCalendars.contains($0.id) }.count
        return shown == calendar.calendars.count ? "All" : "\(shown) of \(calendar.calendars.count)"
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    /// Tall enough for every section at the default text size, including a permission
    /// row that's showing, but never taller than
    /// the screen: at the largest text sizes a 13" MacBook Air has only about 640
    /// points to spare, and the form scrolls there (Quit stays in the footer).
    static var height: CGFloat {
        let available = (ScreenLocator.builtInScreen ?? NSScreen.main)?.visibleFrame.height ?? 900
        return max(360, min(900, available - 60))
    }

    private var launchAtLogin: Binding<Bool> {
        Binding {
            loginItemStatus == .enabled || loginItemStatus == .requiresApproval
        } set: { enabled in
            if enabled {
                try? SMAppService.mainApp.register()
            } else {
                try? SMAppService.mainApp.unregister()
            }
            loginItemStatus = SMAppService.mainApp.status
        }
    }
}

/// Which calendars the panel and the countdown use, grouped by account.
private struct CalendarPicker: View {
    let calendars: [CalendarSource]
    @Binding var hidden: Set<String>

    private var accounts: [String] {
        calendars.map(\.account).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(accounts, id: \.self) { account in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(account)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.tertiary)
                        ForEach(calendars.filter { $0.account == account }) { source in
                            Toggle(isOn: shown(source.id)) {
                                HStack(spacing: 6) {
                                    Circle().fill(source.color).frame(width: 8, height: 8)
                                    Text(source.title).lineLimit(1)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
            }
            .padding(16)
            .frame(width: 260, alignment: .leading)
        }
        .frame(maxHeight: 380)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func shown(_ id: String) -> Binding<Bool> {
        Binding {
            !hidden.contains(id)
        } set: { show in
            if show { hidden.remove(id) } else { hidden.insert(id) }
        }
    }
}

/// A short explanatory line under a control or section.
private struct Caption: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.tertiary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            // Section footers would otherwise sit at the trailing edge.
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
