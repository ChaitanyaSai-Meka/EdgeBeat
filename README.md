# EdgeBeat

**Music-reactive ambient edge lighting for macOS.** EdgeBeat turns your screen's
edges into a sleek glowing border that **pulses to the beat** of whatever's playing in
**Spotify** or **Apple Music** and is **colored by the album art** — a "music player
edge lighting" effect, like phone edge-lighting / ambilight.

It lives quietly in the menu bar (no Dock icon) and floats a click-through glow over
everything, including full-screen apps and across all Spaces.

---

## Status

| Milestone | Feature | State |
|-----------|---------|-------|
| 1 | Menu-bar app scaffold + build scripts | ✅ Done |
| 2 | Overlay panel + edge glow rendering | ✅ Done |
| 3 | Now-playing + album-art color palette | ✅ Done |
| 4 | Audio capture + beat detection | ✅ Done |
| 5 | Polish: preferences, displays, card, permissions, signing | ✅ Done |

> The current build includes music-synced, ambient, and static animation modes; album or
> custom colors; single/gradient rendering; glow and thickness controls; persistent
> settings; multi-display targeting; an optional lock-screen now-playing card; and
> Launch at Login.

---

## Requirements

- **macOS 14.4+** (developed/tested on macOS 26, Apple Silicon)
- **Swift toolchain** — Xcode **Command Line Tools** are enough (no full Xcode needed):
  ```sh
  xcode-select --install
  ```
- Spotify and/or the Apple Music app for the now-playing/color features.

---

## Build & Run

```sh
# from the project root (this folder)
bash scripts/build.sh     # compiles + assembles EdgeBeat.app + signs it
open EdgeBeat.app          # launch (menu-bar icon appears; no Dock icon)

# or do both at once:
bash scripts/run.sh
```

A waveform icon appears in the menu bar. It provides immediate access to the lighting
toggle, animation mode, album/custom colors, glow, thickness, display targeting, the
lock-screen now-playing card, music source, Launch at Login, privacy settings, and quit.

To stop it from the terminal:

```sh
pkill -x EdgeBeat
```

---

## Permissions

EdgeBeat asks for the minimum it needs, on first use:

- **Now Playing / Automation** — the bundled MediaRemoteAdapter is the primary path for
  Spotify and Apple Music, so metadata and playback controls do not depend on per-app
  Automation approval. AppleScript remains as a fallback for metadata and artwork.
- **Audio capture** — EdgeBeat uses **Core Audio process
  taps**, which capture the music app's audio **without** Screen Recording permission and
  without the periodic re-authorization nag that ScreenCaptureKit imposes.

If audio capture ever returns silence, EdgeBeat surfaces a hint and falls back to a global
system-audio tap.

---

## How it works

### Signal flow

```
AudioTapEngine ──PCM──▶ BeatAnalyzer ──▶ AudioFeatures ─┐
                                                        ├─▶ RenderState ─▶ EdgeGlowView
NowPlayingMonitor ──artwork──▶ PaletteExtractor ──▶ Palette ─┘        (inside OverlayPanel)

AppPreferences ── persisted modes / colors / glow / display / card ───────────▶
MenuBarController ───────────── updates AppPreferences ────────────────────────▶
```

- **AudioTapEngine** — resolves the playing app's PID → audio process object, creates a
  Core Audio process tap + a private aggregate device, and streams PCM frames to the
  analyzer (with a global-tap fallback).
- **BeatAnalyzer** — Hann-windowed vDSP real FFT (1024 samples) → bass/mid/treble band
  energy; a smoothed RMS `level`; energy-based onset detection with a refractory window
  produces `beat` pulses. Publishes `AudioFeatures`.
- **NowPlayingMonitor** — reads typed metadata through MediaRemoteAdapter on a serial
  utility queue, with defensive Spotify/Apple Music AppleScript fallbacks; detects the
  active player, play state, artwork, progress, and track changes.
- **PaletteExtractor** — downsamples the artwork to 64×64, builds an HSB histogram, scores
  buckets by *population × saturation × mid-brightness* to pick primary/secondary/accent
  colors + a dark background tone; caches per track.
- **RenderState** — merges `AudioFeatures` + `Palette` into smoothed, animatable render
  parameters and live now-playing progress that drive the view.
- **AppPreferences** — stores lighting, color, animation, glow, thickness, display, and
  card choices in native `UserDefaults`, and publishes changes immediately to the UI.
- **OverlayPanel** — a non-activating, borderless `NSPanel`: clear background,
  click-through (`ignoresMouseEvents`), `level = .screenSaver`, `collectionBehavior`
  spanning all Spaces + full-screen apps. Creates one panel per selected display and
  re-lays them out when the display arrangement changes.
