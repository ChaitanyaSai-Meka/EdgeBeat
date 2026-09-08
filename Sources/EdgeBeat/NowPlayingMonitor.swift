import AppKit
import Foundation
import OSLog

final class NowPlayingMonitor {
    var onPlaybackUpdate: ((NowPlayingTrack) -> Void)?

    private(set) var source: PlayerSource = .automatic

    private var timer: Timer?
    private var isRunning = false
    private var lastTrack = NowPlayingTrack.empty
    private var pollGeneration = GenerationCounter()
    private struct ArtworkCacheEntry {
        let image: NSImage
        let revision: String
        let fetchedAt: Date
    }

    private var artworkCache: [String: ArtworkCacheEntry] = [:]
    private var artworkRequests: Set<String> = []
    private var compiledScripts: [String: NSAppleScript] = [:]
    private var isPolling = false
    private var pollRequestedWhileBusy = false
    private var scheduledPollDate: Date?
    private var scheduledPollToken: UInt64 = 0
    private var lastPollStartUptime: TimeInterval?
    private var pendingPlaybackState: PlaybackState?
    private var pendingPlaybackPosition: TimeInterval?
    private var playbackCommandGeneration = 0
    private var isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    private var spotifyPlaybackObserver: NSObjectProtocol?
    private let mediaRemote = MediaRemoteAdapter()
    private let pollQueue = DispatchQueue(label: "com.chaitanya.edgebeat.now-playing", qos: .utility)
    private let commandQueue = DispatchQueue(label: "com.chaitanya.edgebeat.playback-command",
                                              qos: .userInitiated)
    private let mediaRemoteQueue = DispatchQueue(label: "com.chaitanya.edgebeat.media-remote",
                                                  qos: .userInitiated)
    private let appleScriptQueue = DispatchQueue(label: "com.chaitanya.edgebeat.applescript",
                                                  qos: .utility)
    private let logger = Logger(subsystem: "com.chaitanya.edgebeat", category: "now-playing")
    private var lastPlayPauseCommandDate: Date?

    // Spotify can emit PlaybackStateChanged several times per second. Keep
    // notification-driven refreshes responsive while bounding helper launches.
    private static let minimumNotificationPollInterval: TimeInterval = 0.5

