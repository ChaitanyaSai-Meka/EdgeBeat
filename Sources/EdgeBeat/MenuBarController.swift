import AppKit

private final class ColorPreviewView: NSView {
    var primary = NSColor.white { didSet { needsDisplay = true } }
    var secondary = NSColor.white { didSet { needsDisplay = true } }
    var usesGradient = true { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 14, dy: 8)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        if usesGradient, let gradient = NSGradient(colors: [primary, secondary]) {
            gradient.draw(in: path, angle: 0)
        } else {
            primary.setFill()
            path.fill()
        }
        NSColor.white.withAlphaComponent(0.24).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

private enum MenuColorPreset: String, CaseIterable {
    case ocean = "Ocean"
    case sunset = "Sunset"
    case aurora = "Aurora"
    case neon = "Neon"
    case monochrome = "Monochrome"

    var colors: (NSColor, NSColor) {
        switch self {
        case .ocean:
            (NSColor(calibratedRed: 0.05, green: 0.72, blue: 0.95, alpha: 1),
             NSColor(calibratedRed: 0.08, green: 0.28, blue: 0.9, alpha: 1))
        case .sunset:
            (NSColor(calibratedRed: 1, green: 0.34, blue: 0.2, alpha: 1),
             NSColor(calibratedRed: 1, green: 0.18, blue: 0.58, alpha: 1))
        case .aurora:
            (NSColor(calibratedRed: 0.15, green: 0.9, blue: 0.56, alpha: 1),
             NSColor(calibratedRed: 0.16, green: 0.55, blue: 1, alpha: 1))
        case .neon:
            (NSColor(calibratedRed: 0.78, green: 0.22, blue: 1, alpha: 1),
             NSColor(calibratedRed: 0.1, green: 0.96, blue: 0.84, alpha: 1))
        case .monochrome:
            (NSColor(calibratedWhite: 0.95, alpha: 1),
             NSColor(calibratedWhite: 0.35, alpha: 1))
        }
    }
}

final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let preferences: AppPreferences
    private let nowPlayingItem = NSMenuItem(title: "Waiting for music...", action: nil, keyEquivalent: "")
    private let captureStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var lightingItem: NSMenuItem!
    private var primaryColorItem: NSMenuItem!
    private var secondaryColorItem: NSMenuItem!
    private var primaryColorWell: NSColorWell!
    private var secondaryColorWell: NSColorWell!
    private var intensityValueLabel: NSTextField?
    private var thicknessValueLabel: NSTextField?
    private var waveLengthValueLabel: NSTextField?
    private var waveIntensityValueLabel: NSTextField?
    private var waveSpeedValueLabel: NSTextField?
    private var colorSourceItems: [ColorSource: NSMenuItem] = [:]
    private var colorModeItems: [CustomColorMode: NSMenuItem] = [:]
    private var colorPresetItems: [MenuColorPreset: NSMenuItem] = [:]
    private var displayItems: [DisplayTarget: NSMenuItem] = [:]
    private var sourceItems: [PlayerSource: NSMenuItem] = [:]
    private var selectedSource: PlayerSource
    private var cardItem: NSMenuItem!
    private var launchAtLoginItem: NSMenuItem!
    private var checkForUpdatesItem: NSMenuItem!
    private var colorPreviewItem: NSMenuItem!
    private var colorPreviewView: ColorPreviewView!
    private var customColorHeaderItem: NSMenuItem!
    private var customColorSeparatorItem: NSMenuItem!
    private var colorPresetsItem: NSMenuItem!
    private var waveFlowItem: NSMenuItem!
    private var waveLengthItem: NSMenuItem!
    private var waveIntensityItem: NSMenuItem!
    private var waveSpeedItem: NSMenuItem!
    private var waveControlsSeparatorItem: NSMenuItem!

    var onQuit: (() -> Void)?
    var onSourceChange: ((PlayerSource) -> Void)?
    var onOpenPermissions: (() -> Void)?
    var onLaunchAtLoginChange: ((Bool) -> Bool)?
    var onCheckForUpdates: (() -> Void)?

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
        DispatchQueue.main.async { [weak self] in
            self?.syncMenuState()
        }
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

