import SwiftUI

/// Three short pages shown on first launch: what the app is, how to open it, and the
/// permissions it can use, each asked for on its own with a reason.
struct WelcomeView: View {
    let settings: AppSettings
    let calendar: CalendarService
    let mediaKeys: MediaKeyController
    let onFinish: () -> Void

    @State private var page = WelcomeView.previewPage
    @State private var forward = true
    @State private var permissions = WelcomePermissions()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let pageCount = 3

    /// Development aid: `--preview-welcome N` opens the welcome screen at page N (0–2).
    static var previewPage: Int {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--preview-welcome"), index + 1 < arguments.count,
              let page = Int(arguments[index + 1]) else { return 0 }
        return min(max(page, 0), 2)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch page {
                case 0: HelloPage()
                case 1: HowToPage()
                default: PermissionsPage(settings: settings, calendar: calendar,
                                         mediaKeys: mediaKeys, permissions: permissions)
                }
            }
            .id(page)
            .transition(pageTransition)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            footer
        }
        .frame(width: 640, height: 470)
        .background(Color.black)
        .preferredColorScheme(.dark)
        .onAppear { permissions.startWatching() }
        .onDisappear { permissions.stopWatching() }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            ForEach(0..<pageCount, id: \.self) { index in
                Capsule()
                    .fill(index == page ? Theme.primary : Theme.fillStrong)
                    .frame(width: index == page ? 18 : 6, height: 6)
            }
            .animation(Theme.swap, value: page)
            .accessibilityHidden(true)

            Spacer()

            if page > 0 {
                Button("Back") { go(to: page - 1) }
                    .buttonStyle(WelcomeTextButtonStyle())
            }
            Button(page == pageCount - 1 ? "Start Using Yihao's Notch" : "Continue") {
                if page == pageCount - 1 { onFinish() } else { go(to: page + 1) }
            }
            .buttonStyle(WelcomePrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
        .padding(.top, 8)
    }

    private var pageTransition: AnyTransition {
        if reduceMotion { return .opacity }
        let shift: CGFloat = forward ? 28 : -28
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: shift)).animation(Theme.swap.delay(0.06)),
            removal: .opacity.combined(with: .offset(x: -shift)).animation(.easeOut(duration: 0.14))
        )
    }

    private func go(to newPage: Int) {
        forward = newPage > page
        withAnimation(Theme.swapAnimation(reduceMotion: reduceMotion)) { page = newPage }
    }
}

// MARK: Pages

private struct HelloPage: View {
    private var problem: (title: String, detail: String)? {
        guard let screen = ScreenLocator.builtInScreen else {
            return ("Open your MacBook's lid",
                    "Yihao's Notch lives in the notch of the built-in display, so it stays hidden while the lid is closed.")
        }
        guard ScreenLocator.notchSize(on: screen) == nil else { return nil }
        return ("This display has no notch",
                "Yihao's Notch is made for MacBooks with a notch in the screen. On this Mac there's nowhere for it to appear.")
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 104, height: 104)
                .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
                .accessibilityHidden(true)
            Text("Yihao's Notch")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Theme.primary)
                .padding(.top, 18)
            Text("Your music, your day and a few handy extras,\ntucked into the notch.")
                .font(.system(size: 15))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 8)

            if let problem {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.yellow.opacity(0.9))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(problem.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.primary)
                        Text(problem.detail)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
                .frame(width: 420, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.fill))
                .padding(.top, 26)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 20)
    }
}

private struct HowToPage: View {
    @State private var activeTip = 0

    var body: some View {
        VStack(spacing: 0) {
            PageTitle("Hiding in plain sight",
                      subtitle: "The notch looks the same until you need it.")
            HStack(alignment: .center, spacing: 30) {
                NotchDemo(activeTip: $activeTip)
                VStack(alignment: .leading, spacing: 18) {
                    Tip(symbol: "cursorarrow", title: "Rest the pointer on the notch",
                        detail: "It opens after a moment. Move away to close it.",
                        isActive: activeTip == 0)
                    Tip(symbol: "hand.draw", title: "Or swipe down with two fingers",
                        detail: "With the pointer on the notch, it opens at once.",
                        isActive: activeTip == 1)
                    Tip(symbol: "gearshape", title: "Settings live in the app",
                        detail: "There's no Dock or menu bar icon: open Yihao's Notch again from Spotlight.",
                        isActive: false)
                }
                .frame(width: 250, alignment: .leading)
            }
            .padding(.top, 30)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 36)
        .padding(.top, 44)
    }
}

private struct PermissionsPage: View {
    @Bindable var settings: AppSettings
    let calendar: CalendarService
    let mediaKeys: MediaKeyController
    let permissions: WelcomePermissions

