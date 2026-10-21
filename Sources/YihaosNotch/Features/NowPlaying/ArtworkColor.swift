import AppKit
import SwiftUI

enum ArtworkColor {
    /// Picks the most vivid colour in the artwork and lifts it so it reads on black.
    /// Greyscale artwork falls back to white rather than a muddy grey.
    static func accent(from image: NSImage) -> Color? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
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
        return Color(hue: best.hue, saturation: min(best.saturation, 0.7), brightness: max(best.brightness, 0.88))
    }
}
