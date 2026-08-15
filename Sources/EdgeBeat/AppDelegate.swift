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
    private let updateChecker = GitHubUpdateChecker()
    private let displaySleepController = DisplaySleepController()
    private var menuBar: MenuBarController?
    private var currentTrack = NowPlayingTrack.empty
    private var isAudioCaptureRequested = false
    private var requestedAudioProcessID: pid_t?
    private var areDisplaysAsleep = false
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenuBar()
        configurePlaybackPipeline()
        nowPlaying.setSource(preferences.playerSource)
        observePreferences()
        applyPowerPolicy()

        nowPlaying.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        nowPlaying.stop()
        audioTap.stop()
        displaySleepController.setPrevented(false)
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
        menuBar.onCheckForUpdates = { [weak self] in
            self?.checkForUpdates()
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
            syncDisplaySleepPrevention()
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
                syncDisplaySleepPrevention()
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
            .sink { [weak self] _ in
                self?.overlay.refreshLockScreenCard()
                self?.syncDisplaySleepPrevention()
            }
            .store(in: &cancellables)

        preferences.$isScreenLocked
            .removeDuplicates()
            .sink { [weak self] _ in self?.syncDisplaySleepPrevention() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
            .sink { [weak self] _ in self?.applyPowerPolicy() }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidSleepNotification)
            .sink { [weak self] _ in self?.setDisplaysAsleep(true) }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidWakeNotification)
            .sink { [weak self] _ in self?.setDisplaysAsleep(false) }
            .store(in: &cancellables)
    }

    private func syncAudioCapture() {
        let shouldCapture = preferences.enabled
            && preferences.animationMode == .musicSync
            && currentTrack.state == .playing
            && !areDisplaysAsleep

        if shouldCapture {
            guard !isAudioCaptureRequested
                    || requestedAudioProcessID != currentTrack.processID else { return }
            isAudioCaptureRequested = true
            requestedAudioProcessID = currentTrack.processID
            audioTap.start(processID: currentTrack.processID)
        } else {
            guard isAudioCaptureRequested else { return }
            isAudioCaptureRequested = false
            requestedAudioProcessID = nil
            audioTap.stop()
            renderState.update(audio: .silence)
            menuBar?.setCaptureStatus(nil)
        }
    }

    private func applyPowerPolicy() {
        let isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        renderState.setLowPowerMode(isLowPowerModeEnabled)
        beatAnalyzer?.setLowPowerMode(isLowPowerModeEnabled)
        nowPlaying.setLowPowerMode(isLowPowerModeEnabled)
    }

    private func setDisplaysAsleep(_ asleep: Bool) {
        guard areDisplaysAsleep != asleep else { return }
        areDisplaysAsleep = asleep
        if asleep {
            nowPlaying.stop()
            overlay.hide()
        } else {
            nowPlaying.start()
            if preferences.enabled {
                overlay.show()
            }
        }
        syncAudioCapture()
        syncDisplaySleepPrevention()
    }

    private func syncDisplaySleepPrevention() {
        let shouldPrevent = preferences.enabled
            && preferences.nowPlayingCardEnabled
            && preferences.isScreenLocked
            && currentTrack.state == .playing
            && !areDisplaysAsleep
        displaySleepController.setPrevented(shouldPrevent)
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

    private func checkForUpdates() {
        menuBar?.setCheckingForUpdates(true)
        updateChecker.check { [weak self] result in
            guard let self else { return }
            menuBar?.setCheckingForUpdates(false)

            let alert = NSAlert()
            switch result {
            case let .updateAvailable(currentVersion, release):
                alert.messageText = "EdgeBeat \(release.version) is available"
                alert.informativeText = "You are currently using EdgeBeat \(currentVersion)."
                alert.addButton(withTitle: "View Release")
                alert.addButton(withTitle: "Not Now")
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(release.pageURL)
                }
            case let .upToDate(currentVersion):
                alert.messageText = "EdgeBeat is up to date"
                alert.informativeText = "Version \(currentVersion) is the latest available release."
                alert.runModal()
            case let .failed(message):
                alert.messageText = "Unable to check for updates"
                alert.informativeText = message
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }
}
