import AppKit
import SwiftUI

final class RenderState: ObservableObject {
    @Published private(set) var palette = GlowPalette.default
    @Published private(set) var track = NowPlayingTrack.empty
    @Published private(set) var level: Double = 0
    @Published private(set) var beat: Bool = false
    private(set) var waveform: [Double] = []
    private(set) var bass: Double = 0
    private(set) var mid: Double = 0
    private(set) var treble: Double = 0
    @Published private(set) var waveFlowPhase: Double = 0
    private(set) var waveFlowBeatEnvelope: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var trackTitle = ""
    @Published private(set) var trackArtist = ""
    @Published private(set) var isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Published private(set) var audioOutputRoute = AudioOutputRoute.builtIn

    private var beatResetWork: DispatchWorkItem?
    private var paletteTrackIdentifier = ""
    private var waveFlowTimer: Timer?
    private var waveFlowLastFrameTime = 0.0
    private var isWaveFlowAnimationActive = false
    private var waveFlowSpeed = 0.5

    func update(track: NowPlayingTrack) {
        let artworkChanged = (self.track.artwork == nil) != (track.artwork == nil)
        if self.track.identifier != track.identifier
            || self.track.state != track.state
            || self.track.position != track.position
            || self.track.isShuffleEnabled != track.isShuffleEnabled
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
        bass = audio.bass
        mid = audio.mid
        treble = audio.treble
        level = min(1, max(0, audio.level))
        if audio.beat {
            beat = true
            beatResetWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.beat = false }
            beatResetWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
        }
    }

    func setLowPowerMode(_ enabled: Bool) {
        if isLowPowerModeEnabled != enabled {
            isLowPowerModeEnabled = enabled
            if isWaveFlowAnimationActive && waveFlowSpeed > 0 {
                restartWaveFlowTimer()
            }
        }
    }

    func setWaveFlowAnimationActive(_ active: Bool) {
        guard isWaveFlowAnimationActive != active else { return }
        isWaveFlowAnimationActive = active
        if active && waveFlowSpeed > 0 {
            restartWaveFlowTimer()
        } else {
            stopWaveFlowTimer()
        }
    }

    func setWaveFlowSpeed(_ speed: Double) {
        let clampedSpeed = min(1, max(0, speed))
        guard waveFlowSpeed != clampedSpeed else { return }
        let wasStopped = waveFlowSpeed == 0
        waveFlowSpeed = clampedSpeed

        guard isWaveFlowAnimationActive else { return }
        if clampedSpeed == 0 {
            stopWaveFlowTimer()
        } else if wasStopped || waveFlowTimer == nil {
            restartWaveFlowTimer()
        }
    }

    private func restartWaveFlowTimer() {
        guard waveFlowSpeed > 0 else {
            stopWaveFlowTimer()
            return
        }
        waveFlowTimer?.invalidate()
        waveFlowLastFrameTime = ProcessInfo.processInfo.systemUptime
        let interval = 1.0 / (isLowPowerModeEnabled ? 30.0 : 60.0)
        waveFlowTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.advanceWaveFlow()
        }
        waveFlowTimer?.tolerance = interval * 0.05
    }

    private func stopWaveFlowTimer() {
        waveFlowTimer?.invalidate()
        waveFlowTimer = nil
        waveFlowLastFrameTime = 0
        waveFlowBeatEnvelope = 0
    }

    private func advanceWaveFlow() {
        guard isWaveFlowAnimationActive, waveFlowSpeed > 0 else {
            stopWaveFlowTimer()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = min(0.1, max(0, now - waveFlowLastFrameTime))
        waveFlowLastFrameTime = now
        if beat {
            waveFlowBeatEnvelope += (1 - waveFlowBeatEnvelope) * 0.55
        } else {
            waveFlowBeatEnvelope *= max(0, 1 - elapsed * 4.5)
        }
        let baseSpeed = 0.14 * pow(waveFlowSpeed, 1.25)
        let musicMultiplier = 1 + level * 0.5 + bass * 0.4
            + waveFlowBeatEnvelope * 0.35
        waveFlowPhase = (waveFlowPhase + elapsed * baseSpeed * musicMultiplier)
            .truncatingRemainder(dividingBy: 1)
    }

    func update(audioOutputRoute: AudioOutputRoute) {
        if self.audioOutputRoute != audioOutputRoute {
            self.audioOutputRoute = audioOutputRoute
        }
    }
}

extension GlowPalette {
    var swiftUIColors: [Color] {
        [Color(nsColor: primary), Color(nsColor: secondary), Color(nsColor: accent), Color(nsColor: primary)]
    }
}
