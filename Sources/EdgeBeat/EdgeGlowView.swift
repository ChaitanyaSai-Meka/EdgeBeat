import AppKit
import SwiftUI

struct DisplayNotch: Equatable {
    let minX: CGFloat
    let maxX: CGFloat
    let depth: CGFloat
    let cornerRadius: CGFloat

    init?(screen: NSScreen) {
        guard screen.safeAreaInsets.top > 0,
              let leftArea = screen.auxiliaryTopLeftArea,
              let rightArea = screen.auxiliaryTopRightArea else { return nil }

        let minX = leftArea.maxX - screen.frame.minX
        let maxX = rightArea.minX - screen.frame.minX
        guard maxX > minX else { return nil }

        depth = screen.safeAreaInsets.top
        self.minX = minX
        self.maxX = maxX
        cornerRadius = min(10, depth * 0.32, (maxX - minX) * 0.12)
    }
}

struct EdgeGlowView: View {
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var renderState: RenderState
    let notch: DisplayNotch?

    var body: some View {
        glow
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }

    private var glow: some View {
        let idle = renderState.isPlaying ? 0.14 : 0.08
        let audio = renderState.isPlaying ? renderState.level * 0.86 : 0
        let level = min(1, idle + audio + (renderState.beat ? 0.18 : 0))
        let waveform = renderState.waveform
        let waveDepth = CGFloat(7 + renderState.level * 17 + (renderState.beat ? 5 : 0))
        let beatBloom: CGFloat = renderState.beat ? 1.12 : 1

        let baseGlowOpacity = level * preferences.intensity
        let thicknessScale = CGFloat(0.3 + preferences.thickness * 1.7)
        let waveFlow: WaveFlowParameters? = preferences.waveFlowEnabled && renderState.isPlaying
            ? WaveFlowParameters(
                phase: renderState.waveFlowPhase,
                segmentLength: min(
                    0.62,
                    0.08 + preferences.waveLength * 0.44
                        + renderState.bass * 0.04 + renderState.mid * 0.02
                        + renderState.waveFlowBeatEnvelope * 0.04
                )
            )
            : nil
        let glowOpacity = baseGlowOpacity
        let waveResponse = min(1, 0.58 + level * 0.3
            + renderState.waveFlowBeatEnvelope * 0.2)
        let waveOpacity = preferences.waveIntensity * waveResponse
        let waveWidthScale = CGFloat(0.45 + preferences.thickness * 1.2
            + renderState.waveFlowBeatEnvelope * 0.15)
        let glowColors = activeColors
        let flowColors = waveFlowColors

        return ZStack {
            if !preferences.waveFlowEnabled {
                Canvas(opaque: false, colorMode: .nonLinear,
                       rendersAsynchronously: true) { context, size in
                    let fields = sideEdgeFields(in: size)
                    drawWaveBand(context: &context, size: size, fields: fields,
                                 waveform: waveform, colors: glowColors,
                                 baseDepth: 15 * thicknessScale * beatBloom,
                                 waveDepth: waveDepth * 1.2 * thicknessScale,
                                 blur: 20 * thicknessScale, opacity: 0.36 * glowOpacity)
                    drawWaveBand(context: &context, size: size, fields: fields,
                                 waveform: waveform, colors: glowColors,
                                 baseDepth: 7 * thicknessScale * beatBloom,
                                 waveDepth: waveDepth * 0.72 * thicknessScale,
                                 blur: 7 * thicknessScale, opacity: 0.62 * glowOpacity)
                    drawWaveBand(context: &context, size: size, fields: fields,
                                 waveform: waveform, colors: glowColors,
                                 baseDepth: max(1, 2.2 * thicknessScale),
                                 waveDepth: waveDepth * 0.24 * thicknessScale,
                                 blur: max(0.6, 1.2 * thicknessScale),
                                 opacity: 0.94 * glowOpacity)
                }
                .blendMode(.screen)
            }

            if let waveFlow {
                Canvas(opaque: false, colorMode: .nonLinear,
                       rendersAsynchronously: true) { context, size in
                    let perimeter = perimeterSamples(in: size)
                    drawWaveFlow(context: &context, size: size, perimeter: perimeter,
                                 colors: flowColors,
                                 waveform: waveform,
                                 parameters: waveFlow,
                                 coreWidth: (3.2 + CGFloat(renderState.level) * 2.2)
                                    * waveWidthScale * beatBloom,
                                 glowWidth: (13 + CGFloat(renderState.level) * 8)
                                    * waveWidthScale * beatBloom,
                                 glowBlur: 12 * waveWidthScale,
                                 opacity: waveOpacity)
                }
            }
        }
        .animation(.easeOut(duration: 0.16), value: renderState.beat)
        .animation(.easeInOut(duration: 0.7), value: renderState.trackTitle)
    }

