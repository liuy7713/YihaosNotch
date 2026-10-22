// Renders the app icon to a 1024×1024 PNG.
//   swift scripts/icon/render-icon.swift <output.png>
// scripts/make-icon.sh turns it into Resources/AppIcon.icns.
import AppKit
import SwiftUI

/// Same silhouette as the app's NotchShape: concave flares at the top edge,
/// rounded corners at the bottom.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let t = topRadius, b = bottomRadius
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t), control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addArc(tangent1End: CGPoint(x: rect.minX + t, y: rect.maxY),
                 tangent2End: CGPoint(x: rect.minX + t + b, y: rect.maxY), radius: b)
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addArc(tangent1End: CGPoint(x: rect.maxX - t, y: rect.maxY),
                 tangent2End: CGPoint(x: rect.maxX - t, y: rect.maxY - b), radius: b)
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// macOS icon grid: 1024 canvas, 824 body, continuous corners, soft drop shadow.
struct Icon: View {
    /// Tile colours (top, bottom) and the colour of the notch's contents.
    var base: (Color, Color)
    var accent: Color

    var body: some View {
        let body = RoundedRectangle(cornerRadius: 185, style: .continuous)
        ZStack(alignment: .top) {
            // Warm paper base: a barely-there top-to-bottom shift, no glossy sheen.
            LinearGradient(colors: [base.0, base.1], startPoint: .top, endPoint: .bottom)

            notch
        }
        .frame(width: 824, height: 824)
        .clipShape(body)
        .overlay(body.strokeBorder(Color.black.opacity(0.06), lineWidth: 2))
        .shadow(color: .black.opacity(0.22), radius: 14, y: 8)
        .frame(width: 1024, height: 1024)
    }

    /// The notch hanging from the top edge, showing a live activity: album art on
    /// the left wing, music bars on the right.
    private var notch: some View {
        // The notch must sit on the flat part of the top edge (824 − 2 × 185 = 454 pt),
        // or its flares run into the rounded corners.
        let flare: CGFloat = 26
        return ZStack {
            NotchShape(topRadius: flare, bottomRadius: 66)
                .fill(Color.black)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 6)
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 19, style: .continuous)
                    .fill(accent)
                    .frame(width: 80, height: 80)
                Spacer()
                HStack(alignment: .center, spacing: 12) {
                    ForEach([42, 74, 56, 30] as [CGFloat], id: \.self) { h in
                        Capsule().fill(accent).frame(width: 16, height: h)
                    }
                }
                .frame(width: 80)
            }
            .padding(.horizontal, flare + 40)
            .padding(.top, 6)
        }
        .frame(width: 400 + flare * 2, height: 172)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
let output = arguments.first ?? "icon.png"
let variant = arguments.dropFirst().first ?? "coral"
let icon = variant == "paper"
    ? Icon(base: (Color(hex: 0xF7F4EF), Color(hex: 0xE7E2DA)), accent: Color(hex: 0xFF5A4E))
    : Icon(base: (Color(hex: 0xFF6450), Color(hex: 0xEE4A3C)), accent: Color(hex: 0xF7F4EF))
MainActor.assumeIsolated {
    let renderer = ImageRenderer(content: icon)
    renderer.scale = 1
    guard let image = renderer.nsImage,
          let tiff = image.tiffRepresentation,
          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    else { fatalError("render failed") }
    try! png.write(to: URL(fileURLWithPath: output))
    print("wrote \(output)")
}
