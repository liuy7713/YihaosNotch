import AVFoundation
import SwiftUI

struct CameraMirrorView: View {
    @Environment(CameraController.self) private var camera

    private let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    var body: some View {
        ZStack {
            shape.fill(Theme.fill)
            switch camera.access {
            case .granted where camera.isUnavailable:
                Text("Camera unavailable")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiary)
            case .granted:
                Image(systemName: "video.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
                    .opacity(camera.isLive ? 0 : 1)
                CameraPreview(session: camera.capture.session)
                    .scaleEffect(x: -1, y: 1)
                    .clipShape(shape)
                    .opacity(camera.isLive ? 1 : 0)
                if camera.isLive, camera.supportsCenterStage {
                    CenterStageButton()
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .transition(.opacity)
                }
            case .notDetermined:
                ProgressView()
                    .controlSize(.small)
            case .denied:
                VStack(spacing: 8) {
                    Text("Camera access is off")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.tertiary)
                    Button("Open Privacy Settings") { camera.openPrivacySettings() }
                        .buttonStyle(PressableStyle())
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                }
            }
        }
        .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 0.5))
        .animation(.easeOut(duration: 0.35), value: camera.isLive)
        .onAppear { camera.activate() }
        .onDisappear { camera.deactivate() }
    }
}

/// Turns Center Stage on and off, like FaceTime's button. Lit while it's framing you.
private struct CenterStageButton: View {
    @Environment(CameraController.self) private var camera

    var body: some View {
        let on = camera.isCenterStageEnabled
        Button {
            camera.setCenterStage(!on)
        } label: {
            Image(systemName: "person.fill.viewfinder")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? Color.black : Theme.primary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(on ? Theme.primary : Color.black.opacity(0.55)))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .hoverHighlight(cornerRadius: 13)
        .animation(.easeOut(duration: 0.2), value: on)
        .help(on ? "Center Stage: On (keeps you in frame)" : "Center Stage: Off")
        .accessibilityLabel("Center Stage")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
