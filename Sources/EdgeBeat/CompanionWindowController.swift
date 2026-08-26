import AppKit
import SwiftUI

final class CompanionWindowController: NSWindowController, NSWindowDelegate {
    var onVisibilityChange: ((Bool) -> Void)?

    init(
        renderState: RenderState,
        onPlaybackCommand: @escaping (PlaybackCommand, PlayerSource) -> Void,
        onSeek: @escaping (TimeInterval, PlayerSource) -> Void
    ) {
        let window = NSWindow(
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
            close()
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
        onVisibilityChange?(true)
    }

    func windowWillClose(_ notification: Notification) {
        onVisibilityChange?(false)
    }

    func windowDidMiniaturize(_ notification: Notification) {
        onVisibilityChange?(false)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        onVisibilityChange?(true)
    }

}
