import Combine
import Foundation
import XCTest
@testable import EdgeBeat

final class LyricsServiceTests: XCTestCase {
    func testLyricsCacheSeparatesDurationsUsedByLRCLIB() {
        LyricsURLProtocol.reset()
        defer { LyricsURLProtocol.reset() }

        LyricsURLProtocol.response = { request in
            let duration = URLComponents(
                url: request.url!,
                resolvingAgainstBaseURL: false
            )?.queryItems?.first(where: { $0.name == "duration" })?.value
            let text = duration == "180" ? "Short recording" : "Long recording"
            return Data("{\"plainLyrics\":\"\(text)\"}".utf8)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LyricsURLProtocol.self]
        let store = LyricsStore(session: URLSession(configuration: configuration))

        store.load(
            title: "Song",
            artist: "Artist",
            album: "Album",
            duration: 180.2
        )
        waitForLoadedState(store)
        XCTAssertEqual(store.documentText, "Short recording")

        store.load(
            title: "Song",
            artist: "Artist",
            album: "Album",
            duration: 240.2
        )
        waitForLoadedState(store)
        XCTAssertEqual(store.documentText, "Long recording")
        XCTAssertEqual(LyricsURLProtocol.requestedDurations, ["180", "240"])
    }

    func testEquivalentRoundedDurationsReuseLyricsCache() {
        LyricsURLProtocol.reset()
        defer { LyricsURLProtocol.reset() }

        LyricsURLProtocol.response = { _ in
            Data(#"{"plainLyrics":"Cached lyrics"}"#.utf8)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LyricsURLProtocol.self]
        let store = LyricsStore(session: URLSession(configuration: configuration))

        store.load(
            title: "Song",
            artist: "Artist",
            album: "Album",
            duration: 180.2
        )
        waitForLoadedState(store)

        store.reset()
        store.load(
            title: "Song",
            artist: "Artist",
            album: "Album",
            duration: 180.4
        )
        XCTAssertEqual(store.documentText, "Cached lyrics")
        XCTAssertEqual(LyricsURLProtocol.requestedDurations, ["180"])
    }

    private func waitForLoadedState(_ store: LyricsStore) {
        if case .loaded = store.state { return }

        let expectation = expectation(description: "Lyrics loaded")
        let cancellable = store.$state.sink { state in
            if case .loaded = state {
                expectation.fulfill()
            }
        }
        wait(for: [expectation], timeout: 2)
        withExtendedLifetime(cancellable) {}
    }
}

private extension LyricsStore {
    var documentText: String? {
        guard case let .loaded(document) = state else { return nil }
        return document.text
    }
}

private final class LyricsURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var requests: [URLRequest] = []
    static var response: ((URLRequest) -> Data)?

    static var requestedDurations: [String?] {
        lock.lock()
        defer { lock.unlock() }
        return requests.map { request in
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "duration" })?
                .value
        }
    }

    static func reset() {
        lock.lock()
        requests.removeAll()
        response = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "lrclib.net"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let payload = Self.response?(request)
            ?? Data(#"{"plainLyrics":"Lyrics"}"#.utf8)
        Self.lock.unlock()

        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: nil,
                  headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
