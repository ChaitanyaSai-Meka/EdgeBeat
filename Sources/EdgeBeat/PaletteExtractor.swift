import AppKit

struct GlowPalette {
    var primary: NSColor
    var secondary: NSColor
    var accent: NSColor
    var background: NSColor

    static let `default` = GlowPalette(
        primary: NSColor(calibratedRed: 0.35, green: 0.65, blue: 1, alpha: 1),
        secondary: NSColor(calibratedRed: 0.75, green: 0.45, blue: 1, alpha: 1),
        accent: NSColor(calibratedRed: 1, green: 0.45, blue: 0.75, alpha: 1),
        background: NSColor(calibratedWhite: 0.02, alpha: 1)
    )
}

enum PaletteExtractor {
    static func extract(from image: NSImage?) -> GlowPalette {
        guard let image, let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return .default
        }

        let size = 64
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        guard let context = CGContext(
            data: &pixels,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return .default }
        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        var buckets = Array(repeating: (weight: 0.0, r: 0.0, g: 0.0, b: 0.0), count: 24)
        var darkR = 0.0, darkG = 0.0, darkB = 0.0, darkCount = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[index]) / 255
            let g = Double(pixels[index + 1]) / 255
            let b = Double(pixels[index + 2]) / 255
            let maxValue = max(r, g, b)
            let minValue = min(r, g, b)
            let brightness = maxValue
            let saturation = maxValue == 0 ? 0 : (maxValue - minValue) / maxValue
            if brightness < 0.22 {
                darkR += r; darkG += g; darkB += b; darkCount += 1
            }
            guard saturation > 0.16, brightness > 0.12 else { continue }
            let hue = hsvHue(red: r, green: g, blue: b, max: maxValue, min: minValue)
            let bucket = min(23, max(0, Int(hue * 24)))
            let weight = saturation * (0.35 + 0.65 * min(1, brightness))
            buckets[bucket].weight += weight
            buckets[bucket].r += r * weight
            buckets[bucket].g += g * weight
            buckets[bucket].b += b * weight
        }

        let ranked = buckets.indices.sorted { buckets[$0].weight > buckets[$1].weight }
        let selected = Array(ranked.prefix(3))
        let colors = selected.map { index -> NSColor in
            let bucket = buckets[index]
            guard bucket.weight > 0 else { return .white }
            return NSColor(calibratedRed: bucket.r / bucket.weight, green: bucket.g / bucket.weight,
                           blue: bucket.b / bucket.weight, alpha: 1)
        }
        let fallback = colors + [.systemBlue, .systemPurple, .systemPink]
        let background = darkCount > 0
            ? NSColor(calibratedRed: darkR / darkCount, green: darkG / darkCount, blue: darkB / darkCount, alpha: 1)
            : .black
        return GlowPalette(primary: fallback[0], secondary: fallback[1], accent: fallback[2], background: background)
    }

    private static func hsvHue(red: Double, green: Double, blue: Double, max: Double, min: Double) -> Double {
        let delta = max - min
        guard delta > 0 else { return 0 }
        let value: Double
        if max == red { value = ((green - blue) / delta).truncatingRemainder(dividingBy: 6) }
        else if max == green { value = (blue - red) / delta + 2 }
        else { value = (red - green) / delta + 4 }
        return (value / 6).rounded(.down) < 0 ? (value + 6) / 6 : value / 6
    }
}
