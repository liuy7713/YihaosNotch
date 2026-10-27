import Testing
@testable import YihaosNotch

struct LyricsTests {
    @Test func linesFollowThePosition() throws {
        let lyrics = try #require(Lyrics(lrc: "[00:01.00]first\n[00:03.50]second"))
        #expect(lyrics.line(at: 0.5) == nil)
        #expect(lyrics.line(at: 1.0) == "first")
        #expect(lyrics.line(at: 3.49) == "first")
        #expect(lyrics.line(at: 3.5) == "second")
        #expect(lyrics.line(at: 999) == "second")
    }

    @Test func severalStampsRepeatALine() throws {
        let lyrics = try #require(Lyrics(lrc: "[00:01.00][00:05.00]chorus\n[00:03.00]verse"))
        #expect(lyrics.lines.map(\.time) == [1, 3, 5])
        #expect(lyrics.line(at: 4) == "verse")
        #expect(lyrics.line(at: 5) == "chorus")
    }

    @Test func aPositiveOffsetShowsLinesSooner() throws {
        let lyrics = try #require(Lyrics(lrc: "[offset:+500]\n[00:02.00]line"))
        #expect(lyrics.line(at: 1.4) == nil)
        #expect(lyrics.line(at: 1.5) == "line")
    }

    @Test func wordTimingIsDropped() throws {
        let lyrics = try #require(Lyrics(lrc: "[00:01.00]<00:01.10>hello <00:01.50>world"))
        #expect(lyrics.lines.first?.text == "hello world")
    }

    @Test func aByteOrderMarkDoesNotHideTheFirstLine() throws {
        let lyrics = try #require(Lyrics(lrc: "\u{FEFF}[00:01.00]first"))
        #expect(lyrics.line(at: 1) == "first")
    }

    @Test func colonSeparatedHundredths() throws {
        let lyrics = try #require(Lyrics(lrc: "[00:01:50]line"))
        #expect(lyrics.lines.first?.time == 1.5)
    }

    @Test func aTimeInTheLyricStaysInTheText() throws {
        let lyrics = try #require(Lyrics(lrc: "[00:01.00]meet at [10:30]"))
        #expect(lyrics.lines.count == 1)
        #expect(lyrics.lines.first?.text == "meet at [10:30]")
    }

    @Test(arguments: ["just text", "", "[０１:００]full-width digits", "[ar:Artist]\n[ti:Title]"])
    func nothingSyncedIsNil(_ text: String) {
        #expect(Lyrics(lrc: text) == nil)
    }
}
