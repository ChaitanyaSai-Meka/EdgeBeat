import AppKit

final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let preferences: AppPreferences
    private let nowPlayingItem = NSMenuItem(title: "Waiting for music...", action: nil, keyEquivalent: "")
    private let captureStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var lightingItem: NSMenuItem!
    private var primaryColorItem: NSMenuItem!
    private var secondaryColorItem: NSMenuItem!
    private var intensityValueLabel: NSTextField?
    private var thicknessValueLabel: NSTextField?
    private var animationItems: [GlowAnimationMode: NSMenuItem] = [:]
    private var colorSourceItems: [ColorSource: NSMenuItem] = [:]
    private var colorModeItems: [CustomColorMode: NSMenuItem] = [:]
    private var displayItems: [DisplayTarget: NSMenuItem] = [:]
    private var sourceItems: [PlayerSource: NSMenuItem] = [:]
    private var selectedSource: PlayerSource
    private var cardItem: NSMenuItem!
    private var launchAtLoginItem: NSMenuItem!

    var onQuit: (() -> Void)?
    var onSourceChange: ((PlayerSource) -> Void)?
    var onOpenPermissions: (() -> Void)?
    var onLaunchAtLoginChange: ((Bool) -> Bool)?

    init(preferences: AppPreferences) {
        self.preferences = preferences
        selectedSource = preferences.playerSource
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform",
                                   accessibilityDescription: "EdgeBeat")
            button.image?.isTemplate = true
        }
        let menu = makeMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        syncMenuState()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        nowPlayingItem.isEnabled = false
        menu.addItem(nowPlayingItem)
        captureStatusItem.isEnabled = false
        captureStatusItem.isHidden = true
        menu.addItem(captureStatusItem)
        menu.addItem(.separator())

        lightingItem = commandItem("Lighting", action: #selector(toggleLighting(_:)))
        menu.addItem(lightingItem)
        menu.addItem(.separator())

        menu.addItem(makeAnimationMenu())
        menu.addItem(makeColorsMenu())
        menu.addItem(makeSliderItem(title: "Glow", value: preferences.intensity,
                                    action: #selector(intensityChanged(_:)),
                                    valueLabel: &intensityValueLabel))
        menu.addItem(makeSliderItem(title: "Thickness", value: preferences.thickness,
                                    action: #selector(thicknessChanged(_:)),
                                    valueLabel: &thicknessValueLabel))
        menu.addItem(makeDisplayMenu())

        cardItem = commandItem("Lock Screen Now Playing", action: #selector(toggleCard(_:)))
        menu.addItem(cardItem)
        menu.addItem(makeSourceMenu())
        menu.addItem(.separator())

        launchAtLoginItem = commandItem("Launch at Login", action: #selector(toggleLaunchAtLogin(_:)))
        menu.addItem(launchAtLoginItem)
        menu.addItem(commandItem("Open Privacy Settings...", action: #selector(openPermissions)))
        let quit = commandItem("Quit EdgeBeat", action: #selector(quitTapped))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
        menu.addItem(.separator())

        let versionItem = NSMenuItem(title: Self.versionTitle, action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        syncMenuState()
        return menu
    }

    private static var versionTitle: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "EdgeBeat \(version ?? "Development")"
    }

    private func makeAnimationMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Animation", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Animation")
        for mode in GlowAnimationMode.allCases {
            let item = commandItem(mode.rawValue, action: #selector(animationChanged(_:)))
            item.representedObject = mode.rawValue
            animationItems[mode] = item
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    private func makeColorsMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Colors", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Colors")

        for source in ColorSource.allCases {
            let item = commandItem(source.rawValue, action: #selector(colorSourceChanged(_:)))
            item.representedObject = source.rawValue
            colorSourceItems[source] = item
            submenu.addItem(item)
        }
        submenu.addItem(.separator())

        for mode in CustomColorMode.allCases {
            let item = commandItem(mode.rawValue, action: #selector(colorModeChanged(_:)))
            item.representedObject = mode.rawValue
            colorModeItems[mode] = item
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        primaryColorItem = makeColorItem(title: "Primary", color: preferences.primaryColor,
                                         action: #selector(primaryColorChanged(_:)))
        submenu.addItem(primaryColorItem)
        secondaryColorItem = makeColorItem(title: "Secondary", color: preferences.secondaryColor,
                                           action: #selector(secondaryColorChanged(_:)))
        submenu.addItem(secondaryColorItem)
        parent.submenu = submenu
        return parent
    }

    private func makeColorItem(title: String, color: NSColor, action: Selector) -> NSMenuItem {
        let width: CGFloat = 238
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 38))
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 14, y: 11, width: 150, height: 16)
        container.addSubview(label)

        let well = NSColorWell(frame: NSRect(x: width - 52, y: 7, width: 38, height: 24))
        well.colorWellStyle = .minimal
        well.color = color
        well.target = self
        well.action = action
        container.addSubview(well)

        let item = NSMenuItem()
        item.view = container
        return item
    }

    private func makeSliderItem(title: String, value: Double, action: Selector,
                                valueLabel: inout NSTextField?) -> NSMenuItem {
        let width: CGFloat = 240
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 54))
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 14, y: 32, width: width - 82, height: 16)
        container.addSubview(label)

        let percentage = NSTextField(labelWithString: "\(Int((value * 100).rounded()))%")
        percentage.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        percentage.textColor = .secondaryLabelColor
        percentage.alignment = .right
        percentage.frame = NSRect(x: width - 64, y: 32, width: 50, height: 16)
        container.addSubview(percentage)
        valueLabel = percentage

        let slider = NSSlider(value: value, minValue: 0, maxValue: 1, target: self, action: action)
        slider.isContinuous = true
        slider.frame = NSRect(x: 14, y: 8, width: width - 28, height: 20)
        container.addSubview(slider)

        let item = NSMenuItem()
        item.view = container
        return item
    }

    private func makeDisplayMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Display")
        for target in DisplayTarget.allCases {
            let item = commandItem(target.rawValue, action: #selector(displayChanged(_:)))
            item.representedObject = target.rawValue
            displayItems[target] = item
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    private func makeSourceMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Music Source", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Music Source")
        for source in PlayerSource.allCases {
            let item = commandItem(source.rawValue, action: #selector(sourceChanged(_:)))
            item.representedObject = source.rawValue
            sourceItems[source] = item
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    private func commandItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func toggleLighting(_ sender: NSMenuItem) {
        preferences.enabled.toggle()
        syncMenuState()
    }

    @objc private func animationChanged(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = GlowAnimationMode(rawValue: raw) else { return }
        preferences.animationMode = mode
        syncMenuState()
    }

    @objc private func colorSourceChanged(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let source = ColorSource(rawValue: raw) else { return }
        preferences.colorSource = source
        syncMenuState()
    }

    @objc private func colorModeChanged(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = CustomColorMode(rawValue: raw) else { return }
        preferences.colorMode = mode
        syncMenuState()
    }

    @objc private func primaryColorChanged(_ sender: NSColorWell) {
        preferences.primaryColor = sender.color
    }

    @objc private func secondaryColorChanged(_ sender: NSColorWell) {
        preferences.secondaryColor = sender.color
    }

    @objc private func intensityChanged(_ sender: NSSlider) {
        preferences.intensity = sender.doubleValue
        intensityValueLabel?.stringValue = "\(Int((sender.doubleValue * 100).rounded()))%"
    }

    @objc private func thicknessChanged(_ sender: NSSlider) {
        preferences.thickness = sender.doubleValue
        thicknessValueLabel?.stringValue = "\(Int((sender.doubleValue * 100).rounded()))%"
    }

    @objc private func displayChanged(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let target = DisplayTarget(rawValue: raw) else { return }
        preferences.displayTarget = target
        syncMenuState()
    }

    @objc private func toggleCard(_ sender: NSMenuItem) {
        preferences.nowPlayingCardEnabled.toggle()
        syncMenuState()
    }

    @objc private func sourceChanged(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let source = PlayerSource(rawValue: raw) else { return }
        selectedSource = source
        preferences.playerSource = source
        sourceItems.forEach { $0.value.state = $0.key == selectedSource ? .on : .off }
        onSourceChange?(source)
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let requested = sender.state != .on
        let enabled = onLaunchAtLoginChange?(requested) ?? false
        sender.state = enabled ? .on : .off
    }

    @objc private func openPermissions() {
        onOpenPermissions?()
    }

    @objc private func quitTapped() {
        onQuit?()
    }

    private func syncMenuState() {
        lightingItem?.state = preferences.enabled ? .on : .off
        animationItems.forEach { $0.value.state = $0.key == preferences.animationMode ? .on : .off }
        colorSourceItems.forEach { $0.value.state = $0.key == preferences.colorSource ? .on : .off }
        colorModeItems.forEach { key, item in
            item.state = key == preferences.colorMode ? .on : .off
            item.isHidden = preferences.colorSource != .custom
        }
        primaryColorItem?.isHidden = preferences.colorSource != .custom
        secondaryColorItem?.isHidden = preferences.colorSource != .custom
            || preferences.colorMode != .gradient
        displayItems.forEach { $0.value.state = $0.key == preferences.displayTarget ? .on : .off }
        sourceItems.forEach { $0.value.state = $0.key == selectedSource ? .on : .off }
        cardItem?.state = preferences.nowPlayingCardEnabled ? .on : .off
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

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginItem?.state = enabled ? .on : .off
    }
}
