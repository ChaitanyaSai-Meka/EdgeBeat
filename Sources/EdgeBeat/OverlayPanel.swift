import AppKit
import CoreGraphics
import SwiftUI

private final class GlowHostingView: NSHostingView<EdgeGlowView> {
    override var safeAreaInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }
}

final class OverlayPanel: NSPanel {
    private let preferences: AppPreferences
    private let renderState: RenderState
    private var glowHost: GlowHostingView?
    private var displayNotch: DisplayNotch?

    init(screen: NSScreen, preferences: AppPreferences, renderState: RenderState) {
        self.preferences = preferences
        self.renderState = renderState
        displayNotch = DisplayNotch(screen: screen)
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        canBecomeVisibleWithoutLogin = true
        isReleasedWhenClosed = false
        level = Self.topmostLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isFloatingPanel = true
        isMovableByWindowBackground = false
        hidesOnDeactivate = false

        let view = EdgeGlowView(preferences: preferences, renderState: renderState,
                                notch: displayNotch)
        let host = GlowHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: screen.frame.size)
        host.autoresizingMask = [.width, .height]
        contentView = host
        glowHost = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func updateDisplay(_ screen: NSScreen) {
        if frame != screen.frame {
            setFrame(screen.frame, display: true)
        }
        let updatedNotch = DisplayNotch(screen: screen)
        guard displayNotch != updatedNotch else { return }
        displayNotch = updatedNotch
        glowHost?.rootView = EdgeGlowView(
            preferences: preferences,
            renderState: renderState,
            notch: updatedNotch
        )
    }

    func enableLockScreenVisibility() {
        SkyLightLockBridge.shared?.delegate(self)
    }

    func disableLockScreenVisibility() {
        SkyLightLockBridge.shared?.undelegate(self)
    }

    static var topmostLevel: NSWindow.Level {
        NSWindow.Level(rawValue: Int(Int32.max - 2))
    }
}

private final class LockScreenCardPanel: NSPanel {
    private static let panelHeight: CGFloat = 166
    private static let maximumWidth: CGFloat = 500

    init(screen: NSScreen, renderState: RenderState,
         onPlaybackCommand: @escaping (PlaybackCommand, PlayerSource) -> Void) {
        let frame = Self.cardFrame(on: screen)
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        canBecomeVisibleWithoutLogin = true
        isReleasedWhenClosed = false
        level = OverlayPanel.topmostLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isFloatingPanel = true
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        appearance = NSAppearance(named: .darkAqua)

        let view = LockScreenNowPlayingView(
            renderState: renderState,
            onPlaybackCommand: onPlaybackCommand
        )
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func reposition(on screen: NSScreen) {
        setFrame(Self.cardFrame(on: screen), display: true)
    }

    func enableLockScreenVisibility() {
        SkyLightLockBridge.shared?.delegate(self)
    }

    func disableLockScreenVisibility() {
        SkyLightLockBridge.shared?.undelegate(self)
    }

    private static func cardFrame(on screen: NSScreen) -> NSRect {
        let width = min(maximumWidth, screen.frame.width - 40)
        let x = screen.frame.midX - width / 2
        // macOS places authentication around the vertical center. Keeping the
        // card's bottom at 57% places it above the profile without crowding the clock.
        let y = screen.frame.minY + screen.frame.height * 0.55
        return NSRect(x: x, y: y, width: width, height: panelHeight)
    }
}

final class OverlayController {
    private let preferences: AppPreferences
    private let renderState: RenderState
    private let onPlaybackCommand: (PlaybackCommand, PlayerSource) -> Void
    private var panels: [CGDirectDisplayID: OverlayPanel] = [:]
    private var cardPanel: LockScreenCardPanel?
    private var cardDisplayID: CGDirectDisplayID?
    private var isVisible = false
    private var isObserving = false

    init(preferences: AppPreferences, renderState: RenderState,
         onPlaybackCommand: @escaping (PlaybackCommand, PlayerSource) -> Void) {
        self.preferences = preferences
        self.renderState = renderState
        self.onPlaybackCommand = onPlaybackCommand
    }

    func show() {
        isVisible = true
        beginObservingIfNeeded()
        refreshDisplays()
    }

