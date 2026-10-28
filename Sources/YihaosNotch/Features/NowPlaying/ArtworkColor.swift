import AppKit
import SwiftUI

enum ArtworkColor {
    /// Picks the most vivid colour in the artwork and lifts it so it reads on black.
    /// Greyscale artwork falls back to white rather than a muddy grey.
    static func accent(from cgImage: CGImage) -> Color? {
        let side = 12
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side,
                                          bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }

        var best: (score: CGFloat, hue: CGFloat, saturation: CGFloat, brightness: CGFloat)?
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let color = NSColor(srgbRed: CGFloat(pixels[i]) / 255, green: CGFloat(pixels[i + 1]) / 255,
                                blue: CGFloat(pixels[i + 2]) / 255, alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
            color.getHue(&h, saturation: &s, brightness: &b, alpha: nil)
            let score = s * (0.3 + b)
            if score > (best?.score ?? -1) { best = (score, h, s, b) }
        }
        guard let best, best.saturation > 0.2, best.brightness > 0.15 else { return Theme.primary }
        let brightness = max(best.brightness, 0.88)
        let saturation = readableSaturation(hue: best.hue, saturation: min(best.saturation, 0.7), brightness: brightness)
        return Color(hue: best.hue, saturation: saturation, brightness: brightness)
    }

    /// The accent colours lyrics, which are small text, so it needs 4.5:1 on black.
    /// Deep blues and purples fall short even at full brightness; washing them out a
    /// little keeps the hue.
    static func readableSaturation(hue: CGFloat, saturation: CGFloat, brightness: CGFloat) -> CGFloat {
        var saturation = saturation
        while saturation > 0, contrastOnBlack(hue: hue, saturation: saturation, brightness: brightness) < 4.5 {
            saturation -= 0.02
        }
        return max(saturation, 0)
    }

    /// WCAG contrast ratio against black.
    static func contrastOnBlack(hue: CGFloat, saturation: CGFloat, brightness: CGFloat) -> CGFloat {
        let color = NSColor(colorSpace: .sRGB, hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent)
            + 0.0722 * linear(color.blueComponent)
        return (luminance + 0.05) / 0.05
    }
}
