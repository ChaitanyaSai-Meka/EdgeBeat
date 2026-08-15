import SwiftUI

/// Live-adjustable glow settings shared between the menu and SwiftUI view.
final class GlowSettings: ObservableObject {
    @Published var intensity: Double

    init(intensity: Double = 0.85) {
        self.intensity = intensity
    }
}

struct EdgeGlowView: View {
    @ObservedObject var settings: GlowSettings
    @ObservedObject var renderState: RenderState

    var body: some View {
        glow(colors: renderState.palette.swiftUIColors)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func glow(colors: [Color]) -> some View {
        let idleLevel = renderState.isPlaying ? 0.14 : 0.08
        let audioLevel = renderState.isPlaying ? renderState.level * 0.86 : 0
        let beatBoost = renderState.beat ? 0.18 : 0
        let level = min(1, idleLevel + audioLevel + beatBoost) * settings.intensity
        let waveDepth = CGFloat(7 + renderState.level * 17 + (renderState.beat ? 5 : 0))
        let bloom = renderState.beat ? 1.12 : 1

        Canvas(opaque: false, colorMode: .extendedLinear, rendersAsynchronously: true) { context, size in
            let waveform = renderState.waveform
            let fields = edgeFields(in: size)

            drawWaveBand(context: &context, fields: fields, waveform: waveform, colors: colors,
                         baseDepth: 15 * bloom, waveDepth: waveDepth * 1.2,
                         blur: 20, opacity: 0.36 * level)
            drawWaveBand(context: &context, fields: fields, waveform: waveform, colors: colors,
                         baseDepth: 7 * bloom, waveDepth: waveDepth * 0.72,
                         blur: 7, opacity: 0.62 * level)
            drawWaveBand(context: &context, fields: fields, waveform: waveform, colors: colors,
                         baseDepth: 2.2, waveDepth: waveDepth * 0.24,
                         blur: 1.2, opacity: 0.94 * level)
        }
        .blendMode(.screen)
        .animation(.easeOut(duration: 0.16), value: renderState.beat)
        .animation(.easeInOut(duration: 0.9), value: renderState.trackTitle)
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
            EdgeField(edge: .top,
                      start: CGPoint(x: 0, y: 0),
                      end: CGPoint(x: size.width, y: 0),
                      waveformRange: 0.0...0.3,
                      colorOffset: 0),
            EdgeField(edge: .right,
                      start: CGPoint(x: size.width, y: 0),
                      end: CGPoint(x: size.width, y: size.height),
                      waveformRange: 0.3...0.5,
                      colorOffset: 1),
            EdgeField(edge: .bottom,
                      start: CGPoint(x: size.width, y: size.height),
                      end: CGPoint(x: 0, y: size.height),
                      waveformRange: 0.5...0.8,
                      colorOffset: 2),
            EdgeField(edge: .left,
                      start: CGPoint(x: 0, y: size.height),
                      end: CGPoint(x: 0, y: 0),
                      waveformRange: 0.8...1.0,
                      colorOffset: 3),
        ]
    }

    private func drawWaveBand(context: inout GraphicsContext, fields: [EdgeField],
                              waveform: [Double], colors: [Color],
                              baseDepth: CGFloat, waveDepth: CGFloat,
                              blur: CGFloat, opacity: Double) {
        guard !colors.isEmpty else { return }

        context.drawLayer { layer in
            layer.opacity = opacity
            if blur > 0 { layer.addFilter(.blur(radius: blur)) }

            for field in fields {
                let path = waveBandPath(for: field, waveform: waveform,
                                        baseDepth: baseDepth, waveDepth: waveDepth)
                let startColor = colors[field.colorOffset % colors.count]
                let endColor = colors[(field.colorOffset + 1) % colors.count]
                layer.fill(path, with: .linearGradient(
                    Gradient(colors: [startColor, endColor]),
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
                let cornerScale = cornerFalloff(for: field.edge, at: t)
                let depth = (baseDepth + waveDepth * sample) * cornerScale
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
            // The top light eases into the side emitters, matching the softened
            // upper corners of a Mac display without drawing a rounded frame.
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
