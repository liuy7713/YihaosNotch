import AVFoundation
import SwiftUI

struct CameraMirrorView: View {
    @Environment(CameraController.self) private var camera

    private let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    var body: some View {
        ZStack {
            shape.fill(Theme.fill)
            switch camera.access {
            case .granted:
                CameraPreview(session: camera.capture.session)
                    .scaleEffect(x: -1, y: 1)
                    .clipShape(shape)
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
        .onAppear { camera.activate() }
        .onDisappear { camera.deactivate() }
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