        lightingItem = commandItem("Lighting", action: #selector(toggleLighting(_:)), icon: "light.max")
        menu.addItem(lightingItem)
        menu.addItem(.separator())

        menu.addItem(makeColorsMenu())
        menu.addItem(makeSliderItem(title: "Glow", symbol: "sun.max.fill", value: preferences.intensity,
                                    action: #selector(intensityChanged(_:)),
                                    valueLabel: &intensityValueLabel))
        menu.addItem(makeSliderItem(title: "Thickness", symbol: "line.3.horizontal",
                                    value: preferences.thickness,
                                    action: #selector(thicknessChanged(_:)),
                                    valueLabel: &thicknessValueLabel))
        menu.addItem(makeWaveMenu())
        menu.addItem(makeDisplayMenu())

        cardItem = commandItem("Lock Screen Now Playing", action: #selector(toggleCard(_:)),
                               icon: "lock.rectangle")
        menu.addItem(cardItem)
        menu.addItem(makeSourceMenu())
        menu.addItem(.separator())

        launchAtLoginItem = commandItem("Launch at Login", action: #selector(toggleLaunchAtLogin(_:)),
                                        icon: "power")
        menu.addItem(launchAtLoginItem)
        menu.addItem(commandItem("Open Privacy Settings...", action: #selector(openPermissions),
                                 icon: "hand.raised.fill"))
        checkForUpdatesItem = commandItem("Check for Updates...", action: #selector(checkForUpdates),
                                          icon: "arrow.triangle.2.circlepath")
        menu.addItem(checkForUpdatesItem)
        let quit = commandItem("Quit EdgeBeat", action: #selector(quitTapped), icon: "xmark.circle")
        quit.keyEquivalent = "q"
        menu.addItem(quit)
        menu.addItem(.separator())

        let versionItem = NSMenuItem(title: Self.versionTitle, action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        return menu
    }

    private static var versionTitle: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "EdgeBeat \(version ?? "Development")"
    }

    private func makeColorsMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Colors", action: nil, keyEquivalent: "")
        parent.image = symbol("paintpalette.fill")
        let submenu = NSMenu(title: "Colors")

        submenu.addItem(sectionHeader("Color Source"))
        for source in ColorSource.allCases {
            let item = commandItem(source.rawValue, action: #selector(colorSourceChanged(_:)))
            item.representedObject = source.rawValue
            colorSourceItems[source] = item
            submenu.addItem(item)
        }
        submenu.addItem(.separator())

        customColorHeaderItem = sectionHeader("Custom Appearance")
        submenu.addItem(customColorHeaderItem)
        for mode in CustomColorMode.allCases {
            let item = commandItem(mode.rawValue, action: #selector(colorModeChanged(_:)))
            item.representedObject = mode.rawValue
            colorModeItems[mode] = item
            submenu.addItem(item)
        }
        customColorSeparatorItem = .separator()
        submenu.addItem(customColorSeparatorItem)

        colorPreviewView = ColorPreviewView(frame: NSRect(x: 0, y: 0, width: 252, height: 42))
        colorPreviewItem = NSMenuItem()
        colorPreviewItem.view = colorPreviewView
        submenu.addItem(colorPreviewItem)

        primaryColorItem = makeColorItem(title: "Primary", color: preferences.primaryColor,
                                         isPrimary: true,
                                         action: #selector(primaryColorChanged(_:)))
        submenu.addItem(primaryColorItem)
        secondaryColorItem = makeColorItem(title: "Secondary", color: preferences.secondaryColor,
                                           isPrimary: false,
                                           action: #selector(secondaryColorChanged(_:)))
        submenu.addItem(secondaryColorItem)
        colorPresetsItem = makePresetMenu()
        submenu.addItem(colorPresetsItem)
        parent.submenu = submenu
        return parent
    }

    private func makeColorItem(title: String, color: NSColor, isPrimary: Bool,
                               action: Selector) -> NSMenuItem {
        let width: CGFloat = 252
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 42))
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.frame = NSRect(x: 18, y: 13, width: 150, height: 17)
        container.addSubview(label)

        let well = NSColorWell(frame: NSRect(x: width - 62, y: 7, width: 46, height: 28))
        well.colorWellStyle = .minimal
        well.color = color
        well.target = self
        well.action = action
        container.addSubview(well)
        if isPrimary {
            primaryColorWell = well
        } else {
            secondaryColorWell = well
        }

        let item = NSMenuItem()
        item.view = container
        return item
    }

    private func makePresetMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Presets", action: nil, keyEquivalent: "")
        parent.image = symbol("square.grid.2x2")
        let submenu = NSMenu(title: "Presets")
        for preset in MenuColorPreset.allCases {
            let item = commandItem(preset.rawValue, action: #selector(colorPresetChanged(_:)))
            item.representedObject = preset.rawValue
            item.image = colorSwatch(colors: preset.colors)
            colorPresetItems[preset] = item
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    private func makeWaveMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Wave", action: nil, keyEquivalent: "")
        parent.image = symbol("water.waves")
        let submenu = NSMenu(title: "Wave")

        waveFlowItem = commandItem("Wave Flow", action: #selector(toggleWaveFlow(_:)))
        submenu.addItem(waveFlowItem)
        waveControlsSeparatorItem = .separator()
        submenu.addItem(waveControlsSeparatorItem)

        waveLengthItem = makeSliderItem(
            title: "Wave Length",
            symbol: nil,
            value: preferences.waveLength,
            action: #selector(waveLengthChanged(_:)),
            valueLabel: &waveLengthValueLabel
        )
        submenu.addItem(waveLengthItem)
        waveIntensityItem = makeSliderItem(
            title: "Wave Intensity",
            symbol: nil,
            value: preferences.waveIntensity,
            action: #selector(waveIntensityChanged(_:)),
            valueLabel: &waveIntensityValueLabel
        )
        submenu.addItem(waveIntensityItem)
        waveSpeedItem = makeWaveSpeedSliderItem()
        submenu.addItem(waveSpeedItem)

        parent.submenu = submenu
        return parent
    }

    private func makeSliderItem(title: String, symbol: String?, value: Double, action: Selector,
                                valueLabel: inout NSTextField?) -> NSMenuItem {
        let width: CGFloat = 240
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 54))
        if let symbol {
            let icon = NSImageView(frame: NSRect(x: 14, y: 31, width: 16, height: 16))
            icon.image = self.symbol(symbol)
            icon.contentTintColor = .secondaryLabelColor
            container.addSubview(icon)
        }

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: symbol == nil ? 14 : 36, y: 32,
                             width: symbol == nil ? width - 82 : width - 104, height: 16)
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

    private func makeWaveSpeedSliderItem() -> NSMenuItem {
        let width: CGFloat = 240
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 72))
        let preset = WaveSpeedPreset.nearest(to: preferences.waveSpeed)

        let title = NSTextField(labelWithString: "Wave Speed")
        title.font = .systemFont(ofSize: 12)
        title.textColor = .secondaryLabelColor
        title.frame = NSRect(x: 14, y: 50, width: width - 98, height: 16)
        container.addSubview(title)

        let value = NSTextField(labelWithString: preset.title)
        value.font = .systemFont(ofSize: 11, weight: .regular)
        value.textColor = .secondaryLabelColor
        value.alignment = .right
        value.frame = NSRect(x: width - 82, y: 50, width: 68, height: 16)
        container.addSubview(value)
        waveSpeedValueLabel = value

        let slider = NSSlider(
            value: Double(preset.rawValue),
            minValue: Double(WaveSpeedPreset.slow.rawValue),
            maxValue: Double(WaveSpeedPreset.fast.rawValue),
            target: self,
            action: #selector(waveSpeedChanged(_:))
        )
        slider.isContinuous = true
        slider.numberOfTickMarks = WaveSpeedPreset.allCases.count
        slider.allowsTickMarkValuesOnly = true
        slider.tickMarkPosition = .below
        slider.frame = NSRect(x: 14, y: 22, width: width - 28, height: 24)
        container.addSubview(slider)

        for preset in WaveSpeedPreset.allCases {
            let label = NSTextField(labelWithString: preset.title)
            label.font = .systemFont(ofSize: 9)
            label.textColor = .tertiaryLabelColor
            label.alignment = preset == .slow ? .left : preset == .fast ? .right : .center
            let segmentWidth = (width - 28) / 3
            label.frame = NSRect(
                x: 14 + CGFloat(preset.rawValue) * segmentWidth,
                y: 4,
                width: segmentWidth,
                height: 12
            )
            container.addSubview(label)
        }

        let item = NSMenuItem()
        item.view = container
        return item
    }

