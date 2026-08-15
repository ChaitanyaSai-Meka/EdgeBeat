import SwiftUI

struct LockScreenNowPlayingView: View {
    @ObservedObject var renderState: RenderState
    let onPlaybackCommand: (PlaybackCommand, PlayerSource) -> Void

    var body: some View {
        HStack(spacing: 14) {
            artwork
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(track.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)

                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(accent)
                    .animation(.linear(duration: 1.2), value: progress)

                HStack(spacing: 18) {
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
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
        .padding(4)
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
                .font(.system(size: isPrimary ? 15 : 12, weight: .semibold))
                .foregroundStyle(isPrimary ? Color.black : Color.white)
                .frame(width: isPrimary ? 32 : 26, height: isPrimary ? 32 : 26)
                .background(isPrimary ? accent : Color.white.opacity(0.1))
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
