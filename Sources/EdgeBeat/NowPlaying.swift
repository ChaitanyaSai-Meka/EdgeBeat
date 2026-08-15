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
        position: 0
    )

    static func == (lhs: NowPlayingTrack, rhs: NowPlayingTrack) -> Bool {
        lhs.source == rhs.source && lhs.identifier == rhs.identifier && lhs.state == rhs.state
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
            position: position
        )
    }
}
