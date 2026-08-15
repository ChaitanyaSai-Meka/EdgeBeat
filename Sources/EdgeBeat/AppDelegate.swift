import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?
    private let renderState = RenderState()
    private lazy var overlay = OverlayController(renderState: renderState)
    private let nowPlaying = NowPlayingMonitor()
    private let audioTap = AudioTapEngine()
    private let beatAnalyzer: BeatAnalyzer? = BeatAnalyzer()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menuBar = MenuBarController()
        menuBar.onToggle = { [weak self] enabled in
            if enabled { self?.overlay.show() } else { self?.overlay.hide() }
        }
        menuBar.onQuit = {
            NSApp.terminate(nil)
        }
        menuBar.onIntensityChange = { [weak self] value in
            self?.overlay.setIntensity(value)
        }
        menuBar.onSourceChange = { [weak self] source in
            self?.nowPlaying.setSource(source)
        }
        menuBar.onOpenPermissions = {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
            NSWorkspace.shared.open(url)
        }
        self.menuBar = menuBar

        nowPlaying.onTrackChange = { [weak self] track in
            guard let self else { return }
            self.renderState.update(track: track)
            self.menuBar?.setNowPlaying(track)
            if track.state == .playing {
                self.audioTap.start(processID: track.processID)
            } else {
                self.audioTap.stop()
                self.renderState.update(audio: .silence)
            }
        }
        beatAnalyzer?.onFeatures = { [weak self] features in
            self?.renderState.update(audio: features)
        }
        audioTap.onSamples = { [weak self] samples, sampleRate in
            self?.beatAnalyzer?.consume(samples: samples, sampleRate: sampleRate)
        }
        audioTap.onStatusChange = { [weak self] message in
            DispatchQueue.main.async { self?.menuBar?.setCaptureStatus(message) }
        }

        overlay.show()
        nowPlaying.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        nowPlaying.stop()
        audioTap.stop()
    }
}
