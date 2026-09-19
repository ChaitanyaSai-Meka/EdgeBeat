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

private func normalizedLyricsDuration(_ value: TimeInterval) -> Int? {
    guard value.isFinite, value > 0 else { return nil }
    return Int(exactly: value.rounded())
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
        let duration: Int?

        init(title: String, artist: String, album: String, duration: TimeInterval) {
            self.title = Self.normalized(title)
            self.artist = Self.normalized(artist)
            self.album = Self.normalized(album)
            self.duration = normalizedLyricsDuration(duration)
        }

        private static func normalized(_ value: String) -> String {
            value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        }
    }

    private struct LyricsResponse: Decodable {
        let trackName: String?
        let artistName: String?
        let albumName: String?
        let duration: Double?
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

    private var userAgent: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "1.0"
        return "EdgeBeat/\(version) (macOS)"
    }

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

        let key = LookupKey(title: title, artist: artist, album: album,
                            duration: duration)
        guard !key.title.isEmpty else {
            task?.cancel()
            task = nil
            currentKey = nil
            state = .failed("The current player did not provide a track title.")
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
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        state = .loading

        task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            let result = Self.process(data: data, response: response, error: error)
            if case .unavailable = result {
                self.beginSearch(
                    title: title,
                    artist: artist,
                    album: album,
                    duration: duration,
                    key: key,
                    generation: generation
                )
            } else {
                self.finish(result, key: key, generation: generation)
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
        var queryItems: [(name: String, value: String)] = [
            ("track_name", title)
        ]
        if !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryItems.append(("artist_name", artist))
        }
        if !album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryItems.append(("album_name", album))
        }
        if let durationValue = normalizedLyricsDuration(duration) {
            queryItems.append(("duration", String(durationValue)))
        }
        components?.percentEncodedQuery = queryItems.map { name, value in
            let encodedName = Self.percentEncodeQueryComponent(name)
            return encodedName + "=" + Self.percentEncodeQueryComponent(value)
        }.joined(separator: "&")
        return components?.url
    }

    private func makeSearchURL(title: String, artist: String, album: String) -> URL? {
        let query = [title, artist, album]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !query.isEmpty else { return nil }
        var components = URLComponents(string: "https://lrclib.net/api/search")
        components?.percentEncodedQuery = "q=" + Self.percentEncodeQueryComponent(query)
        return components?.url
    }

    private static let queryComponentAllowedCharacters: CharacterSet = {
        CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
    }()

    private static func percentEncodeQueryComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: queryComponentAllowedCharacters)
            ?? value
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

        return document(from: payload)
    }

    private static func processSearch(
        data: Data?,
        response: URLResponse?,
        error: Error?,
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval
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
        guard (200..<300).contains(response.statusCode) else {
            return .failed("The lyrics service returned HTTP \(response.statusCode).")
        }
        guard let data,
              let payload = try? JSONDecoder().decode([LyricsResponse].self, from: data) else {
            return .failed("The lyrics response could not be read.")
        }

        let ranked = payload.sorted {
            score($0, title: title, artist: artist, album: album, duration: duration)
                > score($1, title: title, artist: artist, album: album, duration: duration)
        }
        for candidate in ranked {
            if case let .document(document) = document(from: candidate) {
                return .document(document)
            }
        }
        return .unavailable
    }

    private static func document(from payload: LyricsResponse) -> LookupResult {

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

    private static func score(
        _ candidate: LyricsResponse,
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval
    ) -> Int {
        let normalizedTitle = normalize(title)
        let normalizedArtist = normalize(artist)
        let normalizedAlbum = normalize(album)
        let candidateTitle = normalize(candidate.trackName ?? "")
        let candidateArtist = normalize(candidate.artistName ?? "")
        let candidateAlbum = normalize(candidate.albumName ?? "")
        var score = 0

        if candidateTitle == normalizedTitle { score += 70 }
        else if candidateTitle.contains(normalizedTitle) || normalizedTitle.contains(candidateTitle) { score += 35 }
        if !normalizedArtist.isEmpty, candidateArtist == normalizedArtist { score += 30 }
        else if !normalizedArtist.isEmpty, candidateArtist.contains(normalizedArtist) { score += 15 }
        if !normalizedAlbum.isEmpty, candidateAlbum == normalizedAlbum { score += 15 }

        if let candidateDuration = candidate.duration,
           duration.isFinite, duration > 0 {
            let difference = abs(candidateDuration - duration)
            score += max(0, 20 - Int(difference.rounded()))
        }
        if candidate.syncedLyrics != nil { score += 5 }
        if candidate.plainLyrics != nil { score += 2 }
        return score
    }

    private static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func beginSearch(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval,
        key: LookupKey,
        generation: Int
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.requestGeneration == generation,
                  self.currentKey == key else { return }
            guard let url = self.makeSearchURL(title: title, artist: artist, album: album) else {
                self.finish(.unavailable, key: key, generation: generation)
                return
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(self.userAgent, forHTTPHeaderField: "User-Agent")
            self.state = .loading
            self.task = self.session.dataTask(with: request) { [weak self] data, response, error in
                let result = Self.processSearch(
                    data: data,
                    response: response,
                    error: error,
                    title: title,
                    artist: artist,
                    album: album,
                    duration: duration
                )
                self?.finish(result, key: key, generation: generation)
            }
            self.task?.resume()
        }
    }

    private func finish(_ result: LookupResult, key: LookupKey, generation: Int) {
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
        var offset: TimeInterval = 0

        for (order, rawLine) in lyrics.components(separatedBy: .newlines).enumerated() {
            var remainder = rawLine
                .replacingOccurrences(of: "\u{FEFF}", with: "")
            var timestamps: [TimeInterval] = []

            while remainder.first == "[",
                  let closingBracket = remainder.firstIndex(of: "]") {
                let tagStart = remainder.index(after: remainder.startIndex)
                let tag = String(remainder[tagStart..<closingBracket])
                let normalizedTag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                if normalizedTag.lowercased().hasPrefix("offset:") {
                    let value = normalizedTag.dropFirst("offset:".count)
                    if let milliseconds = Double(value), milliseconds.isFinite {
                        offset = milliseconds / 1_000
                    }
                } else if let timestamp = parseTimestamp(normalizedTag) {
                    timestamps.append(max(0, timestamp + offset))
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
        let components = value.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 2 || components.count == 3 else { return nil }
        let values = components.compactMap { Double($0) }
        guard values.count == components.count,
              values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }

        if values.count == 2 {
            return values[0] * 60 + values[1]
        }
        return values[0] * 3_600 + values[1] * 60 + values[2]
    }
}