    private func makeDisplayMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
        parent.image = symbol("display")
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
        parent.image = symbol("music.note")
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

    private func commandItem(_ title: String, action: Selector, icon: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = icon.flatMap(symbol)
        return item
    }

    private func sectionHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    private func colorSwatch(colors: (NSColor, NSColor)) -> NSImage {
        let image = NSImage(size: NSSize(width: 28, height: 14))
        image.lockFocus()
        let path = NSBezierPath(roundedRect: NSRect(x: 0, y: 1, width: 28, height: 12),
                                xRadius: 4, yRadius: 4)
        NSGradient(colors: [colors.0, colors.1])?.draw(in: path, angle: 0)
        NSColor.white.withAlphaComponent(0.28).setStroke()
        path.lineWidth = 1
        path.stroke()
        image.unlockFocus()
        return image
    }

    @objc private func toggleLighting(_ sender: NSMenuItem) {
        preferences.enabled.toggle()
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
        syncMenuState()
    }

    @objc private func secondaryColorChanged(_ sender: NSColorWell) {
        preferences.secondaryColor = sender.color
        syncMenuState()
    }

    @objc private func colorPresetChanged(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let preset = MenuColorPreset(rawValue: raw) else { return }
        preferences.colorSource = .custom
        preferences.colorMode = .gradient
        preferences.primaryColor = preset.colors.0
        preferences.secondaryColor = preset.colors.1
        syncMenuState()
    }

