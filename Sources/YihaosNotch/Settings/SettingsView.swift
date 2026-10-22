import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let calendar: CalendarService
    let mediaKeys: MediaKeyController

    @State private var loginItemStatus = SMAppService.mainApp.status

    var body: some View {
        Form {
            Section("Opening") {
                Picker("Open the notch by", selection: $settings.openTrigger) {
                    Text("Hovering").tag(OpenTrigger.hover)
                    Text("Clicking").tag(OpenTrigger.click)
                }
                .pickerStyle(.segmented)

                if settings.openTrigger == .hover {
                    LabeledContent("Hover delay") {
                        HStack {
                            Slider(value: $settings.hoverDelay, in: 0.2...1.2, step: 0.1)
                                .frame(width: 160)
                            Text(String(format: "%.1f s", settings.hoverDelay))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                }
                Toggle("Haptic feedback when it opens", isOn: $settings.hapticsEnabled)
            }

            Section("Live activities") {
                Toggle("Show music while a player has a track", isOn: $settings.showMusicActivity)
                Toggle("Show charging and low battery", isOn: $settings.showBatteryActivity)
                Picker("Countdown before events", selection: $settings.eventReminderMinutes) {
                    Text("Off").tag(0)
                    Text("2 minutes").tag(2)
                    Text("5 minutes").tag(5)
                    Text("10 minutes").tag(10)
                }
            }

            Section("Calendar") {
                Toggle("Show calendar in the notch", isOn: $settings.calendarEnabled)
                    .onChange(of: settings.calendarEnabled) { _, enabled in
                        if enabled { calendar.start() } else { calendar.stop() }
                    }
                LabeledContent("Access") {
                    switch calendar.access {
                    case .granted:
                        Text("Allowed").foregroundStyle(.secondary)
                    case .notDetermined:
                        Button("Allow…") { calendar.requestAccess() }
                    case .denied:
                        Button("Open Privacy Settings…") { calendar.openPrivacySettings() }
                    }
                }
            }

            Section {
                Toggle("Show volume and brightness in the notch", isOn: $settings.replaceSystemHUD)
                    .onChange(of: settings.replaceSystemHUD) { _, enabled in
                        if enabled { mediaKeys.enable(prompt: true) } else { mediaKeys.disable() }
                    }
                if settings.replaceSystemHUD && !mediaKeys.isRunning {
                    LabeledContent("Needs Accessibility permission to catch the keys") {
                        Button("Open Settings…") {
                            mediaKeys.refreshPermission()
                            mediaKeys.openAccessibilitySettings()
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                Toggle("Show when headphones connect", isOn: $settings.showHeadphonesActivity)
            } header: {
                Text("Volume and devices")
            } footer: {
                Text("Replaces the system's volume and brightness pop-up with a small indicator in the notch. While the panel is open, macOS shows its own. The volume-change sound isn't played.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Launch at login", isOn: launchAtLogin)
                // macOS can accept the registration but hold it until the user approves
                // it in Login Items, so the toggle alone would claim it's on.
                if loginItemStatus == .requiresApproval {
                    LabeledContent("Needs your approval in System Settings") {
                        Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    }
                    .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Yihao's Notch \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Quit") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 600)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Picks up an approval made in System Settings while this window was open.
            loginItemStatus = SMAppService.mainApp.status
        }
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
