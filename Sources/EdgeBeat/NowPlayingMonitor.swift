import AppKit
import Foundation
import OSLog

final class NowPlayingMonitor {
    var onPlaybackUpdate: ((NowPlayingTrack) -> Void)?

    private(set) var source: PlayerSource = .automatic

    private var timer: Timer?
    private var isRunning = false
    private var lastTrack = NowPlayingTrack.empty
    private var pollGeneration = 0
    private var artworkCache: [String: NSImage] = [:]
    private var compiledScripts: [String: NSAppleScript] = [:]
    private var isPolling = false
    private var isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    private var spotifyPlaybackObserver: NSObjectProtocol?
    private let mediaRemote = MediaRemoteAdapter()
    private let pollQueue = DispatchQueue(label: "com.chaitanya.edgebeat.now-playing", qos: .utility)
    private let logger = Logger(subsystem: "com.chaitanya.edgebeat", category: "now-playing")

    func start() {
        guard !isRunning else { return }
        isRunning = true
        spotifyPlaybackObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.requestImmediatePoll()
        }
        pollNow()
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        if let spotifyPlaybackObserver {
            DistributedNotificationCenter.default().removeObserver(spotifyPlaybackObserver)
            self.spotifyPlaybackObserver = nil
        }
    }

    func setSource(_ source: PlayerSource) {
        guard self.source != source else { return }
        self.source = source
        if isRunning { requestImmediatePoll() }
    }

    func setLowPowerMode(_ enabled: Bool) {
        isLowPowerModeEnabled = enabled
    }

    func perform(_ command: PlaybackCommand, for source: PlayerSource) {
        guard source == .spotify || source == .music else { return }
        let appName = source == .spotify ? "Spotify" : "Music"
        let script = "tell application \"\(appName)\" to \(command.rawValue)"

        pollQueue.async { [weak self] in
            guard let self else { return }
            let sentByMediaRemote = source == .spotify && self.mediaRemote.send(command)
            if !sentByMediaRemote {
                self.executeAppleScript(script, key: "command.\(source.rawValue).\(command.rawValue)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.requestImmediatePoll()
            }
        }
    }

    private func requestImmediatePoll() {
        timer?.invalidate()
        if isPolling {
            scheduleNextPoll(after: 0.25)
        } else {
            pollNow()
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
                let artwork = self.artworkCache[track.identifier] ?? track.artwork
                if let artwork { self.artworkCache[track.identifier] = artwork }
                let resolvedTrack = track.withArtwork(artwork)
                self.onPlaybackUpdate?(resolvedTrack)
                if resolvedTrack != self.lastTrack {
                    self.lastTrack = resolvedTrack
                    self.loadArtwork(for: track)
                }
                self.scheduleNextPoll(after: self.pollInterval(for: resolvedTrack.state))
            }
        }
    }

    private func scheduleNextPoll(after delay: TimeInterval) {
        guard isRunning else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.pollNow()
        }
        timer?.tolerance = delay < 1 ? 0.05 : min(2, max(0.2, delay * 0.2))
    }

    private func pollInterval(for state: PlaybackState) -> TimeInterval {
        if isLowPowerModeEnabled {
            return switch state {
            case .playing: 3
            case .paused: 8
            case .stopped, .unavailable: 20
            }
        }
        return switch state {
        case .playing: 2
        case .paused: 5
        case .stopped, .unavailable: 10
        }
    }

    private func readTrack(source: PlayerSource) -> NowPlayingTrack {
        if shouldUseMediaRemote(for: source),
           let track = mediaRemote.readTrack(preferredSource: source),
           track.state == .playing || track.state == .paused {
            return track
        }

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

    private func shouldUseMediaRemote(for source: PlayerSource) -> Bool {
        guard source != .music, mediaRemote.isAvailable else { return false }
        return !NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.spotify.client"
        ).isEmpty
    }

    private func readPlayer(_ source: PlayerSource) -> NowPlayingTrack? {
        switch source {
        case .spotify:
            return readSpotify()
        case .music:
            return readAppleMusic()
        case .automatic:
            return nil
        }
    }

    private func readAppleMusic() -> NowPlayingTrack? {
        let script = """
        set separator to ASCII character 31
        if application \"Music\" is running then
          tell application \"Music\"
            set stateText to (player state as text)
            if stateText is \"stopped\" then return \"\"
            if not (exists current track) then return \"\"
            set trackName to name of current track
            set artistName to artist of current track
            set albumName to album of current track
            set trackID to \"Apple Music\" & separator & trackName & separator & artistName & separator & albumName
            set trackID to trackID & separator & (persistent ID of current track)
            set durationValue to duration of current track
            set positionValue to player position
            return stateText & separator & trackID & separator & durationValue & separator & positionValue
          end tell
        end if
        return \"\"
        """

        guard let output = runAppleScript(script, key: "Apple Music.Playback"), !output.isEmpty else {
            return nil
        }
        let fields = output.components(separatedBy: String(UnicodeScalar(31)))
        guard fields.count >= 8 else { return nil }
        let state = PlaybackState(rawValue: fields[0]) ?? .unavailable
        let identifier = fields[5]
        let processID = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.Music"
        ).first?.processIdentifier
        return NowPlayingTrack(
            source: .music,
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

    private func readSpotify() -> NowPlayingTrack? {
        let script = """
        if application "Spotify" is not running then return {}
        tell application "Spotify"
          try
            set stateText to (player state as text)
            if stateText is "stopped" then return {}
            return {stateText, name of current track, artist of current track, album of current track, artwork url of current track, duration of current track, player position}
          on error
            return {}
          end try
        end tell
        """

        guard let descriptor = runAppleScriptDescriptor(script, key: "Spotify.Playback"),
              descriptor.numberOfItems >= 7 else { return nil }
        let state = PlaybackState(rawValue: descriptor.atIndex(1)?.stringValue?.lowercased() ?? "")
            ?? .unavailable
        guard state == .playing || state == .paused else { return nil }

        let artworkURL = descriptor.atIndex(5)?.stringValue ?? ""
        let processID = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.spotify.client"
        ).first?.processIdentifier
        return NowPlayingTrack(
            source: .spotify,
            title: descriptor.atIndex(2)?.stringValue ?? "",
            artist: descriptor.atIndex(3)?.stringValue ?? "",
            album: descriptor.atIndex(4)?.stringValue ?? "",
            artwork: nil,
            identifier: artworkURL,
            state: state,
            processID: processID,
            duration: normalizedSpotifyDuration(descriptor.atIndex(6)?.doubleValue ?? 0),
            position: descriptor.atIndex(7)?.doubleValue ?? 0
        )
    }

    private func normalizedSpotifyDuration(_ duration: TimeInterval) -> TimeInterval {
        // Spotify historically reports milliseconds despite documenting seconds.
        // Newer builds may return seconds, so only scale values longer than one day.
        duration > 86_400 ? duration / 1_000 : duration
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
        guard let descriptor = runAppleScriptDescriptor(source, key: key) else { return nil }
        return descriptor.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runAppleScriptDescriptor(_ source: String, key: String) -> NSAppleEventDescriptor? {
        guard let script = compiledScript(source: source, key: key) else { return nil }
        var error: NSDictionary?
        let descriptor = script.executeAndReturnError(&error)
        if let error {
            logger.error("Now-playing script failed: \(error.description, privacy: .public)")
            return nil
        }
        return descriptor
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
