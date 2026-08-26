import SwiftUI

struct CompanionNowPlayingView: View {
    @ObservedObject var renderState: RenderState
    let onPlaybackCommand: (PlaybackCommand, PlayerSource) -> Void
    let onSeek: (TimeInterval, PlayerSource) -> Void

    @State private var scrubFraction: Double?
    @State private var isBarHovered = false
    @State private var anchorPosition: TimeInterval = 0
    @State private var anchorDate: Date?
    @State private var pendingSeekTarget: TimeInterval?
    @State private var backdropImage: NSImage?
    @State private var backdropIdentifier = ""

    private static let contentMaxWidth: CGFloat = 760
    private static let horizontalInset: CGFloat = 40
    private static let artworkMaxSide: CGFloat = 500
    private static let artworkMinSide: CGFloat = 150
    private static let headerHeight: CGFloat = 78
    private static let controlsHeight: CGFloat = 112
    private static let metadataHeight: CGFloat = 180
    private static let progressHeight: CGFloat = 64

    private struct LayoutMetrics {
        let artworkMinSide: CGFloat
        let metadataHeight: CGFloat
        let controlsHeight: CGFloat
        let progressHeight: CGFloat
        let isCompact: Bool
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                background
                header.frame(height: Self.headerHeight, alignment: .top)

                if track.state == .unavailable {
                    unavailableContent
                        .frame(
                            width: proxy.size.width,
                            height: max(0, proxy.size.height - Self.headerHeight),
                            alignment: .center
                        )
                        .offset(y: Self.headerHeight)
                } else {
                    playerLayout(in: proxy.size)
                        .offset(y: Self.headerHeight)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .preferredColorScheme(.dark)
        .onChange(of: track.position, initial: true) { _, newValue in
            if let pendingSeekTarget {
                let tolerance = max(2, track.duration * 0.01)
                guard abs(newValue - pendingSeekTarget) <= tolerance else { return }
                self.pendingSeekTarget = nil
            }
            anchorPosition = newValue
            anchorDate = Date()
        }
        .onChange(of: track.state) { _, _ in
            anchorPosition = track.position
            anchorDate = Date()
        }
        .onChange(of: track.identifier) { _, _ in
            scrubFraction = nil
            isBarHovered = false
            pendingSeekTarget = nil
            updateBackdrop()
        }
        .onChange(of: track.artwork != nil) { _, _ in
            updateBackdrop()
        }
        .onAppear { updateBackdrop() }
    }

    private var track: NowPlayingTrack {
        renderState.track
    }

    private var accent: Color {
        Color(nsColor: renderState.palette.accent)
    }

    private var canControlPlayback: Bool {
        track.source == .spotify || track.source == .music
    }

    private var canSeek: Bool {
        canControlPlayback && track.duration > 0
    }

    private var background: some View {
        ZStack {
            Color(nsColor: renderState.palette.background)
                .ignoresSafeArea()

            if let backdropImage {
                Image(nsImage: backdropImage)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 48)
                    .opacity(0.22)
                    .ignoresSafeArea()
            }

            Color.black.opacity(0.58)
                .ignoresSafeArea()
        }
    }

    private func updateBackdrop() {
        guard backdropIdentifier != track.identifier || backdropImage == nil else { return }
        backdropIdentifier = track.identifier
        guard let artwork = track.artwork else {
            backdropImage = nil
            return
        }
        backdropImage = Self.makeBackdropImage(from: artwork)
    }

    private static func makeBackdropImage(from artwork: NSImage) -> NSImage? {
        let targetSize = NSSize(width: 320, height: 320)
        let image = NSImage(size: targetSize)
        image.lockFocus()
        artwork.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        image.unlockFocus()
        return image
    }

