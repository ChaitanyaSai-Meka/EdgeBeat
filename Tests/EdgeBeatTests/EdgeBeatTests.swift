import Foundation
import XCTest
@testable import EdgeBeat

final class EdgeBeatTests: XCTestCase {
    func testArtworkRevisionChangesWhenDataChanges() {
        XCTAssertNotEqual(
            ArtworkRevision.data(Data([1, 2, 3])),
            ArtworkRevision.data(Data([1, 2, 4]))
        )
        XCTAssertEqual(
            ArtworkRevision.data(Data([1, 2, 3])),
            ArtworkRevision.data(Data([1, 2, 3]))
        )
    }

    func testArtworkCacheKeyIncludesTrackMetadata() {
        XCTAssertNotEqual(
            makeTrack(title: "First").artworkCacheKey,
            makeTrack(title: "Second").artworkCacheKey
        )
    }

    func testTrackEqualityIncludesArtworkRevisionAndMetadata() {
        let base = makeTrack(title: "First", artworkRevision: "a")
        XCTAssertNotEqual(base, makeTrack(title: "Second", artworkRevision: "a"))
        XCTAssertNotEqual(base, makeTrack(title: "First", artworkRevision: "b"))
    }

    func testAnalyzerRejectsInvalidSampleRates() {
        XCTAssertFalse(BeatAnalyzer.isValidSampleRate(0))
        XCTAssertFalse(BeatAnalyzer.isValidSampleRate(-44_100))
        XCTAssertFalse(BeatAnalyzer.isValidSampleRate(.nan))
        XCTAssertFalse(BeatAnalyzer.isValidSampleRate(.infinity))
        XCTAssertTrue(BeatAnalyzer.isValidSampleRate(44_100))
    }

    func testSpotifyDurationNormalization() {
        XCTAssertEqual(NowPlayingMonitor.normalizeSpotifyDuration(125), 125)
        XCTAssertEqual(NowPlayingMonitor.normalizeSpotifyDuration(125_000), 125)
    }

    func testSpotifyTrackIdentifierUsesStableIDAndSeparatesFallbackTracks() {
        XCTAssertEqual(
            NowPlayingMonitor.spotifyTrackIdentifier(
                trackID: " spotify:track:123 ",
                title: "First",
                artist: "Artist",
                album: "Album",
                duration: 180
            ),
            "spotify:track:123"
        )

        let first = NowPlayingMonitor.spotifyTrackIdentifier(
            trackID: "",
            title: "First",
            artist: "Artist",
            album: "Album",
            duration: 180
        )
        let second = NowPlayingMonitor.spotifyTrackIdentifier(
            trackID: "",
            title: "Second",
            artist: "Artist",
            album: "Album",
            duration: 180
        )
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(
            first,
            NowPlayingMonitor.spotifyTrackIdentifier(
                trackID: "",
                title: "First",
                artist: "Artist",
                album: "Album",
                duration: 180_000
            )
        )
    }

    func testPersistedSliderValuesAreFiniteAndClamped() throws {
        let suiteName = "EdgeBeatTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(-0.25, forKey: "glow.intensity")
        defaults.set(2.5, forKey: "glow.thickness")
        defaults.set(Double.nan, forKey: "waveFlow.length")
        defaults.set(Double.infinity, forKey: "waveFlow.intensity")

        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.intensity, 0)
        XCTAssertEqual(preferences.thickness, 1)
        XCTAssertEqual(preferences.waveLength, 0.5)
        XCTAssertEqual(preferences.waveIntensity, 0.75)
        XCTAssertEqual(defaults.double(forKey: "glow.intensity"), 0)
        XCTAssertEqual(defaults.double(forKey: "glow.thickness"), 1)
    }

    func testGenerationInvalidatesOldWork() {
        var counter = GenerationCounter()
        let first = counter.next()
        XCTAssertTrue(counter.matches(first))

        counter.invalidate()
        XCTAssertFalse(counter.matches(first))

        let second = counter.next()
        XCTAssertTrue(counter.matches(second))
        XCTAssertNotEqual(first, second)
    }

    func testLyricsTimelineTracksLineBoundaries() {
        let lines = [
            LyricsLine(id: 0, timestamp: 4, text: "First"),
            LyricsLine(id: 1, timestamp: 9, text: "Second"),
            LyricsLine(id: 2, timestamp: 15, text: "Third")
        ]

        XCTAssertNil(LyricsTimeline.activeIndex(in: lines, at: 3.99))
        XCTAssertEqual(LyricsTimeline.activeIndex(in: lines, at: 4), 0)
        XCTAssertEqual(LyricsTimeline.activeIndex(in: lines, at: 14.99), 1)
        XCTAssertEqual(LyricsTimeline.activeIndex(in: lines, at: 15), 2)
    }

    func testLyricsDocumentOmitsBlankLinesFromPlaybackViewport() {
        let document = LyricsDocument(
            lines: [
                LyricsLine(id: 0, timestamp: 0, text: "Opening"),
                LyricsLine(id: 1, timestamp: 4, text: "   "),
                LyricsLine(id: 2, timestamp: 8, text: "Next")
            ],
            isSynced: true,
            isInstrumental: false
        )

        XCTAssertEqual(document.visibleLines.map(\.text), ["Opening", "Next"])
    }

    func testEndedAudioSessionCannotPublishFeatures() throws {
        let analyzer = try XCTUnwrap(BeatAnalyzer())
        let staleFeature = expectation(description: "Stale session feature")
        staleFeature.isInverted = true
        analyzer.onFeatures = { _, session in
            if session == 1 { staleFeature.fulfill() }
        }

        analyzer.beginSession(1)
        analyzer.endSession(1)
        analyzer.consume(
            samples: [Float](repeating: 0.5, count: 2_048),
            sampleRate: 44_100,
            session: 1
        )

        wait(for: [staleFeature], timeout: 0.25)
    }

    func testMediaRemoteHelperTimesOut() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let scriptURL = directory.appendingPathComponent("hung-helper.pl")
        let frameworkURL = directory.appendingPathComponent("adapter.framework")
        try Data("sleep 5; print \"{}\";".utf8).write(to: scriptURL)
        try Data().write(to: frameworkURL)

        let adapter = MediaRemoteAdapter(
            scriptURL: scriptURL,
            frameworkURL: frameworkURL,
            processTimeout: 0.05
        )
        let startedAt = Date()
        XCTAssertNil(adapter.readTrack(preferredSource: .automatic))
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1.5)
    }

    private func makeTrack(title: String,
                           artworkRevision: String = "") -> NowPlayingTrack {
        NowPlayingTrack(
            source: .music,
            title: title,
            artist: "Artist",
            album: "Album",
            artwork: nil,
            artworkRevision: artworkRevision,
            identifier: "track-id",
            state: .playing,
            processID: nil,
            duration: 180,
            position: 20,
            isShuffleEnabled: false
        )
    }
}
