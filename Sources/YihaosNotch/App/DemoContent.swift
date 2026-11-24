import AppKit
import SwiftUI

/// Development aid for the README's screenshots: `--demo` fills the notch with a made-up
/// track, lyrics and calendar instead of the real ones, so no personal data is ever on
/// screen. Music, Calendar, headphones, the media keys and update checks aren't started
/// at all. `--demo-meeting` pauses the track and puts a meeting on the next quarter hour, for
/// the closed notch's countdown.
@MainActor
enum DemoContent {
    static let meeting = CommandLine.arguments.contains("--demo-meeting")
    static let isOn = meeting || CommandLine.arguments.contains("--demo")

    static func fill(nowPlaying: NowPlayingService, calendar: CalendarService) {
        nowPlaying.showDemo(track, artwork: artwork, lyrics: Lyrics(lrc: lyrics), position: 64, playing: !meeting)
        calendar.showDemo(events(now: .now))
    }

    static let track = Track(id: "demo", title: "Slow Tides", artist: "Harbour Lights", album: "Afterglow",
                             duration: 214)

    /// Written for the demo.
    private static let lyrics = """
        [00:40.00] The streetlights hum a song we used to know
        [00:47.50] We drive until the city falls asleep
        [00:55.00] And every light along the shore is low
        [01:02.00] Slow tides carry everything we keep
        [01:10.00] Hold on, the morning's almost here
        [01:17.50] Hold on, the water's turning clear
        """

    /// The sky turning from night to dusk over a dark sea, drawn here rather than
    /// shipped as a picture.
    static let artwork: NSImage = {
        let side = 512
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return NSImage() }
        func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
            CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        }
        let size = CGFloat(side)
        let horizon = size * 0.38
        // Core Graphics counts y from the bottom.
        let sky = CGGradient(colorsSpace: space, colors: [color(0xF4A261), color(0xD1495B), color(0x3D2C6B),
                                                          color(0x14112B)] as CFArray,
                             locations: [0, 0.22, 0.65, 1])!
        context.drawLinearGradient(sky, start: CGPoint(x: 0, y: horizon), end: CGPoint(x: 0, y: size), options: [])
        // The sun, half under the horizon.
        context.saveGState()
        context.clip(to: CGRect(x: 0, y: horizon, width: size, height: size - horizon))
        let sun = CGGradient(colorsSpace: space, colors: [color(0xFFE1A8), color(0xF7B267)] as CFArray,
                             locations: [0, 1])!
        context.addEllipse(in: CGRect(x: size / 2 - 92, y: horizon - 92, width: 184, height: 184))
        context.clip()
        context.drawLinearGradient(sun, start: CGPoint(x: 0, y: horizon + 92), end: CGPoint(x: 0, y: horizon),
                                   options: [])
        context.restoreGState()
        // The sea, with the sun's reflection broken into lines.
        let sea = CGGradient(colorsSpace: space, colors: [color(0x231A45), color(0x0D0B1E)] as CFArray,
                             locations: [0, 1])!
        context.saveGState()
        context.clip(to: CGRect(x: 0, y: 0, width: size, height: horizon))
        context.drawLinearGradient(sea, start: CGPoint(x: 0, y: horizon), end: .zero, options: [])
        context.restoreGState()
        for row in 0..<9 {
            let y = horizon - 10 - CGFloat(row) * 17
            let width = 150 - CGFloat(row) * 13
            context.setFillColor(color(0xF7B267, 0.75 - CGFloat(row) * 0.07))
            context.fill(CGRect(x: size / 2 - width / 2, y: y, width: width, height: 4))
        }
        guard let image = context.makeImage() else { return NSImage() }
        return NSImage(cgImage: image, size: NSSize(width: side, height: side))
    }()

    /// A plausible week, placed around the current time so there's always one meeting
    /// with a Join button coming up.
    static func events(now: Date) -> [CalendarItem] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let blue = Color(red: 0.20, green: 0.55, blue: 1.0)
        let purple = Color(red: 0.69, green: 0.42, blue: 0.95)
        let orange = Color(red: 1.0, green: 0.62, blue: 0.20)
        let green = Color(red: 0.30, green: 0.80, blue: 0.45)
        let zoom = MeetingLink(provider: .zoom, url: URL(string: "https://zoom.us/j/0000000000")!)
        let meet = MeetingLink(provider: .meet, url: URL(string: "https://meet.google.com/aaa-bbbb-ccc")!)

        func item(_ title: String, from start: Date, minutes: Int, _ color: Color, location: String? = nil,
                  meeting: MeetingLink? = nil) -> CalendarItem {
            CalendarItem(id: "demo-\(title)-\(start.timeIntervalSince1970)", eventIdentifier: nil, title: title,
                         start: start, end: start.addingTimeInterval(Double(minutes) * 60), isAllDay: false,
                         location: location, color: color, meeting: meeting)
        }
        func allDay(_ title: String, day: Int, _ color: Color) -> CalendarItem {
            let start = calendar.date(byAdding: .day, value: day, to: today)!
            return CalendarItem(id: "demo-\(title)", eventIdentifier: nil, title: title, start: start,
                                end: calendar.date(byAdding: .day, value: 1, to: start)!, isAllDay: true,
                                location: nil, color: color, meeting: nil)
        }
        func at(day: Int, hour: Int, minute: Int = 0) -> Date {
            calendar.date(byAdding: DateComponents(day: day, hour: hour, minute: minute), to: today)!
        }
        // The next quarter hour at least three minutes away, so times look like a real
        // diary's and the closed notch has a countdown to show.
        let quarter = 15 * 60.0
        let soon = Date(timeIntervalSinceReferenceDate:
            ((now.timeIntervalSinceReferenceDate + 3 * 60) / quarter).rounded(.up) * quarter)

        // Nothing earlier today, so the agenda opens at the top with the all-day line.
        return [
            allDay("Release day", day: 0, green),
            item("Design review", from: soon, minutes: 45, purple, meeting: zoom),
            item("Focus time", from: soon.addingTimeInterval(75 * 60), minutes: 90, orange),
            item("Climbing", from: soon.addingTimeInterval(240 * 60), minutes: 90, green, location: "Boulder Hall"),
            item("Team standup", from: at(day: 1, hour: 9, minute: 30), minutes: 15, blue, meeting: zoom),
            item("Product sync", from: at(day: 1, hour: 14), minutes: 30, purple, meeting: meet),
            allDay("Long weekend", day: 3, green),
            item("Book club", from: at(day: 2, hour: 19), minutes: 90, orange, location: "Corner Café"),
            item("Team standup", from: at(day: -1, hour: 9, minute: 30), minutes: 15, blue, meeting: zoom),
            item("Dentist", from: at(day: 4, hour: 11), minutes: 45, orange),
        ]
    }
}