    func hide() {
        isVisible = false
        panels.values.forEach {
            $0.disableLockScreenVisibility()
            $0.orderOut(nil)
        }
        cardPanel?.disableLockScreenVisibility()
        cardPanel?.orderOut(nil)
        panels.removeAll()
        cardPanel = nil
        cardDisplayID = nil
    }

    func refreshDisplays() {
        guard isVisible else { return }
        let screens = selectedScreens()
        let selectedIDs = Set(screens.compactMap(displayID))
        let mainID = NSScreen.main.flatMap(displayID)

        for id in Array(panels.keys) where !selectedIDs.contains(id) {
            panels[id]?.orderOut(nil)
            panels[id] = nil
        }

        for screen in screens {
            guard let id = displayID(screen) else { continue }
            let panel: OverlayPanel
            if let existing = panels[id] {
                panel = existing
            } else {
                panel = OverlayPanel(screen: screen, preferences: preferences,
                                     renderState: renderState)
                panels[id] = panel
            }
            panel.updateDisplay(screen)
            panel.level = OverlayPanel.topmostLevel
            panel.orderFrontRegardless()
            if preferences.isScreenLocked {
                panel.enableLockScreenVisibility()
            }
        }
        refreshLockScreenCard(on: NSScreen.main, displayID: mainID)
    }

    func refreshLockScreenCard() {
        guard isVisible else { return }
        refreshLockScreenCard(on: NSScreen.main, displayID: NSScreen.main.flatMap(displayID))
    }

    private func beginObservingIfNeeded() {
        guard !isObserving else { return }
        isObserving = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(fullScreenChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(fullScreenChanged),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        preferences.isScreenLocked = currentLockState()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(screenDidLock),
            name: Notification.Name("com.apple.screenIsLocked"),
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(screenDidUnlock),
            name: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )
    }

    @objc private func screensChanged() {
        refreshDisplays()
    }

    @objc private func fullScreenChanged() {
        for delay in [0.0, 0.2, 0.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refreshDisplays()
            }
        }
    }

    @objc private func screenDidLock() {
        preferences.isScreenLocked = true
        refreshDisplays()
        panels.values.forEach { $0.enableLockScreenVisibility() }
        refreshLockScreenCard()
    }

    @objc private func screenDidUnlock() {
        preferences.isScreenLocked = false
        cardPanel?.orderOut(nil)
        // Keep the delegated window alive through the unlock cross-fade to avoid
        // a flash, then return it to the normal window spaces.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, !self.preferences.isScreenLocked else { return }
            self.panels.values.forEach { $0.disableLockScreenVisibility() }
            self.cardPanel?.disableLockScreenVisibility()
        }
    }

    private func refreshLockScreenCard(on screen: NSScreen?, displayID: CGDirectDisplayID?) {
        let shouldShow = preferences.isScreenLocked
            && preferences.nowPlayingCardEnabled
            && renderState.track.state != .unavailable
        guard shouldShow else {
            cardPanel?.orderOut(nil)
            return
        }

        guard let screen, let displayID else {
            cardPanel?.orderOut(nil)
            return
        }

        if cardPanel == nil || cardDisplayID != displayID {
            cardPanel?.disableLockScreenVisibility()
            cardPanel?.orderOut(nil)
            cardPanel = LockScreenCardPanel(
                screen: screen,
                renderState: renderState,
                onPlaybackCommand: onPlaybackCommand
            )
            cardDisplayID = displayID
        } else {
            cardPanel?.reposition(on: screen)
        }

        cardPanel?.level = OverlayPanel.topmostLevel
        cardPanel?.orderFrontRegardless()
        cardPanel?.enableLockScreenVisibility()
    }

    private func currentLockState() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    private func selectedScreens() -> [NSScreen] {
        switch preferences.displayTarget {
        case .builtIn:
            if let builtIn = NSScreen.screens.first(where: { screen in
                guard let id = displayID(screen) else { return false }
                return CGDisplayIsBuiltin(id) != 0
            }) {
                return [builtIn]
            }
            return NSScreen.main.map { [$0] } ?? []
        case .main:
            return NSScreen.main.map { [$0] } ?? []
        case .all:
            return NSScreen.screens
        }
    }

    private func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }
}
