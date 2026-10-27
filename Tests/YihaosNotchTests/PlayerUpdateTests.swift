import Foundation
import Testing
@testable import YihaosNotch

/// Any process can post the players' notifications, so every field is untrusted.
struct PlayerUpdateTests {
    @Test func secondsMustBeFiniteAndWithinADay() {
        #expect(PlayerUpdate.seconds(NSNumber(value: 1500), scale: 1000) == 1.5)
        #expect(PlayerUpdate.seconds("12,5", scale: 1) == 12.5)
        #expect(PlayerUpdate.seconds(NSNumber(value: Double.nan), scale: 1) == nil)
        #expect(PlayerUpdate.seconds(NSNumber(value: Double.infinity), scale: 1) == nil)
        #expect(PlayerUpdate.seconds(NSNumber(value: -1), scale: 1) == nil)
        #expect(PlayerUpdate.seconds(NSNumber(value: 86_401), scale: 1) == nil)
        #expect(PlayerUpdate.seconds([1, 2], scale: 1) == nil)
    }

    @Test func musicTrackIDsConvergeFromEitherSource() {
        // The notification's signed 64-bit number and AppleScript's hex name the same track.
        #expect(PlayerUpdate.musicTrackID(NSNumber(value: Int64(-2))) == "FFFFFFFFFFFFFFFE")
        #expect(PlayerUpdate.musicTrackID("fffffffffffffffe") == "FFFFFFFFFFFFFFFE")
        #expect(PlayerUpdate.musicTrackID(["not", "an", "id"]) == nil)
    }

    @Test func spotifyNotification() throws {
        let update = PlayerUpdate.fromNotification([
            "Player State": "Playing", "Name": "Song", "Artist": "Artist", "Album": "Album",
            "Duration": NSNumber(value: 200_000), "Track ID": "spotify:track:1",
            "Playback Position": NSNumber(value: 12.5),
        ], source: .spotify)
        let track = try #require(update.track)
        #expect(update.isPlaying)
        #expect(track == Track(id: "spotify:track:1", title: "Song", artist: "Artist", album: "Album", duration: 200))
        #expect(update.position == 12.5)
    }

    @Test func musicNotification() throws {
        let update = PlayerUpdate.fromNotification([
            "Player State": "Paused", "Name": "Song", "Total Time": NSNumber(value: 180_000),
            "PersistentID": NSNumber(value: Int64(-2)),
        ], source: .music)
        let track = try #require(update.track)
        #expect(!update.isPlaying)
        #expect(track.id == "FFFFFFFFFFFFFFFE")
        #expect(track.duration == 180)
        #expect(track.artist == "")
    }

    @Test func hostileValuesAreCappedOrDropped() {
        let update = PlayerUpdate.fromNotification([
            "Player State": "Playing", "Name": String(repeating: "x", count: 10_000),
            "Artist": 42, "Duration": "inf",
        ], source: .spotify)
        #expect(update.track?.title.count == 500)
        #expect(update.track?.artist == "")
        #expect(update.track?.duration == 0)
    }

    @Test func noNameMeansNoTrack() {
        #expect(PlayerUpdate.fromNotification(["Player State": "Stopped"], source: .music).track == nil)
    }

    @Test(arguments: [("Playing", true), ("Fast Forwarding", true), ("rewinding", true),
                      ("Paused", false), ("Stopped", false)])
    func playingStates(_ state: String, _ playing: Bool) {
        #expect(PlayerUpdate(state: state).isPlaying == playing)
    }

    // MARK: Script output

    func output(_ fields: String...) -> String {
        fields.joined(separator: PlayerUpdate.fieldSeparator)
    }

    @Test func spotifyStatus() throws {
        let update = try #require(PlayerUpdate.fromScriptOutput(
            output("playing", "Song", "Artist", "Album", "200000", "12,5", "spotify:track:1", "https://i.scdn.co/image/x"),
            source: .spotify))
        #expect(update.track?.duration == 200)
        #expect(update.position == 12.5)
        #expect(update.artworkURL == "https://i.scdn.co/image/x")
    }

    @Test func musicStatus() throws {
        let update = try #require(PlayerUpdate.fromScriptOutput(
            output("paused", "Song", "Artist", "Album", "180.5", "3", "abcdef0123456789"), source: .music))
        #expect(update.track?.duration == 180.5)
        #expect(update.track?.id == "ABCDEF0123456789")
        #expect(update.artworkURL == nil)
    }

    @Test func stoppedOrEmptyStatus() {
        #expect(PlayerUpdate.fromScriptOutput("stopped", source: .music)?.isStopped == true)
        #expect(PlayerUpdate.fromScriptOutput("stopped", source: .music)?.track == nil)
        #expect(PlayerUpdate.fromScriptOutput("", source: .spotify) == nil)
    }
}
