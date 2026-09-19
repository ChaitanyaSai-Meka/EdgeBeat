import AppKit
import SwiftUI

final class RenderState: ObservableObject {
    @Published private(set) var palette = GlowPalette.default
    @Published private(set) var track = NowPlayingTrack.empty
    @Published private(set) var recentTracks: [NowPlayingTrack] = []
    @Published private(set) var level: Double = 0
    @Published private(set) var beat: Bool = false
    private(set) var waveform: [Double] = []
    private(set) var bass: Double = 0
    private(set) var mid: Double = 0
    private(set) var treble: Double = 0
    private(set) var beatEnvelope: Double = 0
    @Published private(set) var waveFlowPhase: Double = 0
    private(set) var waveFlowBeatEnvelope: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var trackTitle = ""
    @Published private(set) var trackArtist = ""
    @Published private(set) var isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Published private(set) var audioOutputRoute = AudioOutputRoute.builtIn

    private var beatResetWork: DispatchWorkItem?
    private var audioSmoothingTimer: Timer?
    private var audioSmoothingLastFrameTime = 0.0
    private var targetLevel = 0.0
    private var targetBass = 0.0
    private var targetMid = 0.0
    private var targetTreble = 0.0
    private var targetWaveform: [Double] = []
    private var hasAudioTarget = false
    private var paletteTrackIdentifier = ""
    private var paletteArtworkRevision = ""
    private var waveFlowTimer: Timer?
    private var waveFlowLastFrameTime = 0.0
    private var isWaveFlowAnimationActive = false
    private var waveFlowSpeed = 0.5
    private var waveFlowDirection = WaveFlowDirection.clockwise

    func update(track: NowPlayingTrack) {
        if !track.identifier.isEmpty,
           track.identifier != self.track.identifier,
           !recentTracks.contains(where: { $0.identifier == track.identifier }) {
            recentTracks.insert(track, at: 0)
            if recentTracks.count > 12 { recentTracks.removeLast() }
        }
        let artworkChanged = self.track.artworkRevision != track.artworkRevision
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
        if track.artwork != nil,
           (track.identifier != paletteTrackIdentifier
            || track.artworkRevision != paletteArtworkRevision) {
            palette = PaletteExtractor.extract(from: track.artwork)
            paletteTrackIdentifier = track.identifier
            paletteArtworkRevision = track.artworkRevision
        } else if track.identifier.isEmpty {
            palette = .default
            paletteTrackIdentifier = ""
            paletteArtworkRevision = ""
        } else if track.artwork == nil, track.identifier != paletteTrackIdentifier {
            palette = .default
            paletteTrackIdentifier = track.identifier
            paletteArtworkRevision = ""
        }
        if !playing {
            resetAudio()
        }
    }

    func update(audio: AudioFeatures) {
        hasAudioTarget = true
        targetWaveform = audio.waveform
        targetBass = min(1, max(0, audio.bass))
        targetMid = min(1, max(0, audio.mid))
        targetTreble = min(1, max(0, audio.treble))
        targetLevel = min(1, max(0, audio.level))
        startAudioSmoothingTimerIfNeeded()
        if audio.beat {
            beat = true
            beatResetWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.beat = false }
            beatResetWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
        }
    }

    func resetAudio() {
        beatResetWork?.cancel()
        beatResetWork = nil
        stopAudioSmoothingTimer()
        targetWaveform.removeAll(keepingCapacity: true)
        targetLevel = 0
        targetBass = 0
        targetMid = 0
        targetTreble = 0
        hasAudioTarget = false
        waveform = []
        bass = 0
        mid = 0
        treble = 0
        beatEnvelope = 0
        level = 0
        beat = false
    }

    func setLowPowerMode(_ enabled: Bool) {
        if isLowPowerModeEnabled != enabled {
            isLowPowerModeEnabled = enabled
            if audioSmoothingTimer != nil {
                restartAudioSmoothingTimer()
            }
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

    func setWaveFlowDirection(_ direction: WaveFlowDirection) {
        waveFlowDirection = direction
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
        let nextPhase = waveFlowPhase
            + elapsed * baseSpeed * musicMultiplier * waveFlowDirection.phaseSign
        let remainder = nextPhase.truncatingRemainder(dividingBy: 1)
        waveFlowPhase = remainder >= 0 ? remainder : remainder + 1
    }

    func update(audioOutputRoute: AudioOutputRoute) {
        if self.audioOutputRoute != audioOutputRoute {
            self.audioOutputRoute = audioOutputRoute
        }
    }

    private func startAudioSmoothingTimerIfNeeded() {
        guard isPlaying, hasAudioTarget, audioSmoothingTimer == nil else { return }
        restartAudioSmoothingTimer()
    }

    private func restartAudioSmoothingTimer() {
        stopAudioSmoothingTimer()
        let interval = 1.0 / (isLowPowerModeEnabled ? 30.0 : 60.0)
        audioSmoothingLastFrameTime = ProcessInfo.processInfo.systemUptime
        audioSmoothingTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.advanceAudioSmoothing()
        }
        audioSmoothingTimer?.tolerance = interval * 0.05
    }

    private func stopAudioSmoothingTimer() {
        audioSmoothingTimer?.invalidate()
        audioSmoothingTimer = nil
        audioSmoothingLastFrameTime = 0
    }

    private func advanceAudioSmoothing() {
        guard isPlaying, hasAudioTarget else {
            stopAudioSmoothingTimer()
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = min(0.1, max(0, now - audioSmoothingLastFrameTime))
        audioSmoothingLastFrameTime = now
        guard elapsed > 0 else { return }

        let levelCoefficient = smoothingCoefficient(
            from: level, to: targetLevel, elapsed: elapsed,
            attack: 0.075, release: 0.24
        )
        let bandCoefficient = smoothingCoefficient(
            from: bass, to: targetBass, elapsed: elapsed,
            attack: 0.06, release: 0.2
        )
        let waveformCoefficient = 1 - exp(-elapsed / 0.075)
        if beat {
            beatEnvelope += (1 - beatEnvelope) * (1 - exp(-elapsed / 0.045))
        } else {
            beatEnvelope *= exp(-elapsed / 0.22)
        }
        level += (targetLevel - level) * levelCoefficient
        bass += (targetBass - bass) * bandCoefficient
        mid += (targetMid - mid) * bandCoefficient
        treble += (targetTreble - treble) * bandCoefficient

        let count = max(waveform.count, targetWaveform.count)
        if count > 0 {
            var smoothed = [Double](repeating: 0, count: count)
            for index in 0..<count {
                let current = index < waveform.count ? waveform[index] : 0
                let target = index < targetWaveform.count ? targetWaveform[index] : 0
                smoothed[index] = current + (target - current) * waveformCoefficient
            }
            waveform = smoothed
        }
        objectWillChange.send()
    }

    private func smoothingCoefficient(from current: Double, to target: Double,
                                      elapsed: Double, attack: Double,
                                      release: Double) -> Double {
        let timeConstant = target >= current ? attack : release
        return 1 - exp(-elapsed / timeConstant)
    }
}

extension GlowPalette {
    var swiftUIColors: [Color] {
        [Color(nsColor: primary), Color(nsColor: secondary), Color(nsColor: accent), Color(nsColor: primary)]
    }
}
