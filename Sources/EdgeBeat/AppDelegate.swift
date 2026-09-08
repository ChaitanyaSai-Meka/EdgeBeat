import AppKit
import Combine
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private struct AudioCaptureTarget: Equatable {
        let source: PlayerSource
        let processID: pid_t?
        let trackIdentifier: String
    }

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
    private let audioOutputMonitor = AudioOutputMonitor()
    private let beatAnalyzer: BeatAnalyzer? = BeatAnalyzer()
    private let updateChecker = GitHubUpdateChecker()
    private let displaySleepController = DisplaySleepController()
    private lazy var companionWindow = CompanionWindowController(
        renderState: renderState,
        onPlaybackCommand: { [weak self] command, source in
            self?.nowPlaying.perform(command, for: source)
        },
        onSeek: { [weak self] position, source in
            self?.nowPlaying.seek(to: position, for: source)
        }
    )
    private var menuBar: MenuBarController?
    private var currentTrack = NowPlayingTrack.empty
    private var isAudioCaptureRequested = false
    private var requestedAudioProcessID: pid_t?
    private var audioCaptureRetryWork: DispatchWorkItem?
    private var audioCaptureRetryAttempt = 0
    private var audioCaptureRetryTarget: AudioCaptureTarget?
    private var audioCaptureRetryToken: UInt64 = 0
    private var audioSessionGeneration = GenerationCounter()
    private var areDisplaysAsleep = false
    private var isCompanionVisible = false
    private var isTerminating = false
    private var cancellables: Set<AnyCancellable> = []

    // Bound retries so a persistent Core Audio failure does not relaunch the
    // helper indefinitely while still recovering from transient failures.
    private static let maximumAudioCaptureAttempts = 3

    private var currentAudioCaptureTarget: AudioCaptureTarget {
        AudioCaptureTarget(
            source: currentTrack.source,
            processID: currentTrack.processID,
            trackIdentifier: currentTrack.identifier
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureApplicationMenu()
        configureMenuBar()
        configurePlaybackPipeline()
        nowPlaying.setSource(preferences.playerSource)
        renderState.setWaveFlowDirection(preferences.waveFlowDirection)
        observePreferences()
        applyPowerPolicy()

        nowPlaying.start()
        audioOutputMonitor.start()
    }

    private func configureApplicationMenu() {
        let mainMenu = NSMenu()

        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "EdgeBeat")
        applicationMenu.addItem(
            NSMenuItem(
                title: "About EdgeBeat",
                action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                keyEquivalent: ""
            )
        )
        applicationMenu.addItem(.separator())

        let hideItem = NSMenuItem(
            title: "Hide EdgeBeat",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        hideItem.keyEquivalentModifierMask = [.command]
        applicationMenu.addItem(hideItem)
        applicationMenu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit EdgeBeat",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = [.command]
        applicationMenu.addItem(quitItem)
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        let minimizeItem = NSMenuItem(
            title: "Minimize",
            action: #selector(NSWindow.miniaturize(_:)),
            keyEquivalent: "m"
        )
        minimizeItem.keyEquivalentModifierMask = [.command]
        windowMenu.addItem(minimizeItem)
        let zoomItem = NSMenuItem(
            title: "Zoom",
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        )
        windowMenu.addItem(zoomItem)
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        audioCaptureRetryWork?.cancel()
        audioCaptureRetryWork = nil
        audioCaptureRetryToken &+= 1
        nowPlaying.stop()
        audioOutputMonitor.stop()
        invalidateAudioSession()
        audioTap.stop()
        renderState.setWaveFlowAnimationActive(false)
        displaySleepController.setPrevented(false)
        companionWindow.hide()
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
        menuBar.onToggleCompanion = { [weak self] in
            self?.companionWindow.toggle()
        }
        companionWindow.onVisibilityChange = { [weak self] visible in
            guard let self else { return }
            isCompanionVisible = visible
            menuBar.setCompanionVisible(visible)
            guard !isTerminating else { return }
            syncAudioCapture()
            syncDisplaySleepPrevention()
        }
        menuBar.setLaunchAtLogin(Self.isLaunchAtLoginRequested(SMAppService.mainApp.status))
        menuBar.setCompanionVisible(companionWindow.isVisible)
        self.menuBar = menuBar
    }

    private func configurePlaybackPipeline() {
        audioOutputMonitor.onRouteChange = { [weak self] route in
            self?.renderState.update(audioOutputRoute: route)
        }
        nowPlaying.onPlaybackUpdate = { [weak self] track in
            guard let self else { return }
            currentTrack = track
            renderState.update(track: track)
            overlay.refreshLockScreenCard()
            menuBar?.setNowPlaying(track)
            syncAudioCapture()
            syncWaveFlowAnimation()
            syncDisplaySleepPrevention()
        }
        beatAnalyzer?.onFeatures = { [weak self] features, session in
            guard let self,
                  audioSessionGeneration.matches(session),
                  preferences.enabled || isCompanionVisible else { return }
            renderState.update(audio: features)
        }
        audioTap.onSamples = { [weak self] samples, sampleRate, session in
            self?.beatAnalyzer?.consume(
                samples: samples,
                sampleRate: sampleRate,
                session: session
            )
        }
        audioTap.onStatusChange = { [weak self] message in
            DispatchQueue.main.async { self?.menuBar?.setCaptureStatus(message) }
        }
        audioTap.onStartResult = { [weak self] session, started in
            DispatchQueue.main.async {
                self?.handleAudioCaptureResult(session: session, started: started)
            }
        }
    }

    private func observePreferences() {
        preferences.$enabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled { overlay.show() } else { overlay.hide() }
                syncAudioCapture()
                syncWaveFlowAnimation()
                syncDisplaySleepPrevention()
            }
            .store(in: &cancellables)

        preferences.$waveFlowEnabled
            .removeDuplicates()
            .sink { [weak self] _ in self?.syncWaveFlowAnimation() }
            .store(in: &cancellables)

        preferences.$waveSpeed
            .removeDuplicates()
            .sink { [weak self] speed in self?.renderState.setWaveFlowSpeed(speed) }
            .store(in: &cancellables)

        preferences.$waveFlowDirection
            .removeDuplicates()
            .sink { [weak self] direction in self?.renderState.setWaveFlowDirection(direction) }
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
            .receive(on: DispatchQueue.main)
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
        let shouldCapture = (preferences.enabled || isCompanionVisible)
            && currentTrack.state == .playing
            && !areDisplaysAsleep

        if shouldCapture {
            let target = currentAudioCaptureTarget
            if audioCaptureRetryTarget != target {
                audioCaptureRetryWork?.cancel()
                audioCaptureRetryWork = nil
                audioCaptureRetryToken &+= 1
                audioCaptureRetryAttempt = 0
                audioCaptureRetryTarget = target
            }
            guard !isAudioCaptureRequested
                    || requestedAudioProcessID != currentTrack.processID else { return }
            guard audioCaptureRetryAttempt < Self.maximumAudioCaptureAttempts else { return }
            if isAudioCaptureRequested {
                renderState.resetAudio()
            }
            isAudioCaptureRequested = true
            requestedAudioProcessID = currentTrack.processID
            let session = audioSessionGeneration.next()
            beatAnalyzer?.beginSession(session)
            audioTap.start(processID: currentTrack.processID, session: session)
        } else {
            audioCaptureRetryWork?.cancel()
            audioCaptureRetryWork = nil
            audioCaptureRetryToken &+= 1
            audioCaptureRetryAttempt = 0
            audioCaptureRetryTarget = nil
            guard isAudioCaptureRequested else { return }
            isAudioCaptureRequested = false
            requestedAudioProcessID = nil
            invalidateAudioSession()
            audioTap.stop()
            renderState.resetAudio()
            menuBar?.setCaptureStatus(nil)
        }
    }

    private func handleAudioCaptureResult(session: UInt64, started: Bool) {
        guard audioSessionGeneration.matches(session) else { return }

        if started {
            audioCaptureRetryWork?.cancel()
            audioCaptureRetryWork = nil
            audioCaptureRetryToken &+= 1
            audioCaptureRetryAttempt = 0
            return
        }

        guard !isTerminating,
              isAudioCaptureRequested,
              currentTrack.state == .playing,
              !areDisplaysAsleep,
              audioCaptureRetryTarget == currentAudioCaptureTarget else { return }

        isAudioCaptureRequested = false
        requestedAudioProcessID = nil
        invalidateAudioSession()
        renderState.resetAudio()
        scheduleAudioCaptureRetry()
    }

    private func scheduleAudioCaptureRetry() {
        guard audioCaptureRetryAttempt < Self.maximumAudioCaptureAttempts else { return }
        audioCaptureRetryAttempt += 1
        let delay = min(8.0, pow(2.0, Double(audioCaptureRetryAttempt - 1)))
        audioCaptureRetryToken &+= 1
        let token = audioCaptureRetryToken
        let retry = DispatchWorkItem { [weak self] in
            guard let self,
                  !self.isTerminating,
                  self.audioCaptureRetryToken == token else { return }
            self.audioCaptureRetryWork = nil
            self.syncAudioCapture()
        }
        audioCaptureRetryWork?.cancel()
        audioCaptureRetryWork = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: retry)
    }

    private func invalidateAudioSession() {
        let endingSession = audioSessionGeneration.current
        audioSessionGeneration.invalidate()
        beatAnalyzer?.endSession(endingSession)
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
        syncWaveFlowAnimation()
        syncDisplaySleepPrevention()
    }

    private func syncWaveFlowAnimation() {
        let shouldAnimate = preferences.enabled
            && preferences.waveFlowEnabled
            && currentTrack.state == .playing
            && !areDisplaysAsleep
        renderState.setWaveFlowAnimationActive(shouldAnimate)
    }

    private func syncDisplaySleepPrevention() {
        let lockScreenPlayback = preferences.enabled
            && preferences.nowPlayingCardEnabled
            && preferences.isScreenLocked
        let shouldPrevent = (lockScreenPlayback || isCompanionVisible)
            && currentTrack.state == .playing
            && !areDisplaysAsleep
        displaySleepController.setPrevented(shouldPrevent)
    }

    private func setLaunchAtLogin(_ enabled: Bool) -> Bool {
        let service = SMAppService.mainApp
        let currentStatus = service.status
        let alreadyInDesiredState = enabled
            ? currentStatus == .enabled || currentStatus == .requiresApproval
            : currentStatus == .notRegistered

        // SMAppService reports an error when asked to repeat an operation that
        // has already been performed (for example, after the user changed the
        // setting in System Settings). Treat that state as a no-op instead of
        // surfacing a spurious warning.
        if alreadyInDesiredState {
            let actualEnabled = Self.isLaunchAtLoginRequested(service.status)
            menuBar?.setLaunchAtLogin(actualEnabled)
            return actualEnabled
        }

        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            // Re-read after a failed operation. Another actor may have
            // changed the registration between the initial status check and
            // the call, in which case the requested state is already true.
            let actualStatus = service.status
            let reachedRequestedState = enabled
                ? actualStatus == .enabled || actualStatus == .requiresApproval
                : actualStatus == .notRegistered
            if !reachedRequestedState {
                let alert = NSAlert()
                alert.messageText = "Unable to update Launch at Login"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
        let actualEnabled = Self.isLaunchAtLoginRequested(service.status)
        menuBar?.setLaunchAtLogin(actualEnabled)
        return actualEnabled
    }

    private static func isLaunchAtLoginRequested(_ status: SMAppService.Status) -> Bool {
        status == .enabled || status == .requiresApproval
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
