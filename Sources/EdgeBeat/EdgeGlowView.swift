import SwiftUI

struct EdgeGlowView: View {
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var renderState: RenderState

    var body: some View {
        edgeEffect
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var edgeEffect: some View {
        if preferences.animationMode == .ambient {
            TimelineView(.periodic(from: .now, by: 1.0 / 24.0)) { timeline in
                glow(time: timeline.date.timeIntervalSinceReferenceDate)
            }
        } else {
            glow(time: nil)
        }
    }

    private func glow(time: TimeInterval?) -> some View {
        let mode = preferences.animationMode
        let ambientPulse = time.map { 0.5 + 0.5 * sin($0 * 0.9) } ?? 0.5
        let level: Double
        let waveform: [Double]
        let waveDepth: CGFloat
        let beatBloom: CGFloat

        switch mode {
        case .musicSync:
            let idle = renderState.isPlaying ? 0.14 : 0.08
            let audio = renderState.isPlaying ? renderState.level * 0.86 : 0
            level = min(1, idle + audio + (renderState.beat ? 0.18 : 0))
            waveform = renderState.waveform
            waveDepth = CGFloat(7 + renderState.level * 17 + (renderState.beat ? 5 : 0))
            beatBloom = renderState.beat ? 1.12 : 1
        case .ambient:
            level = 0.42 + ambientPulse * 0.12
            waveform = ambientWaveform(at: time ?? 0)
            waveDepth = 10
            beatBloom = 1
        case .static:
            level = 0.46
            waveform = []
            waveDepth = 0
            beatBloom = 1
        }

        let opacity = level * preferences.intensity
        let thicknessScale = CGFloat(0.3 + preferences.thickness * 1.7)
        let colors = activeColors

        return Canvas(opaque: false, colorMode: .extendedLinear, rendersAsynchronously: true) { context, size in
            let fields = edgeFields(in: size)
            drawWaveBand(context: &context, fields: fields, waveform: waveform, colors: colors,
                         baseDepth: 15 * thicknessScale * beatBloom,
                         waveDepth: waveDepth * 1.2 * thicknessScale,
                         blur: 20 * thicknessScale, opacity: 0.36 * opacity)
            drawWaveBand(context: &context, fields: fields, waveform: waveform, colors: colors,
                         baseDepth: 7 * thicknessScale * beatBloom,
                         waveDepth: waveDepth * 0.72 * thicknessScale,
                         blur: 7 * thicknessScale, opacity: 0.62 * opacity)
            drawWaveBand(context: &context, fields: fields, waveform: waveform, colors: colors,
                         baseDepth: max(1, 2.2 * thicknessScale),
                         waveDepth: waveDepth * 0.24 * thicknessScale,
                         blur: max(0.6, 1.2 * thicknessScale), opacity: 0.94 * opacity)
        }
        .blendMode(.screen)
        .animation(.easeOut(duration: 0.16), value: renderState.beat)
        .animation(.easeInOut(duration: 0.7), value: renderState.trackTitle)
    }

    private var activeColors: [Color] {
        if preferences.colorSource == .album {
            return renderState.palette.swiftUIColors
        }
        let primary = Color(nsColor: preferences.primaryColor)
        guard preferences.colorMode == .gradient else {
            return [primary, primary, primary, primary]
        }
        let secondary = Color(nsColor: preferences.secondaryColor)
        return [primary, secondary, primary, secondary]
    }

    private func ambientWaveform(at time: TimeInterval) -> [Double] {
        (0..<192).map { index in
            let position = Double(index) / 191
            let broad = sin(position * .pi * 10 + time * 0.72)
            let detail = sin(position * .pi * 26 - time * 0.43)
            return min(1, max(0, 0.48 + broad * 0.22 + detail * 0.1))
        }
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

    private func edgeFields(in size: CGSize) -> [EdgeField] {
        guard size.width > 0, size.height > 0 else { return [] }
        return [
            EdgeField(edge: .top, start: .zero, end: CGPoint(x: size.width, y: 0),
                      waveformRange: 0.0...0.3, colorOffset: 0),
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

    private func drawWaveBand(context: inout GraphicsContext, fields: [EdgeField],
                              waveform: [Double], colors: [Color], baseDepth: CGFloat,
                              waveDepth: CGFloat, blur: CGFloat, opacity: Double) {
        guard !colors.isEmpty else { return }
        context.drawLayer { layer in
            layer.opacity = opacity
            if blur > 0 { layer.addFilter(.blur(radius: blur)) }
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

    private func waveformValue(_ waveform: [Double], at position: Double) -> Double {
        guard waveform.count > 1 else { return 0 }
        let scaled = min(1, max(0, position)) * Double(waveform.count - 1)
        let lower = Int(scaled.rounded(.down))
        let upper = min(waveform.count - 1, lower + 1)
        let fraction = scaled - Double(lower)
        return waveform[lower] * (1 - fraction) + waveform[upper] * fraction
    }
}
