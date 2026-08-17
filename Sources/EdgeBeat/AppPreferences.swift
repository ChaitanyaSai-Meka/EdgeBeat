import AppKit
import Foundation

enum ColorSource: String, CaseIterable {
    case album = "Album Colors"
    case custom = "Custom"
}

enum CustomColorMode: String, CaseIterable {
    case single = "Single"
    case gradient = "Gradient"
}

enum DisplayTarget: String, CaseIterable {
    case builtIn = "Built-in Display"
    case main = "Main Display"
    case all = "All Displays"
}

enum WaveSpeedPreset: Int, CaseIterable {
    case slow
    case medium
    case fast

    var title: String {
        switch self {
        case .slow: "Slow"
        case .medium: "Medium"
        case .fast: "Fast"
        }
    }

    var speed: Double {
        switch self {
        case .slow: 0.3
        case .medium: 0.6
        case .fast: 1
        }
    }

    static func nearest(to speed: Double) -> WaveSpeedPreset {
        allCases.min { abs($0.speed - speed) < abs($1.speed - speed) } ?? .medium
    }
}

final class AppPreferences: ObservableObject {
    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Keys.enabled) }
    }
    @Published var isScreenLocked = false
    @Published var colorSource: ColorSource {
        didSet { defaults.set(colorSource.rawValue, forKey: Keys.colorSource) }
    }
    @Published var colorMode: CustomColorMode {
        didSet { defaults.set(colorMode.rawValue, forKey: Keys.colorMode) }
    }
    @Published var primaryColor: NSColor {
        didSet { store(primaryColor, key: Keys.primaryColor) }
    }
    @Published var secondaryColor: NSColor {
        didSet { store(secondaryColor, key: Keys.secondaryColor) }
    }
    @Published var intensity: Double {
        didSet { defaults.set(intensity, forKey: Keys.intensity) }
    }
    @Published var thickness: Double {
        didSet { defaults.set(thickness, forKey: Keys.thickness) }
    }
    @Published var waveFlowEnabled: Bool {
        didSet { defaults.set(waveFlowEnabled, forKey: Keys.waveFlowEnabled) }
    }
    @Published var waveLength: Double {
        didSet { defaults.set(waveLength, forKey: Keys.waveLength) }
    }
    @Published var waveIntensity: Double {
        didSet { defaults.set(waveIntensity, forKey: Keys.waveIntensity) }
    }
    @Published var waveSpeed: Double {
        didSet { defaults.set(waveSpeed, forKey: Keys.waveSpeed) }
    }
    @Published var displayTarget: DisplayTarget {
        didSet { defaults.set(displayTarget.rawValue, forKey: Keys.displayTarget) }
    }
    @Published var nowPlayingCardEnabled: Bool {
        didSet { defaults.set(nowPlayingCardEnabled, forKey: Keys.nowPlayingCardEnabled) }
    }
    @Published var playerSource: PlayerSource {
        didSet { defaults.set(playerSource.rawValue, forKey: Keys.playerSource) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        colorSource = ColorSource(rawValue: defaults.string(forKey: Keys.colorSource) ?? "") ?? .album
        colorMode = CustomColorMode(rawValue: defaults.string(forKey: Keys.colorMode) ?? "") ?? .gradient
        primaryColor = Self.loadColor(defaults: defaults, key: Keys.primaryColor)
            ?? NSColor(calibratedRed: 0.2, green: 0.65, blue: 1, alpha: 1)
        secondaryColor = Self.loadColor(defaults: defaults, key: Keys.secondaryColor)
            ?? NSColor(calibratedRed: 1, green: 0.25, blue: 0.65, alpha: 1)
        let usedLegacyOrbit = defaults.string(forKey: Keys.animationMode) == "Orbit"
        intensity = defaults.object(forKey: Keys.intensity) as? Double ?? 0.85
        thickness = defaults.object(forKey: Keys.thickness) as? Double ?? 0.45
        waveFlowEnabled = defaults.object(forKey: Keys.waveFlowEnabled) as? Bool ?? usedLegacyOrbit
        waveLength = defaults.object(forKey: Keys.waveLength) as? Double ?? 0.5
        waveIntensity = defaults.object(forKey: Keys.waveIntensity) as? Double ?? 0.75
        let storedWaveSpeed = defaults.object(forKey: Keys.waveSpeed) as? Double ?? 0.6
        waveSpeed = WaveSpeedPreset.nearest(to: storedWaveSpeed).speed
        displayTarget = DisplayTarget(rawValue: defaults.string(forKey: Keys.displayTarget) ?? "") ?? .builtIn
        nowPlayingCardEnabled = defaults.object(forKey: Keys.nowPlayingCardEnabled) as? Bool ?? false
        playerSource = PlayerSource(rawValue: defaults.string(forKey: Keys.playerSource) ?? "") ?? .automatic
    }

    private func store(_ color: NSColor, key: String) {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return }
        defaults.set([rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent],
                     forKey: key)
    }

    private static func loadColor(defaults: UserDefaults, key: String) -> NSColor? {
        guard let components = defaults.array(forKey: key) as? [Double], components.count == 4 else {
            return nil
        }
        return NSColor(calibratedRed: components[0], green: components[1],
                       blue: components[2], alpha: components[3])
    }

    private enum Keys {
        static let enabled = "lighting.enabled"
        static let colorSource = "colors.source"
        static let colorMode = "colors.mode"
        static let primaryColor = "colors.primary"
        static let secondaryColor = "colors.secondary"
        static let animationMode = "animation.mode"
        static let intensity = "glow.intensity"
        static let thickness = "glow.thickness"
        static let waveFlowEnabled = "waveFlow.enabled"
        static let waveLength = "waveFlow.length"
        static let waveIntensity = "waveFlow.intensity"
        static let waveSpeed = "waveFlow.speed"
        static let displayTarget = "display.target"
        static let nowPlayingCardEnabled = "nowPlaying.cardEnabled"
        static let playerSource = "player.source"
    }
}
