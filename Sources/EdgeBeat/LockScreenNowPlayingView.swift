import SwiftUI

struct LockScreenNowPlayingView: View {
    @ObservedObject var renderState: RenderState
    let onPlaybackCommand: (PlaybackCommand, PlayerSource) -> Void

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
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(accent)
                        .animation(.linear(duration: 1), value: progress)

                    HStack {
                        Text(formatTime(track.position))
                        Spacer()
                        Text("-\(formatTime(max(0, track.duration - track.position)))")
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
        .background(.ultraThinMaterial, in: shape)
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
                    colors: [.white.opacity(0.5), .white.opacity(0.1), accent.opacity(0.3)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
        }
        .overlay(alignment: .top) {
            Capsule()
                .fill(.white.opacity(0.28))
                .frame(width: 150, height: 1)
                .padding(.top, 2)
        }
        .shadow(color: accent.opacity(0.18), radius: 30, y: 12)
        .shadow(color: .black.opacity(0.34), radius: 24, y: 14)
        .padding(6)
    }

    private var track: NowPlayingTrack {
        renderState.track
    }

    private var accent: Color {
        renderState.palette.swiftUIColors.first ?? .white
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
                .foregroundStyle(isPrimary ? Color.black : (isActive ? accent : Color.white))
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

    private var progress: Double {
        guard track.duration > 0 else { return 0 }
        return min(1, max(0, track.position / track.duration))
    }

    private func formatTime(_ value: TimeInterval) -> String {
        guard value.isFinite, value >= 0 else { return "0:00" }
        let totalSeconds = Int(value.rounded(.down))
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }
}
