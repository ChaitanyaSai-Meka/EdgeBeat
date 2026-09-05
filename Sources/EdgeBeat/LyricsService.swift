import Combine
import Foundation

struct LyricsLine: Equatable, Identifiable {
    let id: Int
    let timestamp: TimeInterval?
    let text: String
}

struct LyricsDocument: Equatable {
    let lines: [LyricsLine]
    let isSynced: Bool
    let isInstrumental: Bool

    var text: String {
        lines.map(\.text).joined(separator: "\n")
    }

    var visibleLines: [LyricsLine] {
        lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

enum LyricsTimeline {
    static func activeIndex(in lines: [LyricsLine], at position: TimeInterval) -> Int? {
        let timedIndices = lines.indices.filter { lines[$0].timestamp != nil }
        guard !timedIndices.isEmpty, position.isFinite else { return nil }

        var lowerBound = 0
        var upperBound = timedIndices.count - 1
        var result: Int?

        while lowerBound <= upperBound {
            let midpoint = (lowerBound + upperBound) / 2
            let lineIndex = timedIndices[midpoint]
            guard let timestamp = lines[lineIndex].timestamp else { break }

            if timestamp <= position {
                result = lineIndex
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint - 1
            }
        }

        return result
    }

    static func progress(
        in lines: [LyricsLine],
        activeIndex: Int?,
        at position: TimeInterval,
        duration: TimeInterval
    ) -> Double {
        guard let activeIndex,
              lines.indices.contains(activeIndex),
              let start = lines[activeIndex].timestamp,
              start.isFinite,
              position.isFinite else { return 0 }

        let nextStart = lines[(activeIndex + 1)...]
            .compactMap(\.timestamp)
            .first
        let fallbackEnd = duration > start ? duration : start + 4
        let end = max(start + 0.5, nextStart ?? fallbackEnd)
        return min(1, max(0, (position - start) / (end - start)))
    }
}

enum LyricsState: Equatable {
    case idle
    case loading
    case loaded(LyricsDocument)
    case unavailable
    case failed(String)
}

final class LyricsStore: ObservableObject {
    @Published private(set) var state: LyricsState = .idle

    private struct LookupKey: Hashable {
        let title: String
        let artist: String
        let album: String

        init(title: String, artist: String, album: String) {
            self.title = Self.normalized(title)
            self.artist = Self.normalized(artist)
            self.album = Self.normalized(album)
        }

        private static func normalized(_ value: String) -> String {
            value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        }
    }

    private struct LyricsResponse: Decodable {
        let plainLyrics: String?
        let syncedLyrics: String?
        let instrumental: Bool?
    }

    private enum CachedResult {
        case document(LyricsDocument)
        case unavailable
    }

    private enum LookupResult {
        case document(LyricsDocument)
        case unavailable
        case failed(String)
    }

    private let session: URLSession
    private var task: URLSessionDataTask?
    private var requestGeneration = 0
    private var currentKey: LookupKey?
    private var cache: [LookupKey: CachedResult] = [:]

    init(session: URLSession = .shared) {
        self.session = session
    }

    deinit {
        task?.cancel()
    }

    func load(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval,
        force: Bool = false
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.load(title: title, artist: artist, album: album,
                           duration: duration, force: force)
            }
            return
        }

        let key = LookupKey(title: title, artist: artist, album: album)
        guard !key.title.isEmpty, !key.artist.isEmpty else {
            task?.cancel()
            task = nil
            currentKey = nil
            state = .unavailable
            return
        }

        if !force, currentKey == key {
            switch state {
            case .loading, .loaded, .unavailable:
                return
            case .idle, .failed:
                break
            }
        }

        task?.cancel()
        task = nil
        currentKey = key
        requestGeneration &+= 1
        let generation = requestGeneration

        if !force, let cached = cache[key] {
            apply(cached)
            return
        }

        guard let url = makeURL(title: title, artist: artist, album: album,
                                duration: duration) else {
            state = .failed("The lyrics request could not be created.")
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("EdgeBeat", forHTTPHeaderField: "User-Agent")
        state = .loading

        task = session.dataTask(with: request) { [weak self] data, response, error in
            let result = Self.process(data: data, response: response, error: error)
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.requestGeneration == generation,
                      self.currentKey == key else { return }
                self.task = nil
                switch result {
                case let .document(document):
                    self.cacheResult(.document(document), for: key)
                    self.state = .loaded(document)
                case .unavailable:
                    self.cacheResult(.unavailable, for: key)
                    self.state = .unavailable
                case let .failed(message):
                    self.state = .failed(message)
                }
            }
        }
        task?.resume()
    }

