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
    @StateObject private var lyricsStore = LyricsStore()
    @State private var showsLyrics = false

    private static let contentMaxWidth: CGFloat = 760
    private static let lyricsContentMaxWidth: CGFloat = 1500
    private static let horizontalInset: CGFloat = 40
    private static let artworkMaxSide: CGFloat = 500
    private static let artworkMinSide: CGFloat = 150
    private static let sideArtworkMaxSide: CGFloat = 480
    private static let sideLyricsMinWidth: CGFloat = 860
    private static let sideLyricsMinHeight: CGFloat = 560
    private static let sideLyricsSpacing: CGFloat = 56
    private static let sideLyricsMaxWidth: CGFloat = 720
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
        .onChange(of: track.artworkRevision) { _, _ in
            updateBackdrop()
        }
        .onChange(of: lyricsRequestKey) { _, _ in
            guard showsLyrics else { return }
            loadLyrics()
        }
        .onAppear {
            updateBackdrop()
            if showsLyrics { loadLyrics() }
        }
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

    private var canLoadLyrics: Bool {
        canControlPlayback
            && !track.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !track.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var lyricsRequestKey: String {
        [track.identifier, track.title, track.artist, track.album].joined(separator: "|")
    }

    private var background: some View {
        ZStack {
            Color(nsColor: renderState.palette.background)
                .ignoresSafeArea()

            if let backdropImage {
                Image(nsImage: backdropImage)
                    .resizable()
                    .scaledToFill()
                    .scaleEffect(showsLyrics ? 1.16 : 1.08)
                    .saturation(showsLyrics ? 1.24 : 1)
                    .blur(radius: showsLyrics ? 84 : 48)
                    .opacity(showsLyrics ? 0.60 : 0.16)
                    .ignoresSafeArea()
            }

            Color.black.opacity(showsLyrics ? 0.38 : 0.94)
                .ignoresSafeArea()

            if showsLyrics {
                LinearGradient(
                    colors: [
                        .black.opacity(0.24),
                        .black.opacity(0.04),
                        .black.opacity(0.18)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .ignoresSafeArea()

                LinearGradient(
                    colors: [
                        .black.opacity(0.22),
                        .clear,
                        .black.opacity(0.20)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            }
        }
    }

    private func updateBackdrop() {
        guard backdropIdentifier != backdropKey || backdropImage == nil else { return }
        backdropIdentifier = backdropKey
        guard let artwork = track.artwork else {
            backdropImage = nil
            return
        }
        backdropImage = Self.makeBackdropImage(from: artwork)
    }

    private var backdropKey: String {
        track.identifier + "|" + track.artworkRevision
    }

    private func loadLyrics(force: Bool = false) {
        guard canLoadLyrics else {
            lyricsStore.reset()
            return
        }
        lyricsStore.load(
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: track.duration,
            force: force
        )
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
                HStack(spacing: 10) {
                    lyricsToggle
                    routeSummary
                }
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

    private var lyricsToggle: some View {
        Button {
            toggleLyrics()
        } label: {
            Image(systemName: showsLyrics ? "music.note.list" : "text.quote")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(showsLyrics ? accent : Color.secondary)
                .frame(width: 34, height: 34)
                .background {
                    Circle().fill(showsLyrics ? accent.opacity(0.2) : Color.white.opacity(0.06))
                }
                .overlay {
                    Circle().stroke(
                        showsLyrics ? accent.opacity(0.7) : Color.white.opacity(0.14),
                        lineWidth: 1
                    )
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(showsLyrics ? "Hide Lyrics" : "Show Lyrics")
        .accessibilityLabel(showsLyrics ? "Hide Lyrics" : "Show Lyrics")
        .disabled(!canLoadLyrics)
        .opacity(canLoadLyrics ? 1 : 0.45)
    }

    private func toggleLyrics() {
        showsLyrics.toggle()
        if showsLyrics {
            loadLyrics()
        } else if case .loading = lyricsStore.state {
            lyricsStore.reset()
        }
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

    @ViewBuilder
    private func playerLayout(in size: CGSize) -> some View {
        let playerHeight = max(0, size.height - Self.headerHeight)
        let metrics = layoutMetrics(for: playerHeight)
        let maxContentWidth = showsLyrics ? Self.lyricsContentMaxWidth : Self.contentMaxWidth
        let columnWidth = min(
            maxContentWidth,
            max(0, size.width - Self.horizontalInset * 2)
        )
        let usesSideLyrics = showsLyrics
            && !metrics.isCompact
            && columnWidth >= Self.sideLyricsMinWidth
            && playerHeight >= Self.sideLyricsMinHeight

        if usesSideLyrics {
            sideLyricsLayout(
                width: columnWidth,
                height: playerHeight,
                metrics: metrics
            )
            .frame(width: columnWidth, height: playerHeight)
            .frame(maxWidth: .infinity, alignment: .center)
            .transition(.opacity.combined(with: .move(edge: .trailing)))
        } else {
            standardPlayerLayout(
                width: columnWidth,
                height: playerHeight,
                metrics: metrics
            )
            .transition(.opacity.combined(with: showsLyrics ? .move(edge: .top) : .identity))
        }
    }

    private func standardPlayerLayout(
        width: CGFloat,
        height: CGFloat,
        metrics: LayoutMetrics
    ) -> some View {
        let artworkAvailableHeight = max(
            metrics.artworkMinSide,
            height - metrics.controlsHeight - metrics.metadataHeight - metrics.progressHeight
        )
        let artworkSide = min(
            Self.artworkMaxSide,
            max(metrics.artworkMinSide, min(width, artworkAvailableHeight))
        )

        return VStack(spacing: 0) {
            Spacer(minLength: 0)

            if showsLyrics {
                compactLyricsLayout(
                    width: width,
                    height: artworkSide + metrics.metadataHeight,
                    artworkSide: artworkSide,
                    isCompact: metrics.isCompact
                )
            } else {
                artworkView(size: artworkSide)

                metadata(isCompact: metrics.isCompact)
                    .padding(.top, metrics.isCompact ? 10 : 18)
                    .frame(height: metrics.metadataHeight, alignment: .top)
            }

            progress
                .frame(height: metrics.progressHeight)

            Spacer(minLength: 0)

            controls(isCompact: metrics.isCompact)
                .frame(height: metrics.controlsHeight, alignment: .top)
        }
        .frame(width: width, height: height)
        .frame(maxWidth: .infinity, alignment: .center)
        .animation(.easeInOut(duration: 0.24), value: showsLyrics)
    }

    private func compactLyricsLayout(
        width: CGFloat,
        height: CGFloat,
        artworkSide: CGFloat,
        isCompact: Bool
    ) -> some View {
        let thumbnailSide = min(92, max(72, artworkSide * 0.62))
        let headerHeight = thumbnailSide + 12

        return VStack(spacing: 0) {
            HStack(spacing: 14) {
                artworkView(size: thumbnailSide, cornerRadius: 12)

                metadata(isCompact: isCompact, showsWaveform: false, leading: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: headerHeight)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            lyricsPanel
                .frame(maxHeight: .infinity)
        }
        .frame(width: width, height: height, alignment: .top)
    }

    private func sideLyricsLayout(
        width: CGFloat,
        height: CGFloat,
        metrics: LayoutMetrics
    ) -> some View {
        let lyricsWidth = min(Self.sideLyricsMaxWidth, max(400, width * 0.48))
        let artworkColumnWidth = max(0, width - lyricsWidth - Self.sideLyricsSpacing)
        let metadataHeight: CGFloat = 72
        let controlsHeight: CGFloat = 58
        let progressHeight: CGFloat = 48
        let artworkAvailableHeight = max(
            metrics.artworkMinSide,
            height - metadataHeight - controlsHeight - progressHeight - 72
        )
        let artworkSide = min(
            Self.sideArtworkMaxSide,
            max(
                metrics.artworkMinSide,
                min(artworkColumnWidth, artworkAvailableHeight)
            )
        )

        return HStack(alignment: .center, spacing: Self.sideLyricsSpacing) {
            sidePlaybackColumn(
                width: artworkColumnWidth,
                height: height,
                artworkSide: artworkSide,
                metadataHeight: metadataHeight,
                controlsHeight: controlsHeight,
                progressHeight: progressHeight
            )

            sideLyricsView
                .frame(width: lyricsWidth, height: height)
        }
    }

    private func sidePlaybackColumn(
        width: CGFloat,
        height: CGFloat,
        artworkSide: CGFloat,
        metadataHeight: CGFloat,
        controlsHeight: CGFloat,
        progressHeight: CGFloat
    ) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            artworkView(size: artworkSide, cornerRadius: 16)

            sideMetadata
                .padding(.top, 18)
                .frame(height: metadataHeight, alignment: .top)

            progress
                .frame(height: progressHeight)

            sideControls
                .frame(height: controlsHeight, alignment: .center)

            Spacer(minLength: 0)
        }
        .frame(width: min(width, artworkSide), height: height)
        .frame(width: width, height: height, alignment: .center)
    }

    private var sideControls: some View {
        ZStack {
            HStack {
                sideControlButton(
                    .toggleShuffle,
                    icon: "shuffle",
                    label: track.isShuffleEnabled ? "Turn Shuffle Off" : "Turn Shuffle On",
                    isActive: track.isShuffleEnabled
                )

                Spacer()

                Button(action: copyTrackInfo) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.76))
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Copy Track Info")
                .accessibilityLabel("Copy Track Info")
                .disabled(!canControlPlayback)
            }

            HStack(spacing: 24) {
                sideControlButton(.previousTrack, icon: "backward.fill", label: "Previous")
                sideControlButton(
                    .togglePlayPause,
                    icon: track.state == .playing ? "pause.fill" : "play.fill",
                    label: track.state == .playing ? "Pause" : "Play",
                    isPrimary: true
                )
                sideControlButton(.nextTrack, icon: "forward.fill", label: "Next")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var sideMetadata: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(track.title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .accessibilityAddTraits(.isHeader)

            Text(track.artist.isEmpty ? track.album : track.artist)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sideControlButton(
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
                .font(.system(size: isPrimary ? 22 : 16, weight: .semibold))
                .foregroundStyle(isActive ? accent : Color.white.opacity(isPrimary ? 1 : 0.82))
                .frame(width: isPrimary ? 46 : 40, height: isPrimary ? 46 : 40)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .disabled(!canControlPlayback)
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

    private var lyricsPanel: some View {
        ZStack {
            lyricsContent
                .mask(lyricsFadeMask)
        }
        .overlay(alignment: .bottomLeading) {
            lyricsAttribution
                .padding(.leading, 12)
        }
    }

    private var sideLyricsView: some View {
        ZStack {
            sideLyricsContent
                .mask(lyricsFadeMask)
        }
        .overlay(alignment: .bottomLeading) {
            lyricsAttribution
                .padding(.leading, 32)
                .padding(.bottom, 12)
        }
        .accessibilityElement(children: .contain)
    }

    private var lyricsFadeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.12),
                .init(color: .black, location: 0.86),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var lyricsAttribution: some View {
        Text("Lyrics by LRCLIB")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white.opacity(0.28))
    }

    @ViewBuilder
    private var sideLyricsContent: some View {
        switch lyricsStore.state {
        case .idle:
            lyricsStatus(
                icon: "text.quote",
                title: "Lyrics are not loaded",
                detail: "Open the lyrics button to look up this track."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading:
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading lyrics...")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .loaded(document):
            lyricsDocumentViewport(document, compact: false)
        case .unavailable:
            VStack(spacing: 12) {
                lyricsStatus(
                    icon: "text.badge.xmark",
                    title: "Lyrics unavailable",
                    detail: "No lyrics were found for this track."
                )
                retryLyricsButton
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            VStack(spacing: 12) {
                lyricsStatus(
                    icon: "wifi.exclamationmark",
                    title: "Lyrics could not be loaded",
                    detail: message
                )
                retryLyricsButton
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func lyricsDocumentViewport(
        _ document: LyricsDocument,
        compact: Bool
    ) -> some View {
        if document.isInstrumental {
            instrumentalLyricsView(compact: compact)
        } else if document.isSynced {
            if track.state == .playing {
                TimelineView(.periodic(from: .now, by: tickInterval)) { context in
                    SyncedLyricsViewport(
                        lines: document.visibleLines,
                        position: resolvedPosition(at: context.date),
                        accent: accent,
                        compact: compact,
                        trackIdentifier: track.identifier,
                        onSeek: seekToLyric
                    )
                }
            } else {
                SyncedLyricsViewport(
                    lines: document.visibleLines,
                    position: resolvedPosition(at: Date()),
                    accent: accent,
                    compact: compact,
                    trackIdentifier: track.identifier,
                    onSeek: seekToLyric
                )
            }
        } else {
            plainLyricsView(document, compact: compact)
        }
    }

    private func plainLyricsView(
        _ document: LyricsDocument,
        compact: Bool
    ) -> some View {
        ScrollView {
            LazyVStack(
                alignment: compact ? .center : .leading,
                spacing: compact ? 14 : 22
            ) {
                ForEach(document.lines) { line in
                    if line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Color.clear
                            .frame(height: compact ? 6 : 10)
                    } else {
                        Text(line.text)
                            .font(.system(size: compact ? 21 : 31, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(compact ? 0.78 : 0.62))
                            .lineSpacing(compact ? 5 : 7)
                            .multilineTextAlignment(compact ? .center : .leading)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, compact ? 18 : 32)
            .padding(.vertical, compact ? 54 : 104)
        }
        .scrollIndicators(.hidden)
    }

    private func instrumentalLyricsView(compact: Bool) -> some View {
        VStack(spacing: compact ? 12 : 16) {
            Image(systemName: "music.note")
                .font(.system(size: compact ? 26 : 34, weight: .medium))
                .foregroundStyle(accent)
                .symbolEffect(.pulse, isActive: track.state == .playing)

            Text("Instrumental track")
                .font(.system(size: compact ? 16 : 20, weight: .semibold))

            Text("There are no lyrics for this recording.")
                .font(.system(size: compact ? 12 : 13))
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    @ViewBuilder
    private var lyricsContent: some View {
        switch lyricsStore.state {
        case .idle:
            VStack {
                lyricsStatus(
                    icon: "text.quote",
                    title: "Lyrics are not loaded",
                    detail: "Open the lyrics button to look up this track."
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading:
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading lyrics...")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .loaded(document):
            lyricsDocumentViewport(document, compact: true)
        case .unavailable:
            VStack(spacing: 10) {
                lyricsStatus(
                    icon: "text.badge.xmark",
                    title: "Lyrics unavailable",
                    detail: "No lyrics were found for this track."
                )
                retryLyricsButton
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            VStack(spacing: 10) {
                lyricsStatus(
                    icon: "wifi.exclamationmark",
                    title: "Lyrics could not be loaded",
                    detail: message
                )
                retryLyricsButton
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var retryLyricsButton: some View {
        Button {
            loadLyrics(force: true)
        } label: {
            Label("Try Again", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
        .tint(accent)
    }

    private func lyricsStatus(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func artworkView(size: CGFloat, cornerRadius: CGFloat = 24) -> some View {
        if let artwork = track.artwork {
            Image(nsImage: artwork)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .background(.black.opacity(0.24))
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(.white.opacity(0.22), lineWidth: 1)
                }
                .shadow(color: accent.opacity(0.42), radius: 34, y: 18)
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.white.opacity(0.08))
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 52, weight: .medium))
                        .foregroundStyle(.secondary)
                }
        }
    }

    private func metadata(
        isCompact: Bool,
        showsWaveform: Bool = true,
        leading: Bool = false
    ) -> some View {
        let alignment: HorizontalAlignment = leading ? .leading : .center
        let textAlignment: TextAlignment = leading ? .leading : .center
        let frameAlignment: Alignment = leading ? .leading : .center

        return VStack(alignment: alignment, spacing: 7) {
            if showsWaveform {
                liveWaveform
                    .frame(height: isCompact ? 24 : 34)
                    .padding(.bottom, isCompact ? 2 : 5)
            }

            Text(track.title)
                .font(.system(size: isCompact ? 27 : 34, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(isCompact ? 0.6 : 0.68)
                .multilineTextAlignment(textAlignment)
                .frame(maxWidth: .infinity, alignment: frameAlignment)
                .accessibilityAddTraits(.isHeader)

            Text(track.artist.isEmpty ? track.album : track.artist)
                .font(.system(size: isCompact ? 16 : 19, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .multilineTextAlignment(textAlignment)
                .frame(maxWidth: .infinity, alignment: frameAlignment)

            if !track.album.isEmpty, !track.artist.isEmpty {
                Text(track.album)
                    .font(.system(size: isCompact ? 12 : 14))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .multilineTextAlignment(textAlignment)
                    .frame(maxWidth: .infinity, alignment: frameAlignment)
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

    private func seekToLyric(_ timestamp: TimeInterval) {
        guard canSeek, timestamp.isFinite else { return }
        let target = min(track.duration, max(0, timestamp))
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

private struct SyncedLyricsViewport: View {
    let lines: [LyricsLine]
    let position: TimeInterval
    let accent: Color
    let compact: Bool
    let onSeek: (TimeInterval) -> Void
    let trackIdentifier: String

    @State private var lastFocusedID: Int?
    @State private var isUserScrolling = false

    init(
        lines: [LyricsLine],
        position: TimeInterval,
        accent: Color,
        compact: Bool,
        trackIdentifier: String = "",
        onSeek: @escaping (TimeInterval) -> Void
    ) {
        self.lines = lines
        self.position = position
        self.accent = accent
        self.compact = compact
        self.trackIdentifier = trackIdentifier
        self.onSeek = onSeek
    }

    var body: some View {
        let activeIndex = LyricsTimeline.activeIndex(in: lines, at: position)
        let activeID = activeIndex.map { lines[$0].id }
        let focusID = activeID ?? lines.first?.id
        return ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(
                        alignment: compact ? .center : .leading,
                        spacing: compact ? 2 : 8
                    ) {
                        ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                            lyricRow(
                                line,
                                at: index,
                                activeIndex: activeIndex
                            )
                        }
                    }
                    .padding(.horizontal, compact ? 18 : 32)
                    .padding(.vertical, compact ? 60 : 112)
                }
                .scrollIndicators(.hidden)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { _ in
                            isUserScrolling = true
                        }
                )

                if isUserScrolling, let focusID {
                    Button {
                        isUserScrolling = false
                        lastFocusedID = focusID
                        withAnimation(.smooth(duration: 0.42)) {
                            proxy.scrollTo(focusID, anchor: .center)
                        }
                    } label: {
                        Image(systemName: "location.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(accent, in: Circle())
                            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                    }
                    .buttonStyle(.plain)
                    .help("Jump to Current Lyric")
                    .accessibilityLabel("Jump to Current Lyric")
                    .padding(.trailing, 16)
                    .padding(.bottom, 18)
                }
            }
            .onChange(of: focusID, initial: true) { _, newID in
                guard let newID, newID != lastFocusedID, !isUserScrolling else { return }
                lastFocusedID = newID
                withAnimation(.smooth(duration: 0.42)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
        .id(trackIdentifier)
    }

    private func lyricRow(
        _ line: LyricsLine,
        at index: Int,
        activeIndex: Int?
    ) -> some View {
        SyncedLyricRow(
            line: line,
            isActive: index == activeIndex,
            isPast: activeIndex.map { index < $0 } ?? false,
            distance: activeIndex.map { abs(index - $0) } ?? index,
            accent: accent,
            compact: compact,
            onSeek: onSeek
        )
        .equatable()
        .id(line.id)
    }
}

private struct SyncedLyricRow: View, Equatable {
    let line: LyricsLine
    let isActive: Bool
    let isPast: Bool
    let distance: Int
    let accent: Color
    let compact: Bool
    let onSeek: (TimeInterval) -> Void

    static func == (lhs: SyncedLyricRow, rhs: SyncedLyricRow) -> Bool {
        lhs.line == rhs.line
            && lhs.isActive == rhs.isActive
            && lhs.isPast == rhs.isPast
            && lhs.distance == rhs.distance
            && lhs.accent == rhs.accent
            && lhs.compact == rhs.compact
    }

    private var lineOpacity: Double {
        guard !isActive else { return 1 }
        if distance == 1 { return isPast ? 0.34 : 0.52 }
        if distance == 2 { return isPast ? 0.22 : 0.32 }
        return isPast ? 0.13 : 0.18
    }

    private var fontSize: CGFloat {
        compact ? 21 : 32
    }

    private var lyricText: some View {
        Text(line.text)
            .font(.system(size: fontSize, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(compact ? 2 : 3)
            .minimumScaleFactor(0.70)
            .lineSpacing(compact ? 4 : 6)
            .multilineTextAlignment(compact ? .center : .leading)
            .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
            .fixedSize(horizontal: false, vertical: true)
            .shadow(
                color: isActive ? accent.opacity(0.22) : .clear,
                radius: isActive ? 16 : 0
            )
    }

    private var rowContent: some View {
        lyricText
        .frame(maxWidth: .infinity)
        .padding(.vertical, compact ? 8 : 12)
        .opacity(lineOpacity)
        .animation(.easeInOut(duration: 0.30), value: isActive)
        .animation(.easeInOut(duration: 0.30), value: lineOpacity)
    }

    var body: some View {
        Button {
            guard let timestamp = line.timestamp else { return }
            onSeek(timestamp)
        } label: {
            rowContent
        }
        .buttonStyle(.plain)
        .disabled(line.timestamp == nil)
        .help(line.timestamp.map { "Jump to \(formatTimestamp($0))" } ?? "Lyrics")
        .accessibilityLabel(line.text)
        .accessibilityHint(line.timestamp == nil ? "" : "Jump to this line")
    }

    private func formatTimestamp(_ value: TimeInterval) -> String {
        let totalSeconds = max(0, Int(value.rounded(.down)))
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }
}
