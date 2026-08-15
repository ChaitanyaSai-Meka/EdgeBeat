import AppKit
import SwiftUI

final class RenderState: ObservableObject {
    @Published private(set) var palette = GlowPalette.default
    @Published private(set) var track = NowPlayingTrack.empty
    @Published private(set) var level: Double = 0
    @Published private(set) var beat: Bool = false
    private(set) var waveform: [Double] = []
    @Published private(set) var isPlaying = false
    @Published private(set) var trackTitle = ""
    @Published private(set) var trackArtist = ""

    private var beatResetWork: DispatchWorkItem?
    private var paletteTrackIdentifier = ""

    func update(track: NowPlayingTrack) {
        let artworkChanged = (self.track.artwork == nil) != (track.artwork == nil)
        if self.track.identifier != track.identifier
            || self.track.state != track.state
            || self.track.position != track.position
            || artworkChanged {
            self.track = track
        }
        let playing = track.state == .playing
        if isPlaying != playing { isPlaying = playing }
        if trackTitle != track.title { trackTitle = track.title }
        if trackArtist != track.artist { trackArtist = track.artist }
        if track.artwork != nil, track.identifier != paletteTrackIdentifier {
            palette = PaletteExtractor.extract(from: track.artwork)
            paletteTrackIdentifier = track.identifier
        } else if track.identifier.isEmpty {
            palette = .default
            paletteTrackIdentifier = ""
        }
        if !playing, level != 0 {
            withAnimation(.easeOut(duration: 0.4)) { level = 0 }
        }
    }

    func update(audio: AudioFeatures) {
        waveform = audio.waveform
        level = min(1, max(0, audio.level))
        if audio.beat {
            beat = true
            beatResetWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.beat = false }
            beatResetWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
        }
    }
}

extension GlowPalette {
    var swiftUIColors: [Color] {
        [Color(nsColor: primary), Color(nsColor: secondary), Color(nsColor: accent), Color(nsColor: primary)]
    }
}
