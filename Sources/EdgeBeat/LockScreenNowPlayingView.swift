import SwiftUI

struct LockScreenNowPlayingView: View {
    @ObservedObject var renderState: RenderState
    let onPlaybackCommand: (PlaybackCommand, PlayerSource) -> Void
    let onSeek: (TimeInterval, PlayerSource) -> Void

    @State private var scrubFraction: Double?
    @State private var pendingSeekTarget: TimeInterval?
    @State private var pendingSeekGeneration: UInt64 = 0

    private static let pendingSeekTimeout: TimeInterval = 2

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)

        HStack(spacing: 20) {
            artwork
                .frame(width: 124, height: 124)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(.white.opacity(0.2), lineWidth: 1)
                }
                .shadow(color: accent.opacity(0.3), radius: 16, y: 7)

            VStack(alignment: .leading, spacing: 7) {
                Text(track.title)
                    .font(.system(size: 18, weight: .semibold))
                    .lineLimit(1)

                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                VStack(spacing: 3) {
                    seekBar

                    HStack {
                        Text(formatTime(displayedPosition))
                        Spacer()
                        Text("-\(formatTime(max(0, track.duration - displayedPosition)))")
                    }
                    .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.tertiary)
                }

                HStack(spacing: 17) {
                    controlButton(
                        .toggleShuffle,
                        icon: "shuffle",
                        label: track.isShuffleEnabled ? "Turn Shuffle Off" : "Turn Shuffle On",
                        isActive: track.isShuffleEnabled
                    )
                    controlButton(.previousTrack, icon: "backward.fill", label: "Previous")
                    controlButton(
                        .togglePlayPause,
                        icon: track.state == .playing ? "pause.fill" : "play.fill",
                        label: track.state == .playing ? "Pause" : "Play",
                        isPrimary: true
                    )
                    controlButton(.nextTrack, icon: "forward.fill", label: "Next")
                    outputRoute
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(18)
        .background(.thickMaterial, in: shape)
        .background {
            shape
                .fill(
                    LinearGradient(
                        colors: [accent.opacity(0.16), .clear, accent.opacity(0.06)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .blendMode(.plusLighter)
        }
        .overlay {
            shape.stroke(
                LinearGradient(
                    colors: [.white.opacity(0.16), .white.opacity(0.06), accent.opacity(0.1)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
        }
        .shadow(color: .black.opacity(0.28), radius: 14, y: 8)
        .padding(4)
        .onChange(of: track.position) { _, position in
            reconcilePendingSeek(with: position)
        }
        .onChange(of: track.identifier) { _, _ in
            scrubFraction = nil
            pendingSeekTarget = nil
            pendingSeekGeneration &+= 1
        }
    }

    private var track: NowPlayingTrack {
        renderState.track
    }

    private var accent: Color {
        renderState.palette.swiftUIColors.first ?? .white
    }

    private var primaryControlForeground: Color {
        let color = renderState.palette.accent
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return .black }
        let luminance = 0.2126 * rgb.redComponent
            + 0.7152 * rgb.greenComponent
            + 0.0722 * rgb.blueComponent
        return luminance > 0.58 ? .black : .white
    }

    private var subtitle: String {
        if track.artist.isEmpty { return track.album }
        if track.album.isEmpty { return track.artist }
        return "\(track.artist) - \(track.album)"
    }

    private var outputRoute: some View {
        Image(systemName: renderState.audioOutputRoute.kind.symbolName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 34, height: 34)
        .background(.thinMaterial, in: Circle())
        .overlay { Circle().stroke(.white.opacity(0.15), lineWidth: 1) }
        .help("Playing on \(renderState.audioOutputRoute.name)")
        .accessibilityLabel("Playing on \(renderState.audioOutputRoute.name)")
    }

    @ViewBuilder
    private var artwork: some View {
        if let image = track.artwork {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Color.white.opacity(0.08)
                Image(systemName: "music.note")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func controlButton(
        _ command: PlaybackCommand,
        icon: String,
        label: String,
        isPrimary: Bool = false,
        isActive: Bool = false
    ) -> some View {
        Button {
            onPlaybackCommand(command, track.source)
        } label: {
            Image(systemName: icon)
                .font(.system(size: isPrimary ? 17 : 13, weight: .semibold))
                .foregroundStyle(isPrimary ? primaryControlForeground : (isActive ? accent : Color.white))
                .frame(width: isPrimary ? 44 : 34, height: isPrimary ? 44 : 34)
                .background {
                    Circle().fill(isPrimary ? AnyShapeStyle(accent.opacity(0.96)) : AnyShapeStyle(.thinMaterial))
                }
                .overlay {
                    Circle().stroke(
                        isActive ? accent.opacity(0.7) : .white.opacity(isPrimary ? 0.3 : 0.15),
                        lineWidth: 1
                    )
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private var canSeek: Bool {
        (track.source == .spotify || track.source == .music)
            && track.duration.isFinite
            && track.duration > 0
    }

    private var displayedPosition: TimeInterval {
        let position: TimeInterval
        if let scrubFraction, track.duration > 0 {
            position = scrubFraction * track.duration
        } else {
            position = pendingSeekTarget ?? track.position
        }
        guard position.isFinite else { return 0 }
        guard track.duration.isFinite, track.duration > 0 else { return max(0, position) }
        return min(track.duration, max(0, position))
    }

    private var displayedProgress: Double {
        guard canSeek else { return 0 }
        return min(1, max(0, displayedPosition / track.duration))
    }

    private var seekBar: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let knobSide: CGFloat = 10

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.18))
                    .frame(height: 4)

                Capsule()
                    .fill(accent)
                    .frame(width: width * displayedProgress, height: 4)

                if scrubFraction != nil {
                    Circle()
                        .fill(.white)
                        .frame(width: knobSide, height: knobSide)
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                        .offset(
                            x: min(
                                max(0, width * displayedProgress - knobSide / 2),
                                max(0, width - knobSide)
                            )
                        )
                }
            }
            .frame(width: width, height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(seekGesture(width: width), including: canSeek ? .all : .none)
        }
        .frame(height: 14)
        .accessibilityLabel("Playback position")
        .accessibilityValue(formatTime(displayedPosition))
        .accessibilityAdjustableAction { direction in
            let offset: TimeInterval = direction == .increment ? 10 : -10
            commitSeek(to: displayedPosition + offset)
        }
    }

    private func seekGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard canSeek else { return }
                scrubFraction = seekFraction(atX: value.location.x, width: width)
            }
            .onEnded { value in
                guard canSeek else {
                    scrubFraction = nil
                    return
                }
                let fraction = seekFraction(atX: value.location.x, width: width)
                commitSeek(to: fraction * track.duration)
            }
    }

    private func seekFraction(atX x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return min(1, max(0, Double(x / width)))
    }

    private func commitSeek(to position: TimeInterval) {
        guard canSeek, position.isFinite else { return }
        let target = min(track.duration, max(0, position))
        scrubFraction = nil
        pendingSeekTarget = target
        pendingSeekGeneration &+= 1
        let generation = pendingSeekGeneration
        onSeek(target, track.source)

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pendingSeekTimeout) {
            guard pendingSeekGeneration == generation else { return }
            pendingSeekTarget = nil
        }
    }

    private func reconcilePendingSeek(with position: TimeInterval) {
        guard let target = pendingSeekTarget, position.isFinite else { return }
        let tolerance = max(2, track.duration * 0.01)
        guard abs(position - target) <= tolerance else { return }
        pendingSeekTarget = nil
    }

    private func formatTime(_ value: TimeInterval) -> String {
        guard value.isFinite, value >= 0 else { return "0:00" }
        let totalSeconds = Int(value.rounded(.down))
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }
}
