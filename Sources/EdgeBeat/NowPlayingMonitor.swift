import AppKit
import Foundation
import OSLog

final class NowPlayingMonitor {
    var onTrackChange: ((NowPlayingTrack) -> Void)?
    var onPlaybackUpdate: ((NowPlayingTrack) -> Void)?

    private(set) var source: PlayerSource = .automatic {
        didSet {
            if oldValue != source { pollNow() }
        }
    }

    private var timer: Timer?
    private var isRunning = false
    private var lastTrack = NowPlayingTrack.empty
    private var pollGeneration = 0
    private var artworkCache: [String: NSImage] = [:]
    private var compiledScripts: [String: NSAppleScript] = [:]
    private var isPolling = false
    private let pollQueue = DispatchQueue(label: "com.chaitanya.edgebeat.now-playing", qos: .utility)
    private let logger = Logger(subsystem: "com.chaitanya.edgebeat", category: "now-playing")

    func start() {
        guard !isRunning else { return }
        isRunning = true
        pollNow()
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
    }

    func setSource(_ source: PlayerSource) {
        self.source = source
    }

    func perform(_ command: PlaybackCommand, for source: PlayerSource) {
        guard source == .spotify || source == .music else { return }
        let appName = source == .spotify ? "Spotify" : "Music"
        let script = "tell application \"\(appName)\" to \(command.rawValue)"

        pollQueue.async { [weak self] in
            guard let self else { return }
            self.executeAppleScript(script, key: "command.\(source.rawValue).\(command.rawValue)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.timer?.invalidate()
                if self.isPolling {
                    self.scheduleNextPoll(after: 0.25)
                } else {
                    self.pollNow()
                }
            }
        }
    }

    private func pollNow() {
        guard !isPolling else { return }
        isPolling = true
        pollGeneration += 1
        let generation = pollGeneration
        let requestedSource = source
        pollQueue.async { [weak self] in
            guard let self else { return }
            let track = self.readTrack(source: requestedSource)
            DispatchQueue.main.async {
                self.isPolling = false
                guard generation == self.pollGeneration else { return }
                let resolvedTrack = track.withArtwork(self.artworkCache[track.identifier])
                self.onPlaybackUpdate?(resolvedTrack)
                if resolvedTrack != self.lastTrack {
                    self.lastTrack = resolvedTrack
                    self.onTrackChange?(resolvedTrack)
                    self.loadArtwork(for: track)
                }
                let delay: TimeInterval = switch resolvedTrack.state {
                case .playing: 1.5
                case .paused: 3
                case .stopped, .unavailable: 5
                }
                self.scheduleNextPoll(after: delay)
            }
        }
    }

    private func scheduleNextPoll(after delay: TimeInterval) {
        guard isRunning else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.pollNow()
        }
    }

    private func readTrack(source: PlayerSource) -> NowPlayingTrack {
        let candidates: [PlayerSource] = switch source {
        case .automatic: [.spotify, .music]
        case .spotify: [.spotify]
        case .music: [.music]
        }

        for candidate in candidates {
            if let track = readPlayer(candidate), track.state == .playing || track.state == .paused {
                return track
            }
        }
        return .empty
    }

    private func readPlayer(_ source: PlayerSource) -> NowPlayingTrack? {
        let appName = source == .spotify ? "Spotify" : "Music"
        let artworkIdentifier = source == .spotify
            ? "artwork url of current track"
            : "persistent ID of current track"
        let durationExpression = source == .spotify
            ? "(duration of current track) / 1000"
            : "duration of current track"
        let script = """
        set separator to ASCII character 31
        if application \"\(appName)\" is running then
          tell application \"\(appName)\"
            set stateText to (player state as text)
            if stateText is \"stopped\" then return \"\"
            if not (exists current track) then return \"\"
            set trackName to name of current track
            set artistName to artist of current track
            set albumName to album of current track
            set trackID to \"\(source.rawValue)\" & separator & trackName & separator & artistName & separator & albumName
            set trackID to trackID & separator & (\(artworkIdentifier))
            set durationValue to \(durationExpression)
            set positionValue to player position
            return stateText & separator & trackID & separator & durationValue & separator & positionValue
          end tell
        end if
        return \"\"
        """

        guard let output = runAppleScript(script, key: source.rawValue), !output.isEmpty else { return nil }
        let fields = output.components(separatedBy: String(UnicodeScalar(31)))
        guard fields.count >= 8 else { return nil }
        let state = PlaybackState(rawValue: fields[0]) ?? .unavailable
        let identifier = fields[5]
        let processID = NSRunningApplication.runningApplications(
            withBundleIdentifier: source == .spotify ? "com.spotify.client" : "com.apple.Music"
        ).first?.processIdentifier
        return NowPlayingTrack(
            source: source,
            title: fields[2],
            artist: fields[3],
            album: fields[4],
            artwork: nil,
            identifier: identifier,
            state: state,
            processID: processID,
            duration: TimeInterval(fields[6]) ?? 0,
            position: TimeInterval(fields[7]) ?? 0
        )
    }

    private func loadArtwork(for track: NowPlayingTrack) {
        guard !track.identifier.isEmpty, artworkCache[track.identifier] == nil else { return }
        if track.source == .spotify, let url = URL(string: track.identifier) {
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
                guard let self, let data, let image = NSImage(data: data) else { return }
                DispatchQueue.main.async { self.applyArtwork(image, to: track) }
            }.resume()
        } else if track.source == .music {
            pollQueue.async { [weak self] in
                guard let self, let image = self.readMusicArtwork() else { return }
                DispatchQueue.main.async { self.applyArtwork(image, to: track) }
            }
        }
    }

    private func applyArtwork(_ image: NSImage, to track: NowPlayingTrack) {
        artworkCache[track.identifier] = image
        guard lastTrack.source == track.source, lastTrack.identifier == track.identifier else { return }
        let updatedTrack = track.withArtwork(image)
        lastTrack = updatedTrack
        onPlaybackUpdate?(updatedTrack)
        onTrackChange?(updatedTrack)
    }

    private func readMusicArtwork() -> NSImage? {
        let script = """
        tell application \"Music\"
            if (count of artworks of current track) is 0 then return \"\"
            return raw data of artwork 1 of current track
        end tell
        """
        guard let source = compiledScript(source: script, key: "MusicArtwork") else { return nil }
        var error: NSDictionary?
        let descriptor = source.executeAndReturnError(&error)
        if let error {
            logger.error("Apple Music artwork script failed: \(error.description, privacy: .public)")
        }
        guard !descriptor.data.isEmpty else { return nil }
        return NSImage(data: descriptor.data)
    }

    private func runAppleScript(_ source: String, key: String) -> String? {
        guard let script = compiledScript(source: source, key: key) else { return nil }
        var error: NSDictionary?
        let descriptor = script.executeAndReturnError(&error)
        if let error {
            logger.error("Now-playing script failed: \(error.description, privacy: .public)")
        }
        return descriptor.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func executeAppleScript(_ source: String, key: String) {
        guard let script = compiledScript(source: source, key: key) else { return }
        var error: NSDictionary?
        _ = script.executeAndReturnError(&error)
        if let error {
            logger.error("Playback command failed: \(error.description, privacy: .public)")
        }
    }

    private func compiledScript(source: String, key: String) -> NSAppleScript? {
        if let script = compiledScripts[key] { return script }
        guard let script = NSAppleScript(source: source) else { return nil }
        compiledScripts[key] = script
        return script
    }
}