    var body: some View {
        VStack(spacing: 0) {
            PageTitle("Choose what it can use",
                      subtitle: "Your calendar and camera never leave this Mac. You can change any of this later in Settings.")
            VStack(spacing: 0) {
                PermissionRow(symbol: "calendar", title: "Calendar",
                              detail: "Today's events, and one click to join a call.") {
                    PermissionControl(state: permissions.calendar,
                                      allow: { permissions.requestCalendar(using: calendar) },
                                      openSettings: { WelcomePermissions.openPrivacySettings("Privacy_Calendars") })
                }
                Divider().overlay(Theme.hairline)
                PermissionRow(symbol: "music.note", title: musicTitle,
                              detail: musicDetail) {
                    if permissions.askingMusic {
                        ProgressView().controlSize(.small)
                    } else {
                        PermissionControl(state: permissions.music,
                                          allow: { permissions.requestMusic() },
                                          openSettings: { WelcomePermissions.openPrivacySettings("Privacy_Automation") })
                    }
                }
                Divider().overlay(Theme.hairline)
                PermissionRow(symbol: "camera", title: "Camera mirror",
                              detail: "A quick look before a call. Only on while the mirror is open.") {
                    PermissionControl(state: permissions.camera,
                                      allow: { permissions.requestCamera() },
                                      openSettings: { WelcomePermissions.openPrivacySettings("Privacy_Camera") })
                }
                Divider().overlay(Theme.hairline)
                PermissionRow(symbol: "speaker.wave.2", title: "Volume and brightness",
                              detail: "In the notch, not the big pop-up. Needs Accessibility.") {
                    hudControl
                }
                Divider().overlay(Theme.hairline)
                PermissionRow(symbol: "power", title: "Open at login",
                              detail: "Start Yihao's Notch whenever you log in.") {
                    Toggle("", isOn: Binding(get: { permissions.launchAtLogin },
                                             set: { permissions.setLaunchAtLogin($0) }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
            }
            .padding(.horizontal, 16)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.fill))
            .padding(.top, 22)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 44)
        .padding(.top, 36)
    }

    private var musicTitle: String {
        let names = permissions.installedPlayers.map(\.appName)
        return names.isEmpty ? "Music" : names.joined(separator: " and ")
    }

    private var musicDetail: String {
        permissions.music == .notRunning
            ? "What's playing, with controls. macOS asks when the player is open."
            : "What's playing, with controls and lyrics."
    }

    @ViewBuilder private var hudControl: some View {
        if !settings.replaceSystemHUD {
            Button("Turn On") {
                settings.replaceSystemHUD = true
                mediaKeys.enable(prompt: true)
            }
            .buttonStyle(WelcomeSmallButtonStyle())
        } else if mediaKeys.isRunning {
            AllowedLabel()
        } else {
            Button("Open Settings…") {
                mediaKeys.refreshPermission()
                mediaKeys.openAccessibilitySettings()
            }
            .buttonStyle(WelcomeSmallButtonStyle())
        }
    }
}

// MARK: Pieces

private struct PageTitle: View {
    let title: String
    let subtitle: String

    init(_ title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Theme.primary)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
    }
}

private struct Tip: View {
    let symbol: String
    let title: String
    let detail: String
    let isActive: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isActive ? Theme.primary : Theme.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isActive ? Theme.primary : Theme.secondary)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(.easeOut(duration: 0.25), value: isActive)
    }
}

private struct PermissionRow<Control: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 12)
            control()
                .frame(minWidth: 70, alignment: .trailing)
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }
}

private struct PermissionControl: View {
    let state: PermissionState
    let allow: () -> Void
    let openSettings: () -> Void

    var body: some View {
        ZStack(alignment: .trailing) {
            switch state {
            case .allowed:
                AllowedLabel()
            case .denied:
                Button("Open Settings…", action: openSettings)
                    .buttonStyle(WelcomeSmallButtonStyle())
            case .notAsked:
                Button("Allow", action: allow)
                    .buttonStyle(WelcomeSmallButtonStyle())
            case .notRunning:
                Text("Later")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .animation(.easeOut(duration: 0.2), value: state)
    }
}

private struct AllowedLabel: View {
    var body: some View {
        Label("Allowed", systemImage: "checkmark")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.charge)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }
}

// MARK: Button styles

private struct WelcomePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 18)
            .frame(height: 32)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.75 : 0.94)))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

private struct WelcomeTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(configuration.isPressed ? Theme.primary : Theme.secondary)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .contentShape(Rectangle())
            .hoverHighlight(cornerRadius: 16)
    }
}

private struct WelcomeSmallButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.primary)
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background(Capsule().fill(configuration.isPressed ? Theme.fill : Theme.fillStrong))
    }
}