    @objc private func intensityChanged(_ sender: NSSlider) {
        preferences.intensity = sender.doubleValue
        intensityValueLabel?.stringValue = "\(Int((sender.doubleValue * 100).rounded()))%"
    }

    @objc private func thicknessChanged(_ sender: NSSlider) {
        preferences.thickness = sender.doubleValue
        thicknessValueLabel?.stringValue = "\(Int((sender.doubleValue * 100).rounded()))%"
    }

    @objc private func toggleWaveFlow(_ sender: NSMenuItem) {
        preferences.waveFlowEnabled.toggle()
        syncMenuState()
    }

    @objc private func waveLengthChanged(_ sender: NSSlider) {
        preferences.waveLength = sender.doubleValue
        waveLengthValueLabel?.stringValue = "\(Int((sender.doubleValue * 100).rounded()))%"
    }

    @objc private func waveIntensityChanged(_ sender: NSSlider) {
        preferences.waveIntensity = sender.doubleValue
        waveIntensityValueLabel?.stringValue = "\(Int((sender.doubleValue * 100).rounded()))%"
    }

    @objc private func waveSpeedChanged(_ sender: NSSlider) {
        guard let preset = WaveSpeedPreset(rawValue: sender.integerValue) else { return }
        preferences.waveSpeed = preset.speed
        waveSpeedValueLabel?.stringValue = preset.title
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

    @objc private func checkForUpdates() {
        onCheckForUpdates?()
    }

    @objc private func quitTapped() {
        onQuit?()
    }

    private func syncMenuState() {
        lightingItem?.state = preferences.enabled ? .on : .off
        waveFlowItem?.state = preferences.waveFlowEnabled ? .on : .off
        let showWaveControls = preferences.waveFlowEnabled
        waveControlsSeparatorItem?.isHidden = !showWaveControls
        waveLengthItem?.isHidden = !showWaveControls
        waveIntensityItem?.isHidden = !showWaveControls
        waveSpeedItem?.isHidden = !showWaveControls
        colorSourceItems.forEach { $0.value.state = $0.key == preferences.colorSource ? .on : .off }
        colorModeItems.forEach { key, item in
            item.state = key == preferences.colorMode ? .on : .off
            item.isHidden = preferences.colorSource != .custom
        }
        primaryColorItem?.isHidden = preferences.colorSource != .custom
        secondaryColorItem?.isHidden = preferences.colorSource != .custom
            || preferences.colorMode != .gradient
        customColorHeaderItem?.isHidden = preferences.colorSource != .custom
        customColorSeparatorItem?.isHidden = preferences.colorSource != .custom
        colorPresetsItem?.isHidden = preferences.colorSource != .custom
        colorPreviewItem?.isHidden = preferences.colorSource != .custom
        primaryColorWell?.color = preferences.primaryColor
        secondaryColorWell?.color = preferences.secondaryColor
        colorPreviewView?.primary = preferences.primaryColor
        colorPreviewView?.secondary = preferences.secondaryColor
        colorPreviewView?.usesGradient = preferences.colorMode == .gradient
        colorPresetItems.forEach { preset, item in
            item.state = preferences.colorSource == .custom
                && preferences.colorMode == .gradient
                && colorsMatch(preferences.primaryColor, preset.colors.0)
                && colorsMatch(preferences.secondaryColor, preset.colors.1) ? .on : .off
        }
        displayItems.forEach { $0.value.state = $0.key == preferences.displayTarget ? .on : .off }
        sourceItems.forEach { $0.value.state = $0.key == selectedSource ? .on : .off }
        cardItem?.state = preferences.nowPlayingCardEnabled ? .on : .off
    }

    private func colorsMatch(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        guard let left = lhs.usingColorSpace(.deviceRGB),
              let right = rhs.usingColorSpace(.deviceRGB) else { return false }
        return abs(left.redComponent - right.redComponent) < 0.01
            && abs(left.greenComponent - right.greenComponent) < 0.01
            && abs(left.blueComponent - right.blueComponent) < 0.01
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

    func setCheckingForUpdates(_ checking: Bool) {
        checkForUpdatesItem?.title = checking ? "Checking for Updates..." : "Check for Updates..."
        checkForUpdatesItem?.isEnabled = !checking
    }
}
