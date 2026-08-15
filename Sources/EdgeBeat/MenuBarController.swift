import AppKit

final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private var enabled = true
    private let nowPlayingItem = NSMenuItem(title: "Waiting for music...", action: nil, keyEquivalent: "")
    private let captureStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var sourceItems: [PlayerSource: NSMenuItem] = [:]
    private weak var brightnessValueLabel: NSTextField?

    var onToggle: ((Bool) -> Void)?
    var onQuit: (() -> Void)?
    var onIntensityChange: ((Double) -> Void)?
    var onSourceChange: ((PlayerSource) -> Void)?
    var onOpenPermissions: (() -> Void)?

    /// Matches GlowSettings' default so the slider starts in sync with the glow.
    private let defaultIntensity = 0.85

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform",
                                   accessibilityDescription: "EdgeBeat")
            button.image?.isTemplate = true
        }
        statusItem.menu = makeMenu()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        nowPlayingItem.isEnabled = false
        menu.addItem(nowPlayingItem)
        captureStatusItem.isEnabled = false
        captureStatusItem.isHidden = true
        menu.addItem(captureStatusItem)
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "Edge Lighting",
                                action: #selector(toggleTapped(_:)),
                                keyEquivalent: "")
        toggle.target = self
        toggle.state = enabled ? .on : .off
        menu.addItem(toggle)

        menu.addItem(makeBrightnessItem())
        menu.addItem(makeSourceItem())
        menu.addItem(.separator())

        let permissions = NSMenuItem(title: "Open Privacy Settings...",
                                     action: #selector(openPermissions), keyEquivalent: "")
        permissions.target = self
        menu.addItem(permissions)

        let quit = NSMenuItem(title: "Quit EdgeBeat",
                              action: #selector(quitTapped),
                              keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    @objc private func toggleTapped(_ sender: NSMenuItem) {
        enabled.toggle()
        sender.state = enabled ? .on : .off
        onToggle?(enabled)
    }

    @objc private func quitTapped() {
        onQuit?()
    }

    // MARK: Brightness slider (custom-view menu item)

    private func makeBrightnessItem() -> NSMenuItem {
        let width: CGFloat = 240
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 54))

        let label = NSTextField(labelWithString: "Brightness")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 14, y: 32, width: width - 82, height: 16)
        container.addSubview(label)

        let valueLabel = NSTextField(labelWithString: "85%")
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.frame = NSRect(x: width - 64, y: 32, width: 50, height: 16)
        container.addSubview(valueLabel)
        brightnessValueLabel = valueLabel

        let slider = NSSlider(value: defaultIntensity, minValue: 0, maxValue: 1,
                              target: self, action: #selector(brightnessChanged(_:)))
        slider.isContinuous = true
        slider.frame = NSRect(x: 14, y: 8, width: width - 28, height: 20)
        container.addSubview(slider)

        let item = NSMenuItem()
        item.view = container
        return item
    }

    @objc private func brightnessChanged(_ sender: NSSlider) {
        brightnessValueLabel?.stringValue = "\(Int((sender.doubleValue * 100).rounded()))%"
        onIntensityChange?(sender.doubleValue)
    }

    private func makeSourceItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Source", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Source")
        for source in PlayerSource.allCases {
            let sourceItem = NSMenuItem(title: source.rawValue,
                                        action: #selector(sourceChanged(_:)), keyEquivalent: "")
            sourceItem.target = self
            sourceItem.representedObject = source.rawValue
            sourceItem.state = source == .automatic ? .on : .off
            sourceItems[source] = sourceItem
            submenu.addItem(sourceItem)
        }
        item.submenu = submenu
        return item
    }

    @objc private func sourceChanged(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let source = PlayerSource(rawValue: rawValue) else { return }
        sourceItems.forEach { $0.value.state = $0.key == source ? .on : .off }
        onSourceChange?(source)
    }

    @objc private func openPermissions() {
        onOpenPermissions?()
    }

    func setNowPlaying(_ track: NowPlayingTrack) {
        if track.state == .unavailable {
            nowPlayingItem.title = "Waiting for Spotify or Apple Music..."
        } else {
            let prefix = track.state == .playing ? "Playing" : "Paused"
            nowPlayingItem.title = "\(prefix): \(track.title) - \(track.artist)"
        }
    }

    func setCaptureStatus(_ message: String?) {
        captureStatusItem.title = message ?? ""
        captureStatusItem.isHidden = message == nil
    }
}
