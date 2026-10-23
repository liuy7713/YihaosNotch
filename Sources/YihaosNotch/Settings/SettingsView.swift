import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let calendar: CalendarService
    let mediaKeys: MediaKeyController

    @State private var loginItemStatus = SMAppService.mainApp.status

    var body: some View {
        Form {
            // First, so it's found without scrolling.
            Section("Help") {
                LabeledContent {
                    Button("Show Tour…") { WelcomeWindowController.shared.show(page: 1) }
                } label: {
                    Text("How to use Yihao's Notch")
                    Text("What it shows by itself, how to open it, and what's in the panel.")
                }
                LabeledContent {
                    Button("Review…") { WelcomeWindowController.shared.show(page: 2) }
                } label: {
                    Text("Permissions")
                    Text("Calendar, Music and Spotify, Camera, and the volume keys.")
                }
            }

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
        .frame(width: 460, height: Self.height)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Picks up an approval made in System Settings while this window was open.
            loginItemStatus = SMAppService.mainApp.status
        }
    }

    /// Tall enough to show most sections, but never taller than the screen: at the
    /// largest text sizes a 13" MacBook Air has only about 640 points to spare. The
    /// form scrolls for the rest.
    private static var height: CGFloat {
        let available = NSScreen.main?.visibleFrame.height ?? 800
        return max(360, min(680, available - 60))
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
