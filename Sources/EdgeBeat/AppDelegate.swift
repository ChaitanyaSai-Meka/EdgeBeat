import AppKit
import Combine
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = AppPreferences()
    private let renderState = RenderState()
    private lazy var overlay = OverlayController(
        preferences: preferences,
        renderState: renderState,
        onPlaybackCommand: { [weak self] command, source in
            self?.nowPlaying.perform(command, for: source)
        }
    )
    private let nowPlaying = NowPlayingMonitor()
    private let audioTap = AudioTapEngine()
    private let beatAnalyzer: BeatAnalyzer? = BeatAnalyzer()
    private var menuBar: MenuBarController?
    private var currentTrack = NowPlayingTrack.empty
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenuBar()
        configurePlaybackPipeline()
        observePreferences()

        if preferences.enabled { overlay.show() }
        nowPlaying.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        nowPlaying.stop()
        audioTap.stop()
    }

    private func configureMenuBar() {
        let menuBar = MenuBarController(preferences: preferences)
        menuBar.onQuit = { NSApp.terminate(nil) }
        menuBar.onSourceChange = { [weak self] source in
            self?.nowPlaying.setSource(source)
        }
        menuBar.onOpenPermissions = {
            guard let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
            ) else { return }
            NSWorkspace.shared.open(url)
        }
        menuBar.onLaunchAtLoginChange = { [weak self] enabled in
            self?.setLaunchAtLogin(enabled) ?? false
        }
        menuBar.setLaunchAtLogin(SMAppService.mainApp.status == .enabled)
        self.menuBar = menuBar
    }

    private func configurePlaybackPipeline() {
        nowPlaying.onPlaybackUpdate = { [weak self] track in
            guard let self else { return }
            currentTrack = track
            renderState.update(track: track)
            overlay.refreshLockScreenCard()
            menuBar?.setNowPlaying(track)
            syncAudioCapture()
        }
        beatAnalyzer?.onFeatures = { [weak self] features in
            guard let self,
                  preferences.enabled,
                  preferences.animationMode == .musicSync else { return }
            renderState.update(audio: features)
        }
        audioTap.onSamples = { [weak self] samples, sampleRate in
            self?.beatAnalyzer?.consume(samples: samples, sampleRate: sampleRate)
        }
        audioTap.onStatusChange = { [weak self] message in
            DispatchQueue.main.async { self?.menuBar?.setCaptureStatus(message) }
        }
    }

    private func observePreferences() {
        preferences.$enabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled { overlay.show() } else { overlay.hide() }
                syncAudioCapture()
            }
            .store(in: &cancellables)

        preferences.$animationMode
            .removeDuplicates()
            .sink { [weak self] _ in self?.syncAudioCapture() }
            .store(in: &cancellables)

        preferences.$displayTarget
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.overlay.refreshDisplays() }
            .store(in: &cancellables)

        preferences.$nowPlayingCardEnabled
            .removeDuplicates()
            .sink { [weak self] _ in self?.overlay.refreshLockScreenCard() }
            .store(in: &cancellables)
    }

    private func syncAudioCapture() {
        let shouldCapture = preferences.enabled
            && preferences.animationMode == .musicSync
            && currentTrack.state == .playing

        if shouldCapture {
            audioTap.start(processID: currentTrack.processID)
        } else {
            audioTap.stop()
            renderState.update(audio: .silence)
            menuBar?.setCaptureStatus(nil)
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Unable to update Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
        return SMAppService.mainApp.status == .enabled
    }
}
