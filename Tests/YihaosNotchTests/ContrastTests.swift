import AppKit
import Testing
@testable import YihaosNotch

/// Colours taken from album art stay readable as small text on black.
struct ContrastTests {
    @Test(arguments: Array(stride(from: 0.0, to: 1.0, by: 0.05)))
    func artworkAccentReadsOnBlack(hue: Double) {
        let saturation = ArtworkColor.readableSaturation(hue: hue, saturation: 0.7, brightness: 0.88)
        #expect(ArtworkColor.contrastOnBlack(hue: hue, saturation: saturation, brightness: 0.88) >= 4.5)
    }

    @Test func brightAccentsKeepTheirSaturation() {
        // Yellow is already light, so it shouldn't be washed out.
        #expect(ArtworkColor.readableSaturation(hue: 1.0 / 6, saturation: 0.7, brightness: 0.88) == 0.7)
    }
}
