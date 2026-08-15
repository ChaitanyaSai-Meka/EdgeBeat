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
| 5 | Polish: intensity, permissions, signing | ✅ Done |

> The current build includes the overlay, brightness and source controls, player detection,
> artwork colors, and beat-reactive animation. Audio capture falls back to a global tap
> when a player-specific tap is unavailable.

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

A waveform icon appears in the menu bar. Use it to select a player, adjust brightness,
toggle the lighting, open privacy settings, or quit.

To stop it from the terminal:

```sh
pkill -x EdgeBeat
```

---

## Permissions

EdgeBeat asks for the minimum it needs, on first use:

- **Automation** (Apple Events) — to read the current song + album artwork from Spotify /
  Apple Music. You'll get a per-app prompt the first time; approve it. Covered by
  `NSAppleEventsUsageDescription` in `Resources/Info.plist`.
- **Audio capture** — EdgeBeat uses **Core Audio process
  taps**, which capture the music app's audio **without** Screen Recording permission and
  without the periodic re-authorization nag that ScreenCaptureKit imposes.

If audio capture ever returns silence, EdgeBeat surfaces a hint and falls back to a global
system-audio tap.

### Making permission grants stick across rebuilds

macOS ties permission (TCC) grants to an app's code signature. Plain **ad-hoc** signing
(the default here) produces a *new* identity on every rebuild, so macOS forgets your
grants and re-prompts. To make grants persist, create a **one-time self-signed
code-signing certificate** and the build script will use it automatically:

```sh
bash scripts/make-signing-cert.sh
```

You can also point the build at any identity:

```sh
EDGEBEAT_SIGN_ID="Your Cert Name" bash scripts/build.sh
```

---

## How it works

### Signal flow

```
AudioTapEngine ──PCM──▶ BeatAnalyzer ──▶ AudioFeatures ─┐
                                                        ├─▶ RenderState ─▶ EdgeGlowView
NowPlayingMonitor ──artwork──▶ PaletteExtractor ──▶ Palette ─┘        (inside OverlayPanel)

MenuBarController ─── toggles panel / intensity ───────────────────────────────▶
```

- **AudioTapEngine** — resolves the playing app's PID → audio process object, creates a
  Core Audio process tap + a private aggregate device, and streams PCM frames to the
  analyzer (with a global-tap fallback).
- **BeatAnalyzer** — Hann-windowed vDSP real FFT (1024 samples) → bass/mid/treble band
  energy; a smoothed RMS `level`; energy-based onset detection with a refractory window
  produces `beat` pulses. Publishes `AudioFeatures`.
- **NowPlayingMonitor** — polls Spotify (`{name, artist, artwork url} of current track`)
  and Apple Music (`raw data of artwork 1 of current track`) via AppleScript, guarded by
  `application "…" is running`; detects the active player, play state, and track changes.
- **PaletteExtractor** — downsamples the artwork to 64×64, builds an HSB histogram, scores
  buckets by *population × saturation × mid-brightness* to pick primary/secondary/accent
  colors + a dark background tone; caches per track.
- **RenderState** — merges `AudioFeatures` + `Palette` into smoothed, animatable render
  parameters (attack/decay envelopes) that drive the view.
- **OverlayPanel** — a non-activating, borderless `NSPanel`: clear background,
  click-through (`ignoresMouseEvents`), `level = .screenSaver`, `collectionBehavior`
  spanning all Spaces + full-screen apps. Sized to `NSScreen.main.frame` and re-laid-out
  on display changes.
- **EdgeGlowView** — SwiftUI: an inset rounded-rect stroke + wide blur bloom filled with a
  palette gradient hugging all four edges; opacity/width driven by `level`, extra bloom on
  `beat`, slow hue drift; honors the intensity slider.

### Why these choices

- **Core Audio process taps** over ScreenCaptureKit — no Screen Recording permission, no
  periodic re-auth prompts, lower CPU.
- **AppleScript** for now-playing — the private MediaRemote framework was gated behind an
  Apple-only entitlement in macOS 15.4, so it's unavailable to third-party apps.
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
│   ├── MenuBarController.swift   # status-item menu and controls
│   ├── OverlayPanel.swift        # click-through overlay window
│   ├── EdgeGlowView.swift        # SwiftUI glow rendering
│   ├── NowPlaying.swift          # player/source and track models
│   ├── NowPlayingMonitor.swift   # Spotify/Music AppleScript bridge
│   ├── PaletteExtractor.swift    # album-art color extraction
│   ├── RenderState.swift         # audio + palette state for the view
│   ├── AudioTapEngine.swift      # Core Audio process/global tap
│   └── BeatAnalyzer.swift        # vDSP FFT + beat/energy detection
└── scripts/
    ├── build.sh                  # swift build → assemble .app → codesign
    ├── run.sh                    # build + open
    └── make-signing-cert.sh      # one-time self-signed certificate
```

---

## Roadmap

1. **Scaffold** ✅ — menu-bar app launches (accessory, no Dock icon), On/Off + Quit,
   build/run scripts, `.app` assembly + signing.
2. **Overlay** ✅ — click-through, always-on-top glow across Spaces and full-screen apps.
3. **Color** ✅ — glow colors follow the current album art and update on track changes.
4. **Beat** ✅ — glow pulses to captured audio, dims on pause, and follows Spotify/Music.
5. **Polish** ✅ — source and brightness controls, privacy helper, signing script, and
   capture fallback status.

---

## Configuration decisions (locked in)

- **Beat sync:** real audio capture (true beat matching).
- **Players:** both Spotify and Apple Music, auto-detected.
- **Look:** full-perimeter glow.
- **Displays:** main display only.
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
