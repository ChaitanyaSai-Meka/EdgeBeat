import AppKit
import Darwin
import Foundation
import OSLog

/// Permission-free bridge used by BoringNotch/mediaremote-adapter for macOS
/// versions where direct MediaRemote access is entitlement-gated.
final class MediaRemoteAdapter {
    private struct Payload: Decodable {
        let bundleIdentifier: String?
        let parentApplicationBundleIdentifier: String?
        let processIdentifier: Int32?
        let playing: Bool?
        let title: String?
        let artist: String?
        let album: String?
        let duration: Double?
        let elapsedTimeNow: Double?
        let elapsedTime: Double?
        let shuffleMode: Int?
        let timestamp: String?
        let artworkData: String?
        let uniqueIdentifier: String?
        let contentItemIdentifier: String?
    }

    private let logger = Logger(subsystem: "com.chaitanya.edgebeat", category: "media-remote")
    private let processTimeout: TimeInterval
    private let scriptURL: URL?
    private let frameworkURL: URL?

    init(bundle: Bundle = .main) {
        scriptURL = bundle.url(forResource: "mediaremote-adapter", withExtension: "pl")
        frameworkURL = bundle.url(forResource: "MediaRemoteAdapter", withExtension: "framework")
        processTimeout = 3
    }

    init(scriptURL: URL?, frameworkURL: URL?, processTimeout: TimeInterval) {
        self.scriptURL = scriptURL
        self.frameworkURL = frameworkURL
        self.processTimeout = max(0.05, processTimeout)
    }

    var isAvailable: Bool {
        scriptURL != nil && frameworkURL != nil
    }

    func readTrack(preferredSource: PlayerSource) -> NowPlayingTrack? {
        guard let payload: Payload = run(arguments: ["get", "--now"]) else { return nil }
        guard let title = payload.title, !title.isEmpty else { return nil }

        let bundleID = payload.parentApplicationBundleIdentifier ?? payload.bundleIdentifier ?? ""
        let source: PlayerSource
        switch bundleID {
        case "com.spotify.client": source = .spotify
        case "com.apple.Music": source = .music
        default: return nil
        }
        guard preferredSource == .automatic || preferredSource == source else { return nil }

        let artworkData = payload.artworkData.flatMap { Data(base64Encoded: $0) }
        let artwork = artworkData.flatMap(NSImage.init(data:))
        let identifier = payload.uniqueIdentifier
            ?? payload.contentItemIdentifier
            ?? "\(source.rawValue)|\(title)|\(payload.artist ?? "")|\(payload.album ?? "")"
        let processID = payload.processIdentifier
            ?? NSRunningApplication.runningApplications(
                withBundleIdentifier: source == .spotify ? "com.spotify.client" : "com.apple.Music"
            ).first?.processIdentifier

        let position = payload.elapsedTimeNow ?? estimatedElapsedTime(from: payload)
        return NowPlayingTrack(
            source: source,
            title: title,
            artist: payload.artist ?? "",
            album: payload.album ?? "",
            artwork: artwork,
            artworkRevision: artworkData.map(ArtworkRevision.data) ?? "",
            identifier: identifier,
            state: payload.playing == true ? .playing : .paused,
            processID: processID,
            duration: payload.duration ?? 0,
            position: position,
            isShuffleEnabled: (payload.shuffleMode ?? 0) != 0
        )
    }

    func send(_ command: PlaybackCommand) -> Bool {
        let commandID: String
        switch command {
        case .togglePlayPause: commandID = "2"
        case .nextTrack: commandID = "4"
        case .previousTrack: commandID = "5"
        case .toggleShuffle: return false
        }
        return runVoid(arguments: ["send", commandID])
    }

    func setPlayback(playing: Bool) -> Bool {
        // MediaRemote exposes idempotent play/pause commands (0/1). Using
        // those instead of toggle (2) prevents a delayed poll from reversing
        // a user's most recent action.
        runVoid(arguments: ["send", playing ? "0" : "1"])
    }

    func setShuffle(enabled: Bool) -> Bool {
        runVoid(arguments: ["shuffle", enabled ? "1" : "0"])
    }

    func seek(to position: TimeInterval) -> Bool {
        let microseconds = Int64((max(0, position) * 1_000_000).rounded())
        return runVoid(arguments: ["seek", String(microseconds)])
    }

    private func estimatedElapsedTime(from payload: Payload) -> TimeInterval {
        guard let elapsed = payload.elapsedTime else { return 0 }
        guard payload.playing == true,
              let timestamp = payload.timestamp,
              let date = ISO8601DateFormatter().date(from: timestamp) else { return elapsed }
        return max(0, elapsed + Date().timeIntervalSince(date))
    }

    private func runVoid(arguments: [String]) -> Bool {
        guard let scriptURL, let frameworkURL else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptURL.path, frameworkURL.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let termination = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in termination.signal() }
        do {
            try process.run()
            guard waitForExit(process, signal: termination) else { return false }
        } catch {
            logger.error("MediaRemote command could not start: \(error.localizedDescription, privacy: .public)")
            return false
        }
        return process.terminationStatus == 0
    }

    private func run<T: Decodable>(arguments: [String]) -> T? {
        guard let scriptURL, let frameworkURL else { return nil }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptURL.path, frameworkURL.path] + arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let termination = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in termination.signal() }
        let outputGroup = DispatchGroup()
        var outputData = Data()
        let outputLock = NSLock()
        do {
            try process.run()
            outputGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                let data = output.fileHandleForReading.readDataToEndOfFile()
                outputLock.lock()
                outputData = data
                outputLock.unlock()
                outputGroup.leave()
            }
            guard waitForExit(process, signal: termination) else { return nil }
            _ = outputGroup.wait(timeout: .now() + 0.5)
            outputLock.lock()
            let data = outputData
            outputLock.unlock()
            guard process.terminationStatus == 0 else { return nil }
            return try? JSONDecoder().decode(T.self, from: data)
        } catch {
            logger.error("MediaRemote query could not start: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func waitForExit(_ process: Process,
                             signal: DispatchSemaphore) -> Bool {
        guard signal.wait(timeout: .now() + processTimeout) == .timedOut else {
            return process.terminationStatus == 0
        }

        logger.error("MediaRemote helper timed out")
        if process.isRunning { process.terminate() }
        if signal.wait(timeout: .now() + 0.25) == .timedOut,
           process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            _ = signal.wait(timeout: .now() + 0.5)
        }
        return false
    }
}
