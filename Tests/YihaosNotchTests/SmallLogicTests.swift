import Foundation
import Testing
@testable import YihaosNotch

struct CountdownTests {
    @Test(arguments: [(754.0, "12:34"), (0.2, "0:01"), (0, "0:00"), (3600, "60:00")])
    func text(_ seconds: TimeInterval, _ expected: String) {
        #expect(seconds.countdownText == expected)
    }
}

@MainActor
struct HeadphoneNameTests {
    @Test(arguments: [("Yihao's AirPods Pro", "AirPods Pro"), ("Yihao’s AirPods", "AirPods"),
                      ("AirPods Max", "AirPods Max"), ("Sam's Beats Studio", "Beats Studio")])
    func ownerIsDropped(_ name: String, _ expected: String) {
        #expect(HeadphoneMonitor.displayName(for: name) == expected)
    }

    @Test(arguments: [("AirPods Pro", "airpods.pro"), ("AirPods Max", "airpods.max"),
                      ("AirPods", "airpods"), ("Beats Solo", "beats.headphones"), ("WH-1000XM5", "headphones")])
    func symbol(_ name: String, _ expected: String) {
        #expect(HeadphoneMonitor.symbol(for: name) == expected)
    }
}

/// Which copy carries on when two are running.
@MainActor
struct SingleInstanceTests {
    typealias Rank = SingleInstance.Rank

    @Test func anInstalledCopyBeatsADiskImageWhateverTheBuild() {
        #expect(Rank(installed: false, build: 99) < Rank(installed: true, build: 1))
    }

    @Test func thenTheHigherBuildWins() {
        #expect(Rank(installed: true, build: 15) < Rank(installed: true, build: 16))
        #expect(Rank(installed: true, build: 16) == Rank(installed: true, build: 16))
    }

    @Test(arguments: [("/Volumes/Yihao's Notch/Yihao's Notch.app", true),
                      ("/private/var/folders/ab/T/AppTranslocation/1234/d/Yihao's Notch.app", true),
                      ("/Applications/Yihao's Notch.app", false),
                      ("/Users/x/Applications/Yihao's Notch.app", false)])
    func diskImagePaths(_ path: String, _ onDiskImage: Bool) {
        #expect(WelcomePermissions.isDiskImagePath(path) == onDiskImage)
    }
}
