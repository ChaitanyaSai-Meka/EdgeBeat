import AppKit

enum PlayerSource: String, CaseIterable {
    case automatic = "Automatic"
    case spotify = "Spotify"
    case music = "Apple Music"
}

enum PlaybackState: String {
    case playing
    case paused
    case stopped
    case unavailable
}

enum PlaybackCommand: String {
    case previousTrack = "previous track"
    case togglePlayPause = "playpause"
    case nextTrack = "next track"
    case toggleShuffle = "toggle shuffle"
}

enum AudioOutputKind: Equatable {
    case mac
    case earbuds
    case headphones
    case speaker

    var symbolName: String {
        switch self {
        case .mac: "laptopcomputer"
        case .earbuds: "airpodspro"
        case .headphones: "headphones"
        case .speaker: "hifispeaker.fill"
        }
    }
}

struct AudioOutputRoute: Equatable {
    let name: String
    let kind: AudioOutputKind

    static let builtIn = AudioOutputRoute(name: "Mac Speakers", kind: .mac)
}

struct NowPlayingTrack: Equatable {
    let source: PlayerSource
    let title: String
    let artist: String
    let album: String
    let artwork: NSImage?
    let identifier: String
    let state: PlaybackState
    let processID: pid_t?
    let duration: TimeInterval
    let position: TimeInterval
    let isShuffleEnabled: Bool

    static let empty = NowPlayingTrack(
        source: .automatic,
        title: "",
        artist: "",
        album: "",
        artwork: nil,
        identifier: "",
        state: .unavailable,
        processID: nil,
        duration: 0,
        position: 0,
        isShuffleEnabled: false
    )

    static func == (lhs: NowPlayingTrack, rhs: NowPlayingTrack) -> Bool {
        lhs.source == rhs.source
            && lhs.identifier == rhs.identifier
            && lhs.state == rhs.state
            && lhs.isShuffleEnabled == rhs.isShuffleEnabled
    }

    func withArtwork(_ artwork: NSImage?) -> NowPlayingTrack {
        NowPlayingTrack(
            source: source,
            title: title,
            artist: artist,
            album: album,
            artwork: artwork,
            identifier: identifier,
            state: state,
            processID: processID,
            duration: duration,
            position: position,
            isShuffleEnabled: isShuffleEnabled
        )
    }

    func withShuffle(_ enabled: Bool) -> NowPlayingTrack {
        NowPlayingTrack(
            source: source,
            title: title,
            artist: artist,
            album: album,
            artwork: artwork,
            identifier: identifier,
            state: state,
            processID: processID,
            duration: duration,
            position: position,
            isShuffleEnabled: enabled
        )
    }
}
