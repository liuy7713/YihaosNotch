// Draws the disk image's window background: the top of a screen with its notch, the
// two icons' places and an arrow between them.
//
//   swift render-background.swift OUT.png SCALE
//
// Finder draws icon names in black in Light Mode and white in Dark Mode, over the
// picture, so the background is a mid grey that both stay readable on.
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3, let scale = Double(arguments[2]) else {
    print("usage: render-background.swift OUT.png SCALE")
    exit(2)
}

// Window content size in points; keep in step with release.sh.
let size = CGSize(width: 560, height: 360)
let appCenter = CGPoint(x: 150, y: 175)
let folderCenter = CGPoint(x: 410, y: 175)

let pixels = CGSize(width: size.width * scale, height: size.height * scale)
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: rep)
else { exit(1) }
rep.size = size
NSGraphicsContext.current = context
let cg = context.cgContext
cg.scaleBy(x: scale, y: scale)
// Flip so y grows downwards, like Finder's icon positions.
cg.translateBy(x: 0, y: size.height)
cg.scaleBy(x: 1, y: -1)

// Background: a quiet vertical grey gradient.
let colors = [NSColor(white: 0.60, alpha: 1).cgColor, NSColor(white: 0.52, alpha: 1).cgColor] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])

// The notch, hanging from the top edge (same silhouette as the app's NotchShape).
let notchWidth: CGFloat = 148, notchHeight: CGFloat = 30, t: CGFloat = 9, b: CGFloat = 11
let left = (size.width - notchWidth) / 2 - t
let notch = CGMutablePath()
notch.move(to: CGPoint(x: left, y: 0))
notch.addQuadCurve(to: CGPoint(x: left + t, y: t), control: CGPoint(x: left + t, y: 0))
notch.addLine(to: CGPoint(x: left + t, y: notchHeight - b))
notch.addArc(tangent1End: CGPoint(x: left + t, y: notchHeight),
             tangent2End: CGPoint(x: left + t + b, y: notchHeight), radius: b)
notch.addLine(to: CGPoint(x: left + t + notchWidth - b, y: notchHeight))
notch.addArc(tangent1End: CGPoint(x: left + t + notchWidth, y: notchHeight),
             tangent2End: CGPoint(x: left + t + notchWidth, y: notchHeight - b), radius: b)
notch.addLine(to: CGPoint(x: left + t + notchWidth, y: t))
notch.addQuadCurve(to: CGPoint(x: left + 2 * t + notchWidth, y: 0), control: CGPoint(x: left + t + notchWidth, y: 0))
notch.closeSubpath()
cg.addPath(notch)
cg.setFillColor(NSColor.black.cgColor)
cg.fillPath()

// Arrow from the app to Applications: a short line with an open head.
let arrowY = appCenter.y
let start = CGPoint(x: appCenter.x + 72, y: arrowY)
let end = CGPoint(x: folderCenter.x - 72, y: arrowY)
cg.setStrokeColor(NSColor(white: 1, alpha: 0.85).cgColor)
cg.setLineWidth(2.5)
cg.setLineCap(.round)
cg.setLineJoin(.round)
cg.move(to: start)
cg.addLine(to: end)
cg.move(to: CGPoint(x: end.x - 10, y: arrowY - 10))
cg.addLine(to: end)
cg.addLine(to: CGPoint(x: end.x - 10, y: arrowY + 10))
cg.strokePath()

// Caption, centred near the bottom. Drawn unflipped for AppKit text.
cg.saveGState()
cg.translateBy(x: 0, y: size.height)
cg.scaleBy(x: 1, y: -1)
let caption = "Drag Yihao's Notch into Applications to install it."
let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 13, weight: .medium),
    .foregroundColor: NSColor(white: 1, alpha: 0.92),
    .paragraphStyle: paragraph,
]
(caption as NSString).draw(in: CGRect(x: 0, y: 44, width: size.width, height: 20), withAttributes: attributes)
cg.restoreGState()

NSGraphicsContext.current = nil
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: arguments[1]))