    func start() {
        guard !isRunning else { return }
        isRunning = true
        pollRequestedWhileBusy = false
        scheduledPollDate = nil
        lastPollStartUptime = nil
        pendingPlaybackState = nil
        pendingPlaybackPosition = nil
        playbackCommandGeneration += 1
        spotifyPlaybackObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.requestPoll()
        }
        if isPolling {
            pollRequestedWhileBusy = true
        } else {
            pollNow()
        }
    }

    func stop() {
        isRunning = false
        isPolling = false
        pollRequestedWhileBusy = false
        pendingPlaybackState = nil
        pendingPlaybackPosition = nil
        playbackCommandGeneration += 1
        pollGeneration.invalidate()
        timer?.invalidate()
        timer = nil
        scheduledPollDate = nil
        scheduledPollToken &+= 1
        lastPollStartUptime = nil
        if let spotifyPlaybackObserver {
            DistributedNotificationCenter.default().removeObserver(spotifyPlaybackObserver)
            self.spotifyPlaybackObserver = nil
        }
    }

    func setSource(_ source: PlayerSource) {
        guard self.source != source else { return }
        self.source = source
        if isRunning { requestPoll() }
    }

    func setLowPowerMode(_ enabled: Bool) {
        isLowPowerModeEnabled = enabled
    }

    func perform(_ command: PlaybackCommand, for source: PlayerSource) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.perform(command, for: source)
            }
            return
        }
        guard source == .spotify || source == .music else { return }
        let appName = source == .spotify ? "Spotify" : "Music"
        let shouldPlay = lastTrack.state != .playing
        if command == .togglePlayPause {
            let now = Date()
            if let lastPlayPauseCommandDate,
               now.timeIntervalSince(lastPlayPauseCommandDate) < 0.14 {
                return
            }
            lastPlayPauseCommandDate = now
        }
        let script: String
        if command == .toggleShuffle {
            let property = source == .spotify ? "shuffling" : "shuffle enabled"
            script = "tell application \"\(appName)\" to set \(property) to not (\(property))"
        } else if command == .togglePlayPause {
            script = "tell application \"\(appName)\" to \(shouldPlay ? "play" : "pause")"
        } else {
            script = "tell application \"\(appName)\" to \(command.rawValue)"
        }
        let shuffleEnabled = lastTrack.isShuffleEnabled
        let isPlayPause = command == .togglePlayPause
        if isPlayPause {
            let targetState: PlaybackState = shouldPlay ? .playing : .paused
            pendingPlaybackState = targetState
            pendingPlaybackPosition = max(0, lastTrack.position)
            playbackCommandGeneration += 1
            let generation = playbackCommandGeneration
            let optimisticTrack = lastTrack.withState(targetState)
            lastTrack = optimisticTrack
            onPlaybackUpdate?(optimisticTrack)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.playbackCommandGeneration == generation else { return }
                self.pendingPlaybackState = nil
                self.pendingPlaybackPosition = nil
                self.requestPoll()
            }
        }

        commandQueue.async { [weak self] in
            guard let self else { return }
            let sentByMediaRemote: Bool
            if source == .spotify, command == .toggleShuffle {
                sentByMediaRemote = self.mediaRemoteQueue.sync {
                    self.mediaRemote.setShuffle(enabled: !shuffleEnabled)
                }
            } else if source == .spotify, command == .togglePlayPause {
                sentByMediaRemote = self.mediaRemoteQueue.sync {
                    self.mediaRemote.setPlayback(playing: shouldPlay)
                }
            } else {
                sentByMediaRemote = source == .spotify && self.mediaRemoteQueue.sync {
                    self.mediaRemote.send(command)
                }
            }
            if !sentByMediaRemote {
                self.executeAppleScript(script)
            }
            let refreshDelays: [TimeInterval] = isPlayPause ? [0.18, 0.65] : [0.2]
            for delay in refreshDelays {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    self.requestPoll()
                }
            }
        }
    }

    func seek(to position: TimeInterval, for source: PlayerSource) {
        guard source == .spotify || source == .music else { return }
        let target = max(0, position)
        let appName = source == .spotify ? "Spotify" : "Music"
        let script = "tell application \"\(appName)\" to set player position to "
            + String(format: "%.3f", target)

        pollQueue.async { [weak self] in
            guard let self else { return }
            let sentByMediaRemote = source == .spotify && self.mediaRemoteQueue.sync {
                self.mediaRemote.seek(to: target)
            }
            if !sentByMediaRemote {
                self.executeAppleScript(script)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.requestPoll()
            }
        }
    }

    private func requestPoll() {
        guard isRunning else { return }
        if isPolling {
            pollRequestedWhileBusy = true
            return
        }
        // Keep one pending timer and enforce the minimum interval from the
        // previous helper launch. Repeated notifications therefore coalesce
        // instead of repeatedly cancelling and recreating the timer.
        scheduleNextPoll(after: notificationPollDelay())
    }

    private func pollNow() {
        guard isRunning, !isPolling else { return }
        timer?.invalidate()
        timer = nil
        scheduledPollDate = nil
        scheduledPollToken &+= 1
        isPolling = true
        lastPollStartUptime = ProcessInfo.processInfo.systemUptime
        let generation = pollGeneration.next()
        let requestedSource = source
        pollQueue.async { [weak self] in
            guard let self else { return }
            let track = self.readTrack(source: requestedSource)
            DispatchQueue.main.async {
                // A stop/start can leave an older helper completion queued
                // behind a newer poll. Do not mutate the newer poll's state.
                guard self.pollGeneration.matches(generation) else { return }
                self.isPolling = false
                guard self.isRunning else { return }
                var resolvedTrack = self.resolvedArtwork(for: track)
                let previousTrack = self.lastTrack
                let isTransientUnavailable = track.state == .unavailable
                    && !previousTrack.identifier.isEmpty
                if let pendingPlaybackState = self.pendingPlaybackState {
                    let sameTrack = !previousTrack.identifier.isEmpty
                        && resolvedTrack.source == previousTrack.source
                        && resolvedTrack.identifier == previousTrack.identifier
                    let incomingState = resolvedTrack.state
                    let stablePosition = self.pendingPlaybackPosition ?? previousTrack.position

                    if isTransientUnavailable {
                        resolvedTrack = previousTrack.withState(pendingPlaybackState)
                    } else if sameTrack {
                        let positionRegressed = stablePosition > 0.75
                            && resolvedTrack.position < stablePosition - 0.75
                        if positionRegressed {
                            resolvedTrack = resolvedTrack.withPosition(stablePosition)
                        }
                        if incomingState != pendingPlaybackState {
                            resolvedTrack = resolvedTrack.withState(pendingPlaybackState)
                        } else if !positionRegressed {
                            self.pendingPlaybackState = nil
                            self.pendingPlaybackPosition = nil
                            self.playbackCommandGeneration += 1
                        }
                    }
                }
                self.onPlaybackUpdate?(resolvedTrack)
                let artworkContextChanged = resolvedTrack.artworkCacheKey
                    != self.lastTrack.artworkCacheKey
                    || resolvedTrack.artworkRevision != self.lastTrack.artworkRevision
                self.lastTrack = resolvedTrack
                self.loadArtworkIfNeeded(for: track, force: artworkContextChanged)
                if self.pollRequestedWhileBusy {
                    self.pollRequestedWhileBusy = false
                    self.scheduleNextPoll(after: self.notificationPollDelay())
                } else {
                    self.scheduleNextPoll(after: self.pollInterval(for: resolvedTrack.state))
                }
            }
        }
    }

    private func scheduleNextPoll(after delay: TimeInterval) {
        guard isRunning else { return }
        let fireDate = Date().addingTimeInterval(max(0, delay))
        if let scheduledPollDate,
           timer != nil,
           scheduledPollDate <= fireDate {
            return
        }
        timer?.invalidate()
        scheduledPollToken &+= 1
        let token = scheduledPollToken
        scheduledPollDate = fireDate
        timer = Timer.scheduledTimer(withTimeInterval: max(0, delay), repeats: false) {
            [weak self] _ in
            guard let self, self.scheduledPollToken == token else { return }
            self.timer = nil
            self.scheduledPollDate = nil
            self.pollNow()
        }
        timer?.tolerance = delay < 1 ? 0.05 : min(2, max(0.2, delay * 0.2))
    }

    private func notificationPollDelay() -> TimeInterval {
        guard let lastPollStartUptime else { return 0 }
        return max(
            0,
            Self.minimumNotificationPollInterval
                - (ProcessInfo.processInfo.systemUptime - lastPollStartUptime)
        )
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
           let track = mediaRemoteQueue.sync(execute: {
               mediaRemote.readTrack(preferredSource: source, includeArtwork: false)
           }),
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
            set shuffleValue to (shuffle enabled as text)
            return stateText & separator & trackID & separator & durationValue & separator & positionValue & separator & shuffleValue
          end tell
        end if
        return \"\"
        """

        guard let output = runAppleScript(script, key: "Apple Music.Playback"), !output.isEmpty else {
            return nil
        }
        let fields = output.components(separatedBy: String(UnicodeScalar(31)))
        guard fields.count >= 9 else { return nil }
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
            artworkRevision: "",
            identifier: identifier,
            state: state,
            processID: processID,
            duration: TimeInterval(fields[6]) ?? 0,
            position: TimeInterval(fields[7]) ?? 0,
            isShuffleEnabled: fields[8].lowercased() == "true"
        )
    }

    private func readSpotify() -> NowPlayingTrack? {
        let script = """
        if application "Spotify" is not running then return {}
        tell application "Spotify"
          try
            set stateText to (player state as text)
            if stateText is "stopped" then return {}
            set trackIdentifier to ""
            try
              set trackIdentifier to (id of current track)
            end try
            return {stateText, name of current track, artist of current track, album of current track, artwork url of current track, trackIdentifier, duration of current track, player position, shuffling}
          on error
            return {}
          end try
        end tell
        """

        guard let descriptor = executeCachedAppleScript(script, key: "Spotify.Playback"),
              descriptor.numberOfItems >= 9 else { return nil }
        let state = PlaybackState(rawValue: descriptor.atIndex(1)?.stringValue?.lowercased() ?? "")
            ?? .unavailable
        guard state == .playing || state == .paused else { return nil }

        let title = descriptor.atIndex(2)?.stringValue ?? ""
        let artist = descriptor.atIndex(3)?.stringValue ?? ""
        let album = descriptor.atIndex(4)?.stringValue ?? ""
        let artworkURL = descriptor.atIndex(5)?.stringValue ?? ""
        let trackIdentifier = descriptor.atIndex(6)?.stringValue ?? ""
        let rawDuration = descriptor.atIndex(7)?.doubleValue ?? 0
        let duration = Self.normalizeSpotifyDuration(rawDuration)
        let processID = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.spotify.client"
        ).first?.processIdentifier
        return NowPlayingTrack(
            source: .spotify,
            title: title,
            artist: artist,
            album: album,
            artwork: nil,
            artworkRevision: "",
            identifier: Self.spotifyTrackIdentifier(
                trackID: trackIdentifier,
                title: title,
                artist: artist,
                album: album,
                duration: duration
            ),
            artworkURL: artworkURL,
            state: state,
            processID: processID,
            duration: duration,
            position: descriptor.atIndex(8)?.doubleValue ?? 0,
            isShuffleEnabled: descriptor.atIndex(9)?.booleanValue ?? false
        )
    }

    /// Returns Spotify's stable track ID when available, with a deterministic
    /// metadata fallback for older clients or unusual local tracks.
    static func spotifyTrackIdentifier(
        trackID: String,
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval
    ) -> String {
        let normalizedID = trackID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedID.isEmpty else { return normalizedID }

        let normalizedDuration = normalizeSpotifyDuration(duration)
        let durationMilliseconds: String
        if normalizedDuration.isFinite {
            durationMilliseconds = String(Int(max(0, normalizedDuration * 1_000).rounded()))
        } else {
            durationMilliseconds = "0"
        }
        // Length-prefix fields so delimiters in metadata cannot collide.
        let fields = [title, artist, album, durationMilliseconds]
            .map { "\($0.utf8.count):\($0)" }
        return "spotify-track:" + fields.joined(separator: "|")
    }

    static func normalizeSpotifyDuration(_ duration: TimeInterval) -> TimeInterval {
        // Spotify historically reports milliseconds despite documenting seconds.
        // Newer builds may return seconds, so only scale values longer than one day.
        duration > 86_400 ? duration / 1_000 : duration
    }

    private func resolvedArtwork(for track: NowPlayingTrack) -> NowPlayingTrack {
        guard !track.identifier.isEmpty else { return track }
        let key = track.artworkCacheKey
        if let artwork = track.artwork {
            let revision = track.artworkRevision.isEmpty
                ? ArtworkRevision.image(artwork)
                : track.artworkRevision
            storeArtwork(artwork, revision: revision, for: key)
            return track.withArtwork(artwork, revision: revision)
        }
        guard let cached = artworkCache[key] else { return track }
        return track.withArtwork(cached.image, revision: cached.revision)
    }

    private func loadArtworkIfNeeded(for track: NowPlayingTrack, force: Bool) {
        guard !track.identifier.isEmpty else { return }
        guard track.artwork == nil else { return }
        let key = track.artworkCacheKey
        let cacheAge = artworkCache[key].map { Date().timeIntervalSince($0.fetchedAt) }
        let refreshInterval: TimeInterval = track.source == .music ? 30 : 300
        let needsRefresh = cacheAge.map { $0 >= refreshInterval } ?? true
        guard force || needsRefresh else { return }
        guard artworkRequests.insert(key).inserted else { return }

        if track.source == .spotify,
           track.artworkURL.isEmpty,
           mediaRemote.isAvailable {
            mediaRemoteQueue.async { [weak self] in
                guard let self else { return }
                let artworkTrack = self.mediaRemote.readTrack(
                    preferredSource: .spotify,
                    includeArtwork: true
                )
                DispatchQueue.main.async {
                    self.artworkRequests.remove(key)
                    guard let artworkTrack,
                          artworkTrack.identifier == track.identifier,
                          let image = artworkTrack.artwork else { return }
                    self.applyArtwork(
                        image,
                        revision: artworkTrack.artworkRevision,
                        to: track
                    )
                }
            }
        } else if track.source == .spotify,
           let url = URL(string: track.artworkURL),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.artworkRequests.remove(key)
                    guard let data, let image = NSImage(data: data) else { return }
                    self.applyArtwork(
                        image,
                        revision: ArtworkRevision.data(data),
                        to: track
                    )
                }
            }.resume()
        } else if track.source == .music {
            pollQueue.async { [weak self] in
                guard let self else { return }
                let image = self.readMusicArtwork()
                DispatchQueue.main.async {
                    self.artworkRequests.remove(key)
                    guard let image else { return }
                    self.applyArtwork(
                        image,
                        revision: ArtworkRevision.image(image),
                        to: track
                    )
                }
            }
        } else {
            artworkRequests.remove(key)
        }
    }

    private func storeArtwork(_ image: NSImage, revision: String, for key: String) {
        artworkCache[key] = ArtworkCacheEntry(
            image: image,
            revision: revision,
            fetchedAt: Date()
        )
        if artworkCache.count > 32,
           let oldest = artworkCache.min(by: { $0.value.fetchedAt < $1.value.fetchedAt })?.key {
            artworkCache.removeValue(forKey: oldest)
        }
    }

    private func applyArtwork(_ image: NSImage, revision: String, to track: NowPlayingTrack) {
        storeArtwork(image, revision: revision, for: track.artworkCacheKey)
        guard lastTrack.artworkCacheKey == track.artworkCacheKey else { return }
        let updatedTrack = lastTrack.withArtwork(image, revision: revision)
        guard updatedTrack.artworkRevision != lastTrack.artworkRevision else { return }
        lastTrack = updatedTrack
        onPlaybackUpdate?(updatedTrack)
    }

    private func readMusicArtwork() -> NSImage? {
        // Check before sending an Apple Event so a background artwork refresh
        // cannot relaunch Music after the user has quit it.
        guard !NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.Music"
        ).isEmpty else { return nil }
        let script = """
        if application \"Music\" is not running then return \"\"
        tell application \"Music\"
            if not (exists current track) then return \"\"
            if (count of artworks of current track) is 0 then return \"\"
            return raw data of artwork 1 of current track
        end tell
        """
        guard let descriptor = executeCachedAppleScript(script, key: "MusicArtwork") else { return nil }
        guard !descriptor.data.isEmpty else { return nil }
        return NSImage(data: descriptor.data)
    }

    private func runAppleScript(_ source: String, key: String) -> String? {
        guard let descriptor = executeCachedAppleScript(source, key: key) else { return nil }
        return descriptor.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func executeAppleScript(_ source: String) {
        appleScriptQueue.sync {
            guard let script = NSAppleScript(source: source) else { return }
            var error: NSDictionary?
            _ = script.executeAndReturnError(&error)
            if let error {
                logger.error("Playback command failed: \(error.description, privacy: .public)")
            }
        }
    }

    private func executeCachedAppleScript(
        _ source: String,
        key: String
    ) -> NSAppleEventDescriptor? {
        appleScriptQueue.sync {
            let script: NSAppleScript
            if let cached = compiledScripts[key] {
                script = cached
            } else {
                guard let compiled = NSAppleScript(source: source) else { return nil }
                compiledScripts[key] = compiled
                script = compiled
            }

            var error: NSDictionary?
            let descriptor = script.executeAndReturnError(&error)
            if let error {
                logger.error("AppleScript failed: \(error.description, privacy: .public)")
                return nil
            }
            return descriptor
        }
    }
}
