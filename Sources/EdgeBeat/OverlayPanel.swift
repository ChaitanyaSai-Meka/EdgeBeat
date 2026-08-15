import AppKit
import SwiftUI

/// Hosting view that reports zero safe-area insets so SwiftUI draws all the way to
/// the true physical top edge (behind the notch / menu bar). Without this, the
/// window's safe area pushes the canvas *below* the notch and the top glow appears
/// under it instead of flanking it.
private final class GlowHostingView: NSHostingView<EdgeGlowView> {
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
}

/// Non-activating, borderless, click-through overlay window that hosts the glow.
/// Floats above normal windows and full-screen apps, on every Space.
final class OverlayPanel: NSPanel {
    init(screen: NSScreen, settings: GlowSettings, renderState: RenderState) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true            // click-through: clicks pass to apps below
        // Keep the panel just above the screen-saver level so full-screen app
        // surfaces cannot cover the edge while system UI remains usable.
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isFloatingPanel = true
        isMovableByWindowBackground = false
        hidesOnDeactivate = false

        let host = GlowHostingView(rootView: EdgeGlowView(settings: settings, renderState: renderState))
        host.frame = NSRect(origin: .zero, size: screen.frame.size)
        host.autoresizingMask = [.width, .height]
        contentView = host
    }

    // Never steal focus — this is a passive overlay.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns the overlay panel: creates it lazily, toggles visibility, drives live
/// settings (brightness), and keeps it sized to the main display across
/// resolution / arrangement changes.
final class OverlayController {
    let settings = GlowSettings()
    private let renderState: RenderState
    private var panel: OverlayPanel?

    init(renderState: RenderState) {
        self.renderState = renderState
    }

    func show() {
        if panel == nil {
            guard let screen = NSScreen.main else { return }
            panel = OverlayPanel(screen: screen, settings: settings, renderState: renderState)
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
        }
        reassertOverlay()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func setIntensity(_ value: Double) {
        settings.intensity = value
    }

    @objc private func screensChanged() {
        reassertOverlay()
    }

    @objc private func fullScreenChanged() {
        // Full-screen transitions can temporarily reorder auxiliary windows below
        // the app's full-screen surface. Reassert the frame and level afterwards.
        for delay in [0.0, 0.2, 0.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.reassertOverlay()
            }
        }
    }

    private func reassertOverlay() {
        layoutToMainScreen()
        panel?.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel?.orderFrontRegardless()
    }

    private func layoutToMainScreen() {
        guard let panel, let screen = NSScreen.main else { return }
        // Full frame (not visibleFrame) so the top edge sits at the true physical
        // top and wraps around the notch.
        panel.setFrame(screen.frame, display: true)
    }
}