    func reset() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.reset() }
            return
        }
        task?.cancel()
        task = nil
        requestGeneration &+= 1
        currentKey = nil
        state = .idle
    }

    private func apply(_ cached: CachedResult) {
        switch cached {
        case let .document(document): state = .loaded(document)
        case .unavailable: state = .unavailable
        }
    }

    private func cacheResult(_ result: CachedResult, for key: LookupKey) {
        cache[key] = result
        if cache.count > 32, let firstKey = cache.keys.first {
            cache.removeValue(forKey: firstKey)
        }
    }

    private func makeURL(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval
    ) -> URL? {
        var components = URLComponents(string: "https://lrclib.net/api/get")
        components?.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "album_name", value: album),
            URLQueryItem(
                name: "duration",
                value: duration > 0 ? String(Int(duration.rounded())) : nil
            )
        ]
        return components?.url
    }

    private static func process(
        data: Data?,
        response: URLResponse?,
        error: Error?
    ) -> LookupResult {
        if let error {
            if (error as? URLError)?.code == .cancelled {
                return .failed("The lyrics request was cancelled.")
            }
            return .failed(error.localizedDescription)
        }

        guard let response = response as? HTTPURLResponse else {
            return .failed("The lyrics service returned an invalid response.")
        }
        if response.statusCode == 404 { return .unavailable }
        guard (200..<300).contains(response.statusCode) else {
            return .failed("The lyrics service returned HTTP \(response.statusCode).")
        }
        guard let data,
              let payload = try? JSONDecoder().decode(LyricsResponse.self, from: data) else {
            return .failed("The lyrics response could not be read.")
        }

        if let syncedLyrics = payload.syncedLyrics,
           let lines = parseSyncedLyrics(syncedLyrics), !lines.isEmpty {
            return .document(
                LyricsDocument(
                    lines: lines,
                    isSynced: true,
                    isInstrumental: payload.instrumental == true
                )
            )
        }

        if let plainLyrics = payload.plainLyrics {
            let lines = parsePlainLyrics(plainLyrics)
            if !lines.isEmpty {
                return .document(
                    LyricsDocument(
                        lines: lines,
                        isSynced: false,
                        isInstrumental: payload.instrumental == true
                    )
                )
            }
        }

        if payload.instrumental == true {
            return .document(
                LyricsDocument(
                    lines: [LyricsLine(id: 0, timestamp: nil, text: "Instrumental track")],
                    isSynced: false,
                    isInstrumental: true
                )
            )
        }
        return .unavailable
    }

    private static func parsePlainLyrics(_ lyrics: String) -> [LyricsLine] {
        let lines = lyrics
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.contains(where: { !$0.isEmpty }) else { return [] }
        return lines.enumerated().map { index, text in
            LyricsLine(id: index, timestamp: nil, text: text)
        }
    }

    private static func parseSyncedLyrics(_ lyrics: String) -> [LyricsLine]? {
        var parsed: [(timestamp: TimeInterval, text: String, order: Int)] = []

        for (order, rawLine) in lyrics.components(separatedBy: .newlines).enumerated() {
            var remainder = rawLine
            var timestamps: [TimeInterval] = []

            while remainder.first == "[",
                  let closingBracket = remainder.firstIndex(of: "]") {
                let tagStart = remainder.index(after: remainder.startIndex)
                let tag = String(remainder[tagStart..<closingBracket])
                if let timestamp = parseTimestamp(tag) {
                    timestamps.append(timestamp)
                }
                remainder = String(remainder[remainder.index(after: closingBracket)...])
            }

            guard !timestamps.isEmpty else { continue }
            let text = remainder.trimmingCharacters(in: .whitespaces)
            for timestamp in timestamps {
                parsed.append((timestamp: timestamp, text: text, order: order))
            }
        }

        guard parsed.contains(where: { !$0.text.isEmpty }) else { return nil }
        parsed.sort {
            if $0.timestamp == $1.timestamp { return $0.order < $1.order }
            return $0.timestamp < $1.timestamp
        }
        return parsed.enumerated().map { index, entry in
            LyricsLine(id: index, timestamp: entry.timestamp, text: entry.text)
        }
    }

    private static func parseTimestamp(_ value: String) -> TimeInterval? {
        let components = value.split(separator: ":", maxSplits: 1)
        guard components.count == 2,
              let minutes = Double(components[0]),
              let seconds = Double(components[1]),
              minutes >= 0, seconds >= 0 else { return nil }
        return minutes * 60 + seconds
    }
}