- **EdgeGlowView** — SwiftUI `Canvas`: independent, edge-to-edge filled wave fields on all
  four sides, layered into a broad halo, tighter glow, and bright core. It supports
  music-reactive, gently animated ambient, and zero-clock static rendering.
- **LockScreenNowPlayingView** — a separate, tightly sized lock-screen panel above the
  profile area, with artwork, progress, and previous/play-pause/next controls. Keeping it
  separate preserves click-through behavior everywhere outside the widget.

### Why these choices

- **Core Audio process taps** over ScreenCaptureKit — no Screen Recording permission, no
  periodic re-auth prompts, lower CPU.
- **Lock-screen card** — uses the same dynamic SkyLight-space technique as
  [BoringNotch](https://github.com/TheBoredTeam/boring.notch) and its
  [SkyLightWindow](https://github.com/Lakr233/SkyLightWindow) dependency. This relies on
  private macOS SkyLight symbols and may require maintenance across macOS releases.
- **MediaRemoteAdapter** — follows BoringNotch's permission-free approach: `/usr/bin/perl`
  loads the bundled adapter framework using its system entitlement on macOS 15.4+. The
  upstream BSD-3-Clause license is included at `Resources/MediaRemoteAdapter.LICENSE`.
- **AppKit lifecycle + SwiftUI rendering** — AppKit `NSApplication`/`NSStatusItem` for a
  reliable accessory (menu-bar) app; SwiftUI (via `NSHostingView`) for expressive glow
  visuals. No custom Metal shaders / asset catalogs / storyboards, since Command Line
  Tools can't compile those.
- **SwiftPM + a packaging script** instead of an `.xcodeproj` — builds fully from the CLI
  with only Command Line Tools installed.

---

## Project structure

```
edge/
├── Package.swift                 # SwiftPM executable target + linked frameworks
├── README.md                     # this file
├── Resources/
│   └── Info.plist                # bundle id, LSUIElement, usage strings, min OS
├── Sources/EdgeBeat/
│   ├── main.swift                # entry point (accessory activation)
│   ├── AppDelegate.swift         # wires everything together
│   ├── AppPreferences.swift      # persisted feature settings
│   ├── MenuBarController.swift   # status-item menu and controls
│   ├── OverlayPanel.swift        # click-through overlay window
│   ├── EdgeGlowView.swift        # SwiftUI glow rendering
│   ├── NowPlaying.swift          # player/source and track models
│   ├── NowPlayingMonitor.swift   # player detection and fallback bridge
│   ├── MediaRemoteAdapter.swift  # permission-free system Now Playing bridge
│   ├── PaletteExtractor.swift    # album-art color extraction
│   ├── RenderState.swift         # audio + palette state for the view
│   ├── AudioTapEngine.swift      # Core Audio process/global tap
│   └── BeatAnalyzer.swift        # vDSP FFT + beat/energy detection
└── scripts/
    ├── build.sh                  # swift build → assemble .app → codesign
    └── run.sh                    # build + open
```

---

## Roadmap

1. **Scaffold** ✅ — menu-bar app launches (accessory, no Dock icon), On/Off + Quit,
   build/run scripts, `.app` assembly + signing.
2. **Overlay** ✅ — click-through, always-on-top glow across Spaces and full-screen apps.
3. **Color** ✅ — glow colors follow the current album art and update on track changes.
4. **Beat** ✅ — glow pulses to captured audio, dims on pause, and follows Spotify/Music.
5. **Polish** ✅ — full menu controls, persistence, multi-display targeting, interactive
   lock-screen card, adaptive polling, Launch at Login, privacy helper, and capture fallback status.

---

## Configuration decisions (locked in)

- **Beat sync:** real audio capture (true beat matching).
- **Players:** both Spotify and Apple Music, auto-detected.
- **Look:** full-perimeter glow.
- **Displays:** built-in, current main, or all connected displays.
- **Notch/top edge:** the glow stays at the true top physical edge and wraps around the
  notch (uses the full screen frame, not the visible frame), with a thin/translucent top
  band so the menu bar underneath stays readable.

---

## Troubleshooting

- **No menu-bar icon after `open`?** Check it's running: `pgrep -x EdgeBeat`. If the menu
  bar is crowded, macOS may hide the icon — widen the menu bar or quit some other menu
  items.
- **Colors/beat not reacting?** Make sure you approved the Automation prompt (System
  Settings → Privacy & Security → Automation → EdgeBeat) and that music is actually
  playing.
- **Permissions keep re-prompting after each rebuild?** Set up the self-signed cert (see
  *Making permission grants stick* above).
