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

enum ArtworkRevision {
    static func data(_ data: Data) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    static func image(_ image: NSImage?) -> String {
        guard let data = image?.tiffRepresentation else { return "" }
        return self.data(data)
    }
}

struct GenerationCounter {
    private(set) var current: UInt64 = 0

    mutating func next() -> UInt64 {
        current &+= 1
        return current
    }

    mutating func invalidate() {
        current &+= 1
    }

    func matches(_ generation: UInt64) -> Bool {
        generation == current
    }
}

struct NowPlayingTrack: Equatable {
    let source: PlayerSource
    let title: String
    let artist: String
    let album: String
    let artwork: NSImage?
    let artworkRevision: String
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
        artworkRevision: "",
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
            && lhs.title == rhs.title
            && lhs.artist == rhs.artist
            && lhs.album == rhs.album
            && lhs.duration == rhs.duration
            && lhs.artworkRevision == rhs.artworkRevision
    }

    var artworkCacheKey: String {
        [source.rawValue, identifier, title, artist, album].joined(separator: "|")
    }

    func withArtwork(_ artwork: NSImage?, revision: String? = nil) -> NowPlayingTrack {
        NowPlayingTrack(
            source: source,
            title: title,
            artist: artist,
            album: album,
            artwork: artwork,
            artworkRevision: artwork == nil ? "" : (revision ?? ArtworkRevision.image(artwork)),
            identifier: identifier,
            state: state,
            processID: processID,
            duration: duration,
            position: position,
            isShuffleEnabled: isShuffleEnabled
        )
    }

    func withState(_ state: PlaybackState) -> NowPlayingTrack {
        NowPlayingTrack(
            source: source,
            title: title,
            artist: artist,
            album: album,
            artwork: artwork,
            artworkRevision: artworkRevision,
            identifier: identifier,
            state: state,
            processID: processID,
            duration: duration,
            position: position,
            isShuffleEnabled: isShuffleEnabled
        )
    }

    func withPosition(_ position: TimeInterval) -> NowPlayingTrack {
        NowPlayingTrack(
            source: source,
            title: title,
            artist: artist,
            album: album,
            artwork: artwork,
            artworkRevision: artworkRevision,
            identifier: identifier,
            state: state,
            processID: processID,
            duration: duration,
            position: max(0, position),
            isShuffleEnabled: isShuffleEnabled
        )
    }
}
