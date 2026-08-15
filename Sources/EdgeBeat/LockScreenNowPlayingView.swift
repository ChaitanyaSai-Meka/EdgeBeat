import SwiftUI

struct LockScreenNowPlayingView: View {
    @ObservedObject var renderState: RenderState
    let onPlaybackCommand: (PlaybackCommand, PlayerSource) -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)

        HStack(spacing: 18) {
            artwork
                .frame(width: 112, height: 112)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(.white.opacity(0.18), lineWidth: 1)
                }
                .shadow(color: accent.opacity(0.25), radius: 14, y: 6)

            VStack(alignment: .leading, spacing: 8) {
                Text(track.title)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)

                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(accent)
                    .animation(.linear(duration: 1.2), value: progress)

                HStack(spacing: 22) {
                    controlButton(.previousTrack, icon: "backward.fill", label: "Previous")
                    controlButton(
                        .togglePlayPause,
                        icon: track.state == .playing ? "pause.fill" : "play.fill",
                        label: track.state == .playing ? "Pause" : "Play",
                        isPrimary: true
                    )
                    controlButton(.nextTrack, icon: "forward.fill", label: "Next")
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(18)
        .background(.ultraThinMaterial, in: shape)
        .background {
            shape
                .fill(accent.opacity(0.1))
                .blendMode(.plusLighter)
        }
        .overlay {
            shape.stroke(
                LinearGradient(
                    colors: [.white.opacity(0.42), .white.opacity(0.08), accent.opacity(0.24)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
        }
        .overlay(alignment: .top) {
            Capsule()
                .fill(.white.opacity(0.24))
                .frame(width: 120, height: 1)
                .padding(.top, 2)
        }
        .shadow(color: accent.opacity(0.16), radius: 28, y: 10)
        .shadow(color: .black.opacity(0.32), radius: 22, y: 12)
        .padding(5)
    }

    private var track: NowPlayingTrack {
        renderState.track
    }

    private var accent: Color {
        renderState.palette.swiftUIColors.first ?? .white
    }

    private var subtitle: String {
        track.album.isEmpty ? track.artist : "\(track.artist) - \(track.album)"
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
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func controlButton(_ command: PlaybackCommand, icon: String, label: String,
                               isPrimary: Bool = false) -> some View {
        Button {
            onPlaybackCommand(command, track.source)
        } label: {
            Image(systemName: icon)
                .font(.system(size: isPrimary ? 17 : 13, weight: .semibold))
                .foregroundStyle(isPrimary ? Color.black : Color.white)
                .frame(width: isPrimary ? 42 : 34, height: isPrimary ? 42 : 34)
                .background {
                    if isPrimary {
                        Circle().fill(accent.opacity(0.94))
                    } else {
                        Circle().fill(.thinMaterial)
                    }
                }
                .overlay {
                    Circle().stroke(.white.opacity(isPrimary ? 0.28 : 0.16), lineWidth: 1)
                }
                .clipShape(Circle())
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
}
