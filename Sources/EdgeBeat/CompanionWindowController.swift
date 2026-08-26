import AppKit
import SwiftUI

private final class CompanionWindow: NSWindow {
    var handleKeyEvent: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if handleKeyEvent?(event) == true { return }
        super.keyDown(with: event)
    }
}

final class CompanionWindowController: NSWindowController, NSWindowDelegate {
    var onVisibilityChange: ((Bool) -> Void)?

    private var hideAfterExitingFullScreen = false
    private var reportedVisibility = false

    init(
        renderState: RenderState,
        onPlaybackCommand: @escaping (PlaybackCommand, PlayerSource) -> Void,
        onSeek: @escaping (TimeInterval, PlayerSource) -> Void
    ) {
        let window = CompanionWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 680, height: 520)
        window.title = "EdgeBeat Now Playing"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isOpaque = false
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.isMovableByWindowBackground = false
        window.contentView = NSHostingView(
            rootView: CompanionNowPlayingView(
                renderState: renderState,
                onPlaybackCommand: onPlaybackCommand,
                onSeek: onSeek
            )
        )
        window.handleKeyEvent = { [weak renderState] event in
            guard let renderState else { return false }
            let track = renderState.track
            guard track.source == .spotify || track.source == .music else { return false }

            switch event.keyCode {
            case 49 where !event.isARepeat:
                onPlaybackCommand(.togglePlayPause, track.source)
                return true
            case 123, 124:
                if event.modifierFlags.contains(.command) {
                    onPlaybackCommand(event.keyCode == 123 ? .previousTrack : .nextTrack,
                                      track.source)
                    return true
                }
                guard track.duration > 0 else { return false }
                let offset: TimeInterval = event.keyCode == 123 ? -10 : 10
                onSeek(min(track.duration, max(0, track.position + offset)), track.source)
                return true
            default:
                return false
            }
        }
        super.init(window: window)
        window.delegate = self
        window.setFrameAutosaveName("EdgeBeat.CompanionNowPlaying")
        if !window.setFrameUsingName("EdgeBeat.CompanionNowPlaying") {
            window.center()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var isVisible: Bool {
        guard let window else { return false }
        return window.isVisible && !window.isMiniaturized
    }

    func toggle() {
        if let window, window.isMiniaturized {
            show()
        } else if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        reportVisibility(true)
    }

    func hide() {
        guard let window else { return }
        if window.styleMask.contains(.fullScreen) {
            hideAfterExitingFullScreen = true
            window.toggleFullScreen(nil)
            return
        }
        window.orderOut(nil)
        reportVisibility(false)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    func windowDidMiniaturize(_ notification: Notification) {
        reportVisibility(false)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        restoreInteractiveWindow()
        reportVisibility(true)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard let window else { return }
        restoreInteractiveWindow()
        if hideAfterExitingFullScreen {
            hideAfterExitingFullScreen = false
            window.orderOut(nil)
            reportVisibility(false)
        } else {
            window.makeKeyAndOrderFront(nil)
            reportVisibility(true)
        }
    }

    private func restoreInteractiveWindow() {
        guard let window else { return }
        window.makeFirstResponder(nil)
        window.contentView?.needsLayout = true
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func reportVisibility(_ visible: Bool) {
        guard reportedVisibility != visible else { return }
        reportedVisibility = visible
        onVisibilityChange?(visible)
    }
}
