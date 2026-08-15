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
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let breathe = 0.5 + 0.5 * sin(t * (2 * .pi / 5.0))
            let gradientPhase = Angle.degrees((t * 3).truncatingRemainder(dividingBy: 360))

            glow(breathe: breathe, colors: renderState.palette.swiftUIColors, phase: gradientPhase)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func glow(breathe: Double, colors: [Color], phase: Angle) -> some View {
        let idleLevel = renderState.isPlaying ? 0.12 : 0.05 + 0.05 * breathe
        let audioLevel = renderState.isPlaying ? renderState.level * 0.88 : 0
        let beatBoost = renderState.beat ? 0.22 : 0
        let level = min(1, idleLevel + audioLevel + beatBoost) * settings.intensity
        let shape = RoundedRectangle(cornerRadius: 34, style: .continuous).inset(by: 3)
        let gradient = AngularGradient(
            gradient: Gradient(colors: colors),
            center: .center,
            startAngle: phase,
            endAngle: .degrees(phase.degrees + 360)
        )
        let bloom = renderState.beat ? 1.25 : 1

        ZStack {
            shape.stroke(gradient, lineWidth: 22 * bloom).blur(radius: 28).opacity(0.48 * level)
            shape.stroke(gradient, lineWidth: 10 * bloom).blur(radius: 12).opacity(0.72 * level)
            shape.stroke(gradient, lineWidth: 2.5).blur(radius: 1.5).opacity(0.90 * level)
        }
        .drawingGroup(opaque: false, colorMode: .extendedLinear)
        .blendMode(.screen)
        .animation(.easeOut(duration: 0.18), value: renderState.beat)
        .animation(.easeInOut(duration: 1.1), value: renderState.trackTitle)
    }
}