    private var header: some View {
        HStack(spacing: 12) {
            Label {
                Text("EdgeBeat")
                    .font(.system(size: 13, weight: .semibold))
            } icon: {
                Image(systemName: "waveform")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(accent)
            }

            if track.state != .unavailable {
                sourceStatus
            }

            Spacer()

            if track.state != .unavailable {
                routeSummary
            }
        }
        .padding(.horizontal, 34)
        .padding(.top, 26)
        .padding(.bottom, 18)
        .layoutPriority(1)
    }

    private var sourceStatus: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(track.state == .playing ? accent : Color.secondary)
                .frame(width: 6, height: 6)
                .shadow(
                    color: track.state == .playing ? accent.opacity(0.65) : .clear,
                    radius: 5
                )

            Text(sourceName)

            Text("\u{00B7}")
                .foregroundStyle(.tertiary)

            Text(playbackStatus)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 11)
        .frame(height: 28)
        .background(.thinMaterial, in: Capsule())
        .overlay {
            Capsule().stroke(.white.opacity(0.12), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var routeSummary: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 7) {
                Image(systemName: renderState.audioOutputRoute.kind.symbolName)
                Text(renderState.audioOutputRoute.name)
                    .lineLimit(1)
            }
            .frame(maxWidth: 230, alignment: .trailing)

            Image(systemName: renderState.audioOutputRoute.kind.symbolName)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .help("Playing on \(renderState.audioOutputRoute.name)")
        .accessibilityLabel("Playing on \(renderState.audioOutputRoute.name)")
    }

    private func playerLayout(in size: CGSize) -> some View {
        let playerHeight = max(0, size.height - Self.headerHeight)
        let metrics = layoutMetrics(for: playerHeight)
        let columnWidth = min(
            Self.contentMaxWidth,
            max(0, size.width - Self.horizontalInset * 2)
        )
        let artworkAvailableHeight = max(
            metrics.artworkMinSide,
            playerHeight - metrics.controlsHeight - metrics.metadataHeight - metrics.progressHeight
        )
        let artworkSide = min(
            Self.artworkMaxSide,
            max(metrics.artworkMinSide, min(columnWidth, artworkAvailableHeight))
        )

        return VStack(spacing: 0) {
            Spacer(minLength: 0)

            artworkView(size: artworkSide)

            metadata(isCompact: metrics.isCompact)
                .padding(.top, metrics.isCompact ? 10 : 18)
                .frame(height: metrics.metadataHeight, alignment: .top)

            progress
                .frame(height: metrics.progressHeight)

            Spacer(minLength: 0)

            controls(isCompact: metrics.isCompact)
                .frame(height: metrics.controlsHeight, alignment: .top)
        }
        .frame(width: columnWidth, height: playerHeight)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func layoutMetrics(for playerHeight: CGFloat) -> LayoutMetrics {
        let isCompact = playerHeight < 560
        return LayoutMetrics(
            artworkMinSide: isCompact ? 112 : Self.artworkMinSide,
            metadataHeight: isCompact ? 142 : Self.metadataHeight,
            controlsHeight: isCompact ? 96 : Self.controlsHeight,
            progressHeight: isCompact ? 58 : Self.progressHeight,
            isCompact: isCompact
        )
    }

    private var unavailableContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note")
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(accent)
            Text("No music is playing")
                .font(.system(size: 24, weight: .semibold))
            Text("Start Spotify or Apple Music to see the current track here.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func artworkView(size: CGFloat) -> some View {
        if let artwork = track.artwork {
            Image(nsImage: artwork)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .background(.black.opacity(0.24))
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(.white.opacity(0.22), lineWidth: 1)
                }
                .shadow(color: accent.opacity(0.42), radius: 34, y: 18)
        } else {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.white.opacity(0.08))
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 52, weight: .medium))
                        .foregroundStyle(.secondary)
                }
        }
    }

    private func metadata(isCompact: Bool) -> some View {
        VStack(spacing: 7) {
            liveWaveform
                .frame(height: isCompact ? 24 : 34)
                .padding(.bottom, isCompact ? 2 : 5)

            Text(track.title)
                .font(.system(size: isCompact ? 27 : 34, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(isCompact ? 0.6 : 0.68)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            Text(track.artist.isEmpty ? track.album : track.artist)
                .font(.system(size: isCompact ? 16 : 19, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .multilineTextAlignment(.center)

            if !track.album.isEmpty, !track.artist.isEmpty {
                Text(track.album)
                    .font(.system(size: isCompact ? 12 : 14))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var liveWaveform: some View {
        Canvas { context, size in
            let samples = downsampledWaveform
            guard !samples.isEmpty else { return }

            let centerY = size.height / 2
            let step = samples.count > 1 ? size.width / CGFloat(samples.count - 1) : size.width
            let upperPoints = samples.enumerated().map { index, sample in
                let x = CGFloat(index) * step
                let amplitude = CGFloat(sample) * size.height * waveformAmplitude
                return CGPoint(x: x, y: centerY - amplitude)
            }
            let lowerPoints = samples.enumerated().map { index, sample in
                let x = CGFloat(index) * step
                let amplitude = CGFloat(sample) * size.height * waveformAmplitude
                return CGPoint(x: x, y: centerY + amplitude)
            }
            let upperPath = smoothWaveformPath(through: upperPoints)
            let lowerPath = smoothWaveformPath(through: lowerPoints)

            let strokeStyle = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
            let gradient = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [accent.opacity(0.22), accent, accent.opacity(0.22)]),
                startPoint: .zero,
                endPoint: CGPoint(x: size.width, y: 0)
            )
            context.stroke(
                upperPath,
                with: gradient,
                style: strokeStyle
            )
            context.stroke(
                lowerPath,
                with: gradient,
                style: strokeStyle
            )
        }
        .opacity(track.state == .playing ? 1 : 0.45)
        .animation(.easeOut(duration: 0.16), value: renderState.level)
        .accessibilityHidden(true)
    }

    private var downsampledWaveform: [Double] {
        let samples = renderState.waveform
        guard !samples.isEmpty else { return Array(repeating: 0.04, count: 40) }
        let pointCount = min(40, samples.count)
        guard pointCount > 1 else { return samples }
        let reduced = (0..<pointCount).map { index -> Double in
            let start = index * samples.count / pointCount
            let end = max(start + 1, (index + 1) * samples.count / pointCount)
            let slice = samples[start..<min(samples.count, end)]
            return slice.reduce(0, +) / Double(max(1, slice.count))
        }
        guard reduced.count > 2 else { return reduced }
        return reduced.indices.map { index in
            let previous = reduced[max(0, index - 1)]
            let current = reduced[index]
            let next = reduced[min(reduced.count - 1, index + 1)]
            return previous * 0.2 + current * 0.6 + next * 0.2
        }
    }

    private func smoothWaveformPath(through points: [CGPoint]) -> Path {
        guard let first = points.first else { return Path() }
        guard points.count > 1 else {
            var path = Path()
            path.move(to: first)
            return path
        }

        return Path { path in
            path.move(to: first)
            for index in 0..<(points.count - 1) {
                let p0 = index > 0 ? points[index - 1] : points[index]
                let p1 = points[index]
                let p2 = points[index + 1]
                let p3 = index + 2 < points.count ? points[index + 2] : p2
                let control1 = CGPoint(
                    x: p1.x + (p2.x - p0.x) / 6,
                    y: p1.y + (p2.y - p0.y) / 6
                )
                let control2 = CGPoint(
                    x: p2.x - (p3.x - p1.x) / 6,
                    y: p2.y - (p3.y - p1.y) / 6
                )
                path.addCurve(to: p2, control1: control1, control2: control2)
            }
        }
    }

    private var waveformAmplitude: CGFloat {
        let activity = 0.2 + renderState.level * 0.8
        return CGFloat(min(0.46, max(0.06, activity * 0.46)))
    }

    @ViewBuilder
    private var progress: some View {
        if track.state == .playing {
            TimelineView(.periodic(from: .now, by: tickInterval)) { context in
                progressBody(position: resolvedPosition(at: context.date))
            }
        } else {
            progressBody(position: resolvedPosition(at: Date()))
        }
    }

    /// The monitor only samples position every couple of seconds, so the bar is
    /// projected forward from the last sample to keep it moving continuously.
    private var tickInterval: TimeInterval {
        renderState.isLowPowerModeEnabled ? 0.5 : 0.25
    }

    private func resolvedPosition(at date: Date) -> TimeInterval {
        if let scrubFraction, track.duration > 0 {
            return scrubFraction * track.duration
        }
        guard track.state == .playing, let anchorDate else { return track.position }
        let projected = anchorPosition + max(0, date.timeIntervalSince(anchorDate))
        return track.duration > 0 ? min(track.duration, projected) : projected
    }

    private func progressBody(position: TimeInterval) -> some View {
        let fraction = track.duration > 0 ? min(1, max(0, position / track.duration)) : 0

        return VStack(spacing: 8) {
            seekBar(fraction: fraction)

            HStack {
                Text(formatTime(position))
                Spacer()
                Text(track.duration > 0 ? "-\(formatTime(max(0, track.duration - position)))" : "LIVE")
            }
            .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
            .foregroundStyle(.tertiary)
        }
    }

    private func seekBar(fraction: Double) -> some View {
        let isSeekable = track.duration > 0
        let isActive = isBarHovered || scrubFraction != nil
        let barHeight: CGFloat = isActive ? 8 : 5
        let knobSide: CGFloat = 13

        return GeometryReader { proxy in
            let width = proxy.size.width

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.16))
                    .frame(height: barHeight)

                Capsule()
                    .fill(accent)
                    .frame(width: min(width, width * fraction), height: barHeight)

                if isActive, isSeekable {
                    Circle()
                        .fill(.white)
                        .frame(width: knobSide, height: knobSide)
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                        .offset(
                            x: min(
                                max(0, width * fraction - knobSide / 2),
                                max(0, width - knobSide)
                            )
                        )
                }
            }
            .frame(width: width, height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(seekGesture(width: width), including: isSeekable ? .all : .none)
        }
        .frame(height: 20)
        .animation(.easeOut(duration: 0.14), value: isActive)
        .onHover { isBarHovered = $0 }
        .accessibilityLabel("Playback position")
        .accessibilityValue(
            "\(formatTime(fraction * track.duration)) elapsed, "
                + "\(formatTime(max(0, track.duration - fraction * track.duration))) remaining"
        )
            .accessibilityAdjustableAction { direction in
            guard canSeek else { return }
            seekRelative(by: direction == .increment ? 10 : -10)
        }
    }

    private func seekGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                scrubFraction = seekFraction(atX: value.location.x, width: width)
            }
            .onEnded { value in
                let target = seekFraction(atX: value.location.x, width: width) * track.duration
                scrubFraction = nil
                anchorPosition = target
                anchorDate = Date()
                pendingSeekTarget = target
                onSeek(target, track.source)
            }
    }

    private func seekFraction(atX x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return min(1, max(0, Double(x / width)))
    }

    private func controls(isCompact: Bool) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                controlButton(
                    .toggleShuffle,
                    icon: "shuffle",
                    label: track.isShuffleEnabled ? "Turn Shuffle Off" : "Turn Shuffle On",
                    isActive: track.isShuffleEnabled
                )

                utilityButton(
                    icon: "doc.on.doc",
                    label: "Copy Track Info",
                    action: copyTrackInfo
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: isCompact ? 10 : 14) {
                controlButton(.previousTrack, icon: "backward.fill", label: "Previous", isCompact: isCompact)
                controlButton(
                    .togglePlayPause,
                    icon: track.state == .playing ? "pause.fill" : "play.fill",
                    label: track.state == .playing ? "Pause" : "Play",
                    isPrimary: true,
                    isCompact: isCompact
                )
                controlButton(.nextTrack, icon: "forward.fill", label: "Next", isCompact: isCompact)
            }
            .frame(width: isCompact ? 138 : 160)

            HStack(spacing: 8) {
                Text("\(Image(systemName: renderState.audioOutputRoute.kind.symbolName))  \(renderState.audioOutputRoute.name)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 150, alignment: .trailing)
                    .help("Playing on \(renderState.audioOutputRoute.name)")
                    .accessibilityLabel("Playing on \(renderState.audioOutputRoute.name)")

                utilityButton(
                    icon: "arrow.up.forward.app",
                    label: "Open \(sourceName)",
                    action: openSourcePlayer
                )
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func controlButton(
        _ command: PlaybackCommand,
        icon: String,
        label: String,
        isPrimary: Bool = false,
        isActive: Bool = false,
        isCompact: Bool = false
    ) -> some View {
        Button {
            onPlaybackCommand(command, track.source)
        } label: {
            Image(systemName: icon)
                .font(.system(size: isPrimary ? (isCompact ? 17 : 19) : (isCompact ? 13 : 14), weight: .semibold))
                    .foregroundStyle(isPrimary ? primaryControlForeground : (isActive ? accent : Color.white))
                .frame(
                    width: isPrimary ? (isCompact ? 48 : 54) : (isCompact ? 34 : 38),
                    height: isPrimary ? (isCompact ? 48 : 54) : (isCompact ? 34 : 38)
                )
                .background {
                    Circle().fill(isPrimary ? AnyShapeStyle(accent) : AnyShapeStyle(.thinMaterial))
                }
                .overlay {
                    Circle().stroke(
                        isActive ? accent.opacity(0.75) : .white.opacity(isPrimary ? 0.35 : 0.16),
                        lineWidth: 1
                    )
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .disabled(!canControlPlayback)
    }

    private var primaryControlForeground: Color {
        guard let rgb = renderState.palette.accent.usingColorSpace(.deviceRGB) else { return .black }
        let luminance = 0.2126 * rgb.redComponent
            + 0.7152 * rgb.greenComponent
            + 0.0722 * rgb.blueComponent
        return luminance > 0.58 ? .black : .white
    }

    private func utilityButton(
        icon: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 38, height: 38)
                .background(.thinMaterial, in: Circle())
                .overlay {
                    Circle().stroke(.white.opacity(0.16), lineWidth: 1)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .disabled(!canControlPlayback)
    }

    private var sourceName: String {
        switch track.source {
        case .spotify: "Spotify"
        case .music: "Apple Music"
        case .automatic: "Music App"
        }
    }

    private var playbackStatus: String {
        switch track.state {
        case .playing: "Playing"
        case .paused: "Paused"
        case .stopped: "Stopped"
        case .unavailable: "Unavailable"
        }
    }

    private func copyTrackInfo() {
        let components = [track.title, track.artist, track.album].filter { !$0.isEmpty }
        guard !components.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(components.joined(separator: " - "), forType: .string)
    }

    private func openSourcePlayer() {
        if let processID = track.processID,
           let application = NSRunningApplication(processIdentifier: processID) {
            application.activate(options: [.activateAllWindows])
            return
        }

        let bundleIdentifier: String? = switch track.source {
        case .spotify: "com.spotify.client"
        case .music: "com.apple.Music"
        case .automatic: nil
        }
        guard let bundleIdentifier,
              let applicationURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleIdentifier
              ) else { return }
        NSWorkspace.shared.openApplication(
            at: applicationURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, _ in }
    }

    private func seekRelative(by offset: TimeInterval) {
        let target = min(track.duration, max(0, resolvedPosition(at: Date()) + offset))
        anchorPosition = target
        anchorDate = Date()
        pendingSeekTarget = target
        onSeek(target, track.source)
    }

    private func formatTime(_ value: TimeInterval) -> String {
        guard value.isFinite, value >= 0 else { return "0:00" }
        let totalSeconds = Int(value.rounded(.down))
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }
}
