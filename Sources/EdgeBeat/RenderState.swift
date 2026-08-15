import AppKit
import SwiftUI

final class RenderState: ObservableObject {
    @Published private(set) var palette = GlowPalette.default
    @Published private(set) var level: Double = 0
    @Published private(set) var beat: Bool = false
    private(set) var waveform: [Double] = []
    @Published private(set) var isPlaying = false
    @Published private(set) var trackTitle = ""
    @Published private(set) var trackArtist = ""

    private var beatResetWork: DispatchWorkItem?

    func update(track: NowPlayingTrack) {
        isPlaying = track.state == .playing
        trackTitle = track.title
        trackArtist = track.artist
        if track.artwork != nil {
            palette = PaletteExtractor.extract(from: track.artwork)
        } else if track.identifier.isEmpty {
            palette = .default
        }
        if !isPlaying { level = 0 }
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