    private var activeColors: [Color] {
        activeNSColors.map { Color(nsColor: $0) }
    }

    private var waveFlowColors: [Color] {
        activeNSColors.map { Color(nsColor: deeperWaveColor($0)) }
    }

    private var activeNSColors: [NSColor] {
        if preferences.colorSource == .album {
            let palette = renderState.palette
            return [palette.primary, palette.secondary, palette.accent, palette.primary]
        }
        let primary = preferences.primaryColor
        guard preferences.colorMode == .gradient else {
            return [primary, primary, primary, primary]
        }
        let secondary = preferences.secondaryColor
        return [primary, secondary, primary, secondary]
    }

    private func deeperWaveColor(_ color: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return color }
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        guard saturation >= 0.08 else { return color }
        return NSColor(
            calibratedHue: hue,
            saturation: min(1, max(0.68, saturation * 1.18)),
            brightness: min(0.84, max(0.5, brightness * 0.88)),
            alpha: alpha
        )
    }

    private enum Edge {
        case top
        case right
        case bottom
        case left
    }

    private struct EdgeField {
        let edge: Edge
        let start: CGPoint
        let end: CGPoint
        let waveformRange: ClosedRange<Double>
        let colorOffset: Int
    }

    private struct WaveFlowParameters {
        let phase: Double
        let segmentLength: Double
    }

    private struct PerimeterSample {
        let point: CGPoint
        let normal: CGVector
        let position: Double
    }

    private struct WaveFlowPoint {
        let point: CGPoint
        let normal: CGVector
        let progress: CGFloat
        let widthScale: CGFloat
    }

    private func sideEdgeFields(in size: CGSize) -> [EdgeField] {
        guard size.width > 0, size.height > 0 else { return [] }
        return [
            EdgeField(edge: .right, start: CGPoint(x: size.width, y: 0),
                      end: CGPoint(x: size.width, y: size.height),
                      waveformRange: 0.3...0.5, colorOffset: 1),
            EdgeField(edge: .bottom, start: CGPoint(x: size.width, y: size.height),
                      end: CGPoint(x: 0, y: size.height),
                      waveformRange: 0.5...0.8, colorOffset: 2),
            EdgeField(edge: .left, start: CGPoint(x: 0, y: size.height), end: .zero,
                      waveformRange: 0.8...1.0, colorOffset: 3),
        ]
    }

    private func drawWaveBand(context: inout GraphicsContext, size: CGSize, fields: [EdgeField],
                              waveform: [Double], colors: [Color], baseDepth: CGFloat,
                              waveDepth: CGFloat, blur: CGFloat, opacity: Double) {
        guard !colors.isEmpty else { return }
        context.drawLayer { layer in
            layer.opacity = opacity
            if blur > 0 { layer.addFilter(.blur(radius: blur)) }
            layer.fill(topWaveBandPath(in: size, waveform: waveform,
                                       baseDepth: baseDepth, waveDepth: waveDepth),
                       with: .linearGradient(
                        Gradient(colors: [colors[0], colors[min(1, colors.count - 1)]]),
                        startPoint: .zero,
                        endPoint: CGPoint(x: size.width, y: 0)
                       ))
            for field in fields {
                let path = waveBandPath(for: field, waveform: waveform,
                                        baseDepth: baseDepth, waveDepth: waveDepth)
                layer.fill(path, with: .linearGradient(
                    Gradient(colors: [colors[field.colorOffset % colors.count],
                                      colors[(field.colorOffset + 1) % colors.count]]),
                    startPoint: field.start,
                    endPoint: field.end
                ))
            }
        }
    }

    private func drawWaveFlow(context: inout GraphicsContext, size: CGSize,
                              perimeter: [PerimeterSample],
                              colors: [Color],
                              waveform: [Double],
                              parameters: WaveFlowParameters,
                              coreWidth: CGFloat,
                              glowWidth: CGFloat,
                              glowBlur: CGFloat,
                              opacity: Double) {
        guard !colors.isEmpty else { return }
        let inset = coreWidth / 2
        let run = travelingWaveRun(perimeter: perimeter, inset: inset,
                                   parameters: parameters)
        guard run.count > 1 else { return }
        let profile = waveFlowProfile(run, waveform: waveform, phase: parameters.phase)
        let line = waveFlowLine(profile)
        let halo = waveFlowRibbon(profile, width: glowWidth)
        let bloom = waveFlowRibbon(profile, width: coreWidth * 2.3)
        let ribbon = waveFlowRibbon(profile, width: coreWidth)
        let shading = waveFlowShading(colors: colors, size: size, phase: parameters.phase)

        context.drawLayer { layer in
            layer.opacity = 0.42 * opacity
            layer.blendMode = .screen
            layer.addFilter(.blur(radius: glowBlur))
            layer.fill(halo, with: shading)
        }
        context.drawLayer { layer in
            layer.opacity = 0.62 * opacity
            layer.blendMode = .screen
            layer.addFilter(.blur(radius: max(0.8, coreWidth * 0.55)))
            layer.fill(bloom, with: shading)
        }
        context.drawLayer { layer in
            layer.opacity = 0.94 * opacity
            layer.blendMode = .normal
            layer.fill(ribbon, with: shading)
        }
        context.drawLayer { layer in
            layer.opacity = 0.28 * opacity
            layer.blendMode = .screen
            layer.stroke(
                line,
                with: shading,
                style: StrokeStyle(lineWidth: max(0.7, coreWidth * 0.24),
                                   lineCap: .round, lineJoin: .round)
            )
        }
    }

    private func waveFlowShading(colors: [Color], size: CGSize,
                              phase: Double) -> GraphicsContext.Shading {
        let first = colors[0]
        let second = colors[min(1, colors.count - 1)]
        let third = colors[min(2, colors.count - 1)]
        let fourth = colors[min(3, colors.count - 1)]
        let gradient = Gradient(colors: [first, second, third, fourth, first])
        return .conicGradient(
            gradient,
            center: CGPoint(x: size.width / 2, y: size.height / 2),
            angle: .radians(phase * 2 * .pi)
        )
    }

    private func travelingWaveRun(
        perimeter: [PerimeterSample],
        inset: CGFloat,
        parameters: WaveFlowParameters
    ) -> [WaveFlowPoint] {
        guard perimeter.count > 1 else { return [] }
        let segmentLength = max(0.04, parameters.segmentLength)
        let lower = parameters.phase - segmentLength
        let upper = parameters.phase
        var run: [(sample: PerimeterSample, position: Double)] = []

        for sample in perimeter {
            for offset in -1...1 {
                let position = sample.position + Double(offset)
                if position >= lower, position <= upper {
                    run.append((sample, position))
                }
            }
        }
        run.sort { $0.position < $1.position }
        guard !run.isEmpty else { return [] }

        var points: [(sample: PerimeterSample, position: Double)] = []
        points.append(interpolatedPerimeterSample(perimeter, at: lower))
        points.append(contentsOf: run.filter { $0.position > lower && $0.position < upper })
        points.append(interpolatedPerimeterSample(perimeter, at: upper))

        return points.map { entry in
            let progress = CGFloat((entry.position - lower) / segmentLength)
            return WaveFlowPoint(
                point: insetPoint(entry.sample, by: inset),
                normal: entry.sample.normal,
                progress: min(1, max(0, progress)),
                widthScale: 1
            )
        }
    }

    private func interpolatedPerimeterSample(
        _ perimeter: [PerimeterSample], at unwrappedPosition: Double
    ) -> (sample: PerimeterSample, position: Double) {
        let position = wrapped(unwrappedPosition)
        let upperIndex = perimeter.firstIndex { $0.position >= position } ?? 0
        let lowerIndex = upperIndex == 0 ? perimeter.count - 1 : upperIndex - 1
        let lower = perimeter[lowerIndex]
        let upper = perimeter[upperIndex]
        let lowerPosition = lower.position
        let upperPosition = upperIndex == 0 ? upper.position + 1 : upper.position
        let adjustedPosition = upperIndex == 0 && position < lowerPosition ? position + 1 : position
        let span = max(0.000_001, upperPosition - lowerPosition)
        let fraction = CGFloat((adjustedPosition - lowerPosition) / span)

        let point = CGPoint(
            x: lower.point.x + (upper.point.x - lower.point.x) * fraction,
            y: lower.point.y + (upper.point.y - lower.point.y) * fraction
        )
        let normal = normalized(CGVector(
            dx: lower.normal.dx + (upper.normal.dx - lower.normal.dx) * fraction,
            dy: lower.normal.dy + (upper.normal.dy - lower.normal.dy) * fraction
        ))
        return (PerimeterSample(point: point, normal: normal, position: position),
                unwrappedPosition)
    }

    private func waveFlowLine(_ run: [WaveFlowPoint]) -> Path {
        Path { path in
            path.move(to: run[0].point)
            for entry in run.dropFirst() {
                path.addLine(to: entry.point)
            }
        }
    }

    private func waveFlowRibbon(_ run: [WaveFlowPoint], width: CGFloat) -> Path {
        Path { path in
            for (index, entry) in run.enumerated() {
                let radius = width * 0.5 * entry.widthScale
                let point = offset(entry.point, along: entry.normal, by: radius)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }

            for entry in run.reversed() {
                let radius = width * 0.5 * entry.widthScale
                path.addLine(to: offset(entry.point, along: entry.normal, by: -radius))
            }
            path.closeSubpath()
        }
    }

    private func waveFlowEnvelope(_ progress: CGFloat) -> CGFloat {
        let tail = smoothstep(min(1, progress / 0.2))
        let head = smoothstep(min(1, (1 - progress) / 0.11))
        return min(tail, head)
    }

    private func waveFlowProfile(_ run: [WaveFlowPoint], waveform: [Double],
                                 phase: Double) -> [WaveFlowPoint] {
        run.map { point in
            let progress = Double(point.progress)
            let spacing = 0.018
            let audio = (
                waveformValue(waveform, at: max(0, progress - spacing))
                    + waveformValue(waveform, at: progress)
                    + waveformValue(waveform, at: min(1, progress + spacing))
            ) / 3
            let liquid = 0.5 + 0.5 * sin((progress * 7 - phase * 2) * 2 * .pi)
            let modulation = 0.82 + audio * 0.22 + liquid * 0.07
            return WaveFlowPoint(
                point: point.point,
                normal: point.normal,
                progress: point.progress,
                widthScale: waveFlowEnvelope(point.progress) * CGFloat(modulation)
            )
        }
    }

    private func offset(_ point: CGPoint, along vector: CGVector, by amount: CGFloat) -> CGPoint {
        CGPoint(x: point.x + vector.dx * amount, y: point.y + vector.dy * amount)
    }

    private func normalized(_ vector: CGVector) -> CGVector {
        let length = hypot(vector.dx, vector.dy)
        guard length > 0.000_001 else { return .zero }
        return CGVector(dx: vector.dx / length, dy: vector.dy / length)
    }

    private func insetPoint(_ sample: PerimeterSample, by amount: CGFloat) -> CGPoint {
        CGPoint(
            x: sample.point.x + sample.normal.dx * amount,
            y: sample.point.y + sample.normal.dy * amount
        )
    }

    private func perimeterSamples(in size: CGSize) -> [PerimeterSample] {
        guard size.width > 0, size.height > 0 else { return [] }
        let cornerRadius = min(24, max(12, min(size.width, size.height) * 0.02))
        var boundary = topBoundarySamples(
            in: size,
            from: cornerRadius,
            to: size.width - cornerRadius
        )
        appendInwardArc(to: &boundary,
                        center: CGPoint(x: size.width - cornerRadius, y: cornerRadius),
                        radius: cornerRadius, startAngle: -.pi / 2, endAngle: 0)
        appendLine(to: &boundary, from: CGPoint(x: size.width, y: cornerRadius),
                   to: CGPoint(x: size.width, y: size.height - cornerRadius),
                   normal: CGVector(dx: -1, dy: 0))
        appendInwardArc(to: &boundary,
                        center: CGPoint(x: size.width - cornerRadius,
                                        y: size.height - cornerRadius),
                        radius: cornerRadius, startAngle: 0, endAngle: .pi / 2)
        appendLine(to: &boundary, from: CGPoint(x: size.width - cornerRadius, y: size.height),
                   to: CGPoint(x: cornerRadius, y: size.height),
                   normal: CGVector(dx: 0, dy: -1))
        appendInwardArc(to: &boundary,
                        center: CGPoint(x: cornerRadius, y: size.height - cornerRadius),
                        radius: cornerRadius, startAngle: .pi / 2, endAngle: .pi)
        appendLine(to: &boundary, from: CGPoint(x: 0, y: size.height - cornerRadius),
                   to: CGPoint(x: 0, y: cornerRadius),
                   normal: CGVector(dx: 1, dy: 0))
        appendInwardArc(to: &boundary, center: CGPoint(x: cornerRadius, y: cornerRadius),
                        radius: cornerRadius, startAngle: .pi, endAngle: .pi * 1.5)

        if let first = boundary.first, let last = boundary.last,
           hypot(last.point.x - first.point.x, last.point.y - first.point.y) < 0.01 {
            boundary.removeLast()
        }
        guard boundary.count > 1 else { return [] }

        var distances = [Double](repeating: 0, count: boundary.count)
        for index in 1..<boundary.count {
            let previous = boundary[index - 1].point
            let current = boundary[index].point
            distances[index] = distances[index - 1]
                + Double(hypot(current.x - previous.x, current.y - previous.y))
        }
        let first = boundary[0].point
        let last = boundary[boundary.count - 1].point
        let total = distances[distances.count - 1]
            + Double(hypot(first.x - last.x, first.y - last.y))
        guard total > 0 else { return [] }

        return boundary.enumerated().map { index, sample in
            PerimeterSample(
                point: sample.point,
                normal: sample.normal,
                position: distances[index] / total
            )
        }
    }

    private struct BoundarySample {
        let point: CGPoint
        let normal: CGVector
    }

    private func topWaveBandPath(in size: CGSize, waveform: [Double],
                                 baseDepth: CGFloat, waveDepth: CGFloat) -> Path {
        let samples = topBoundarySamples(in: size)
        guard samples.count > 1 else { return Path() }

        return Path { path in
            path.move(to: samples[0].point)
            for sample in samples.dropFirst() { path.addLine(to: sample.point) }

            for (index, sample) in samples.enumerated().reversed() {
                let t = CGFloat(index) / CGFloat(samples.count - 1)
                let waveformPosition = Double(t) * 0.3
                let amplitude = CGFloat(waveformValue(waveform, at: waveformPosition))
                let depth = (baseDepth + waveDepth * amplitude)
                    * cornerFalloff(for: .top, at: t)
                path.addLine(to: CGPoint(
                    x: sample.point.x + sample.normal.dx * depth,
                    y: sample.point.y + sample.normal.dy * depth
                ))
            }
            path.closeSubpath()
        }
    }

    private func topBoundarySamples(in size: CGSize) -> [BoundarySample] {
        topBoundarySamples(in: size, from: 0, to: size.width)
    }

    private func topBoundarySamples(in size: CGSize, from startX: CGFloat,
                                    to endX: CGFloat) -> [BoundarySample] {
        guard let notch,
              notch.minX > startX,
              notch.maxX < endX,
              notch.depth > 0 else {
            return lineSamples(from: CGPoint(x: startX, y: 0),
                               to: CGPoint(x: endX, y: 0),
                               normal: CGVector(dx: 0, dy: 1))
        }

        let left = min(size.width, max(0, notch.minX))
        let right = min(size.width, max(left, notch.maxX))
        let bottom = min(size.height, max(0, notch.depth))
        let radius = min(notch.cornerRadius, bottom, (right - left) / 2)
        var samples: [BoundarySample] = []

        appendLine(to: &samples, from: CGPoint(x: startX, y: 0),
                   to: CGPoint(x: left, y: 0),
                   normal: CGVector(dx: 0, dy: 1))
        appendLine(to: &samples, from: CGPoint(x: left, y: 0),
                   to: CGPoint(x: left, y: bottom - radius),
                   normal: CGVector(dx: -1, dy: 0))
        appendArc(to: &samples, center: CGPoint(x: left + radius, y: bottom - radius),
                  radius: radius, startAngle: .pi, endAngle: .pi / 2)
        appendLine(to: &samples, from: CGPoint(x: left + radius, y: bottom),
                   to: CGPoint(x: right - radius, y: bottom),
                   normal: CGVector(dx: 0, dy: 1))
        appendArc(to: &samples, center: CGPoint(x: right - radius, y: bottom - radius),
                  radius: radius, startAngle: .pi / 2, endAngle: 0)
        appendLine(to: &samples, from: CGPoint(x: right, y: bottom - radius),
                   to: CGPoint(x: right, y: 0), normal: CGVector(dx: 1, dy: 0))
        appendLine(to: &samples, from: CGPoint(x: right, y: 0),
                   to: CGPoint(x: endX, y: 0), normal: CGVector(dx: 0, dy: 1))
        return samples
    }

    private func lineSamples(from start: CGPoint, to end: CGPoint,
                             normal: CGVector) -> [BoundarySample] {
        var samples: [BoundarySample] = []
        appendLine(to: &samples, from: start, to: end, normal: normal)
        return samples
    }

    private func appendLine(to samples: inout [BoundarySample], from start: CGPoint,
                            to end: CGPoint, normal: CGVector) {
        let length = hypot(end.x - start.x, end.y - start.y)
        let count = max(1, Int(length / 5))
        for index in 0...count {
            if !samples.isEmpty, index == 0 { continue }
            let t = CGFloat(index) / CGFloat(count)
            samples.append(BoundarySample(
                point: CGPoint(x: start.x + (end.x - start.x) * t,
                               y: start.y + (end.y - start.y) * t),
                normal: normal
            ))
        }
    }

    private func appendArc(to samples: inout [BoundarySample], center: CGPoint,
                           radius: CGFloat, startAngle: CGFloat, endAngle: CGFloat) {
        guard radius > 0 else { return }
        let count = max(4, Int(radius * abs(endAngle - startAngle) / 3))
        for index in 1...count {
            let t = CGFloat(index) / CGFloat(count)
            let angle = startAngle + (endAngle - startAngle) * t
            let normal = CGVector(dx: cos(angle), dy: sin(angle))
            samples.append(BoundarySample(
                point: CGPoint(x: center.x + normal.dx * radius,
                               y: center.y + normal.dy * radius),
                normal: normal
            ))
        }
    }

    private func appendInwardArc(to samples: inout [BoundarySample], center: CGPoint,
                                 radius: CGFloat, startAngle: CGFloat, endAngle: CGFloat) {
        let count = max(6, Int(radius * abs(endAngle - startAngle) / 3))
        for index in 1...count {
            let t = CGFloat(index) / CGFloat(count)
            let angle = startAngle + (endAngle - startAngle) * t
            let radial = CGVector(dx: cos(angle), dy: sin(angle))
            samples.append(BoundarySample(
                point: CGPoint(x: center.x + radial.dx * radius,
                               y: center.y + radial.dy * radius),
                normal: CGVector(dx: -radial.dx, dy: -radial.dy)
            ))
        }
    }

    private func waveBandPath(for field: EdgeField, waveform: [Double],
                              baseDepth: CGFloat, waveDepth: CGFloat) -> Path {
        let edgeLength = hypot(field.end.x - field.start.x, field.end.y - field.start.y)
        let pointCount = max(48, min(260, Int(edgeLength / 6)))
        return Path { path in
            path.move(to: field.start)
            path.addLine(to: field.end)
            for index in stride(from: pointCount, through: 0, by: -1) {
                let t = CGFloat(index) / CGFloat(pointCount)
                let position = field.waveformRange.lowerBound
                    + (field.waveformRange.upperBound - field.waveformRange.lowerBound) * Double(t)
                let sample = CGFloat(waveformValue(waveform, at: position))
                let depth = (baseDepth + waveDepth * sample) * cornerFalloff(for: field.edge, at: t)
                let edgePoint = CGPoint(
                    x: field.start.x + (field.end.x - field.start.x) * t,
                    y: field.start.y + (field.end.y - field.start.y) * t
                )
                path.addLine(to: insetPoint(from: edgePoint, on: field.edge, by: depth))
            }
            path.closeSubpath()
        }
    }

    private func cornerFalloff(for edge: Edge, at position: CGFloat) -> CGFloat {
        switch edge {
        case .top:
            let nearestEnd = min(position, 1 - position)
            return 0.38 + 0.62 * smoothstep(min(1, nearestEnd / 0.018))
        case .right:
            return 0.45 + 0.55 * smoothstep(min(1, position / 0.025))
        case .left:
            return 0.45 + 0.55 * smoothstep(min(1, (1 - position) / 0.025))
        case .bottom:
            return 1
        }
    }

    private func insetPoint(from point: CGPoint, on edge: Edge, by depth: CGFloat) -> CGPoint {
        switch edge {
        case .top: return CGPoint(x: point.x, y: point.y + depth)
        case .right: return CGPoint(x: point.x - depth, y: point.y)
        case .bottom: return CGPoint(x: point.x, y: point.y - depth)
        case .left: return CGPoint(x: point.x + depth, y: point.y)
        }
    }

    private func smoothstep(_ value: CGFloat) -> CGFloat {
        value * value * (3 - 2 * value)
    }

    private func wrapped(_ value: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: 1)
        return remainder >= 0 ? remainder : remainder + 1
    }

    private func waveformValue(_ waveform: [Double], at position: Double) -> Double {
        guard waveform.count > 1 else { return 0 }
        let scaled = min(1, max(0, position)) * Double(waveform.count - 1)
        let lower = Int(scaled.rounded(.down))
        let upper = min(waveform.count - 1, lower + 1)
        let fraction = scaled - Double(lower)
        return waveform[lower] * (1 - fraction) + waveform[upper] * fraction
    }
}
