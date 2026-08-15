# EdgeBeat

EdgeBeat is a music-reactive edge-lighting application for macOS. It renders a
click-through glow around the display, follows the current album artwork, and
responds to audio from Spotify or Apple Music.

The application runs from the menu bar, stays visible over full-screen apps,
supports multiple displays, follows the physical MacBook notch, and can show an
interactive now-playing card on the lock screen.

Current version: `1.0.0`

## Features

- Music-reactive edge waves driven by real system audio
- Spotify and Apple Music detection
- Album-art color extraction
- Custom single-color and gradient modes
- Music Sync, Ambient, and Static animation modes
- Adjustable glow intensity and thickness
- Built-in, main, or all-display targeting
- Notch-aware lighting on supported MacBook displays
- Full-screen app and multi-Space support
- Lock-screen artwork, progress, and playback controls
- Persistent settings and optional Launch at Login
- Adaptive refresh rates that respect macOS Low Power Mode and display sleep
- Menu-bar-only operation with no Dock icon

## Requirements

- macOS 14.4 or later
- Xcode Command Line Tools
- Spotify for macOS, Apple Music, or both
- A Mac account allowed to grant system-audio permissions

The project is primarily developed and verified on Apple Silicon. The bundled
MediaRemoteAdapter framework includes both Apple Silicon and Intel architectures.

## Installation

EdgeBeat is currently distributed as source code. Build the application locally
using the included script.

### 1. Install the Command Line Tools

Open Terminal and run:

```sh
xcode-select --install
```

If the tools are already installed, macOS will report that no installation is
necessary.

### 2. Clone the repository

```sh
git clone https://github.com/ChaitanyaSai-Meka/EdgeBeat.git
cd EdgeBeat
```

### 3. Build EdgeBeat

```sh
bash scripts/build.sh
```

The script performs a release build, assembles `EdgeBeat.app`, copies the required
resources, and applies an ad-hoc code signature.

### 4. Launch EdgeBeat

```sh
open EdgeBeat.app
```

EdgeBeat runs as a menu-bar application. A waveform icon will appear in the menu
bar; no Dock icon is shown.

You can build and launch in one command during development:

```sh
bash scripts/run.sh
```

### 5. Install in Applications

After building, the app can be placed in `/Applications`:

```sh
ditto EdgeBeat.app /Applications/EdgeBeat.app
open /Applications/EdgeBeat.app
```

When replacing an existing installation, quit EdgeBeat before copying the new
build.

## First Run

1. Start Spotify or Apple Music and play a track.
2. Open the EdgeBeat menu-bar menu.
3. Enable `Lighting`.
4. Set `Animation` to `Music Sync`.
5. Set `Music Source` to `Automatic`, `Spotify`, or `Apple Music`.
6. Approve the system-audio permission if macOS requests it.

Album colors and audio response may take a few seconds to appear after the first
track begins playing.

## Permissions

### System Audio

Music Sync uses Core Audio process taps to analyze the active player's audio. The
audio is processed in memory and is not recorded or saved.

Depending on the macOS version, the permission appears under:

`System Settings > Privacy & Security > Screen & System Audio Recording`

After changing this permission, quit and reopen EdgeBeat.

### Automation

Spotify metadata and playback controls normally use the bundled
MediaRemoteAdapter and do not require Automation access. AppleScript remains as a
fallback for player metadata and artwork, so macOS may occasionally request access
to control Spotify or Music.

Fallback Automation permissions can be reviewed under:

`System Settings > Privacy & Security > Automation`

### Lock Screen

The lock-screen card uses private macOS SkyLight APIs. No separate user permission
is normally displayed, but compatibility can change between macOS releases.
When the card is enabled and music is actively playing, EdgeBeat temporarily keeps
the display awake while the Mac is locked. This activity is released when playback
stops, the card is disabled, the Mac unlocks, or EdgeBeat quits.

## Using EdgeBeat

All controls are available from the waveform icon in the menu bar.

| Control | Description |
| --- | --- |
| Lighting | Enables or disables the display overlay |
| Animation > Music Sync | Reacts to captured audio and detected beats |
| Animation > Ambient | Runs a low-motion animated glow without audio capture |
| Animation > Static | Displays a fixed edge glow |
| Colors > Album Colors | Derives the palette from the current artwork |
| Colors > Custom | Uses the selected primary and secondary colors |
| Glow | Adjusts overall brightness and opacity |
| Thickness | Adjusts the width and bloom of the edge lighting |
| Display | Targets the built-in, main, or all connected displays |
| Lock Screen Now Playing | Shows the now-playing card only while macOS is locked |
| Music Source | Selects automatic detection, Spotify, or Apple Music |
| Launch at Login | Starts EdgeBeat when the user signs in |
| Open Privacy Settings | Opens the macOS privacy settings used by the app |
| Check for Updates | Checks the EdgeBeat GitHub Releases page for a newer version |

The lock-screen card includes artwork, title, album information, progress, and
previous, play/pause, and next controls. It is placed above the authentication
area and is shown only on the main display.

## Updating

Select `Check for Updates...` from the EdgeBeat menu. The app checks only the
official [EdgeBeat GitHub Releases](https://github.com/ChaitanyaSai-Meka/EdgeBeat/releases)
feed. When a newer version is available, EdgeBeat offers to open its release page.

To update directly from source instead, run the following commands from the
repository directory:

```sh
git pull --ff-only
bash scripts/build.sh
```

Quit the installed copy before replacing it:

```sh
pkill -x EdgeBeat 2>/dev/null || true
ditto EdgeBeat.app /Applications/EdgeBeat.app
open /Applications/EdgeBeat.app
```

## Uninstalling

Quit EdgeBeat and remove the application:

```sh
pkill -x EdgeBeat 2>/dev/null || true
rm -rf /Applications/EdgeBeat.app
```

To remove stored preferences as well:

```sh
defaults delete com.chaitanya.edgebeat
```

Remove EdgeBeat from `System Settings > General > Login Items` if it remains listed
after uninstalling.

## Troubleshooting

### The menu-bar icon does not appear

Check whether EdgeBeat is running:

```sh
pgrep -fl EdgeBeat
```

If it is not running, launch the packaged app again:

```sh
open EdgeBeat.app
```

If the menu bar is crowded, macOS may hide some status items.

### The lighting does not appear

- Confirm that `Lighting` is enabled.
- Confirm that the selected display includes the display being viewed.
- Try `Animation > Ambient` to verify the overlay independently of audio capture.
- Quit and reopen EdgeBeat after changing display or privacy settings.

### Spotify is not detected

- Use the desktop Spotify application, not only the web player.
- Set `Music Source` to `Automatic` or `Spotify`.
- Start playback before testing detection.
- Quit and reopen both Spotify and EdgeBeat.
- Confirm that the packaged adapter exists:

```sh
test -d EdgeBeat.app/Contents/Resources/MediaRemoteAdapter.framework && echo "Adapter installed"
```

Do not run `.build/debug/EdgeBeat` directly when testing Spotify. The raw SwiftPM
executable does not contain the bundled MediaRemoteAdapter resources. Use
`scripts/run.sh` or open `EdgeBeat.app`.

### Apple Music is not detected

- Set `Music Source` to `Automatic` or `Apple Music`.
- Confirm that a normal music track is playing.
- Approve EdgeBeat under Automation settings if macOS presents a fallback prompt.

### The glow does not react to audio

- Confirm that `Animation` is set to `Music Sync`.
- Check the status text at the top of the EdgeBeat menu.
- Review the system-audio permission in Privacy & Security settings.
- Quit and reopen EdgeBeat after granting access.
- Verify that Spotify or Music is producing audible output.

When a player-specific Core Audio tap cannot be created, EdgeBeat attempts a
system-wide audio-capture fallback.

### The lock-screen card does not appear

- Enable `Lock Screen Now Playing` before locking the Mac.
- Keep a supported track playing or paused.
- Confirm that the main display is active.
- Restart EdgeBeat after a macOS update.

The lock-screen implementation depends on private SkyLight APIs and may require an
application update when Apple changes window-server behavior.

### Build fails because of an SDK mismatch

The build script automatically selects the oldest installed macOS SDK to avoid
common Command Line Tools compatibility issues. A specific SDK can be supplied
manually:

```sh
EDGEBEAT_SDKROOT=/path/to/MacOSX.sdk bash scripts/build.sh
```

For a clean rebuild:

```sh
rm -rf .build EdgeBeat.app
bash scripts/build.sh
```

## Development

### Build commands

```sh
swift build
bash scripts/build.sh
bash scripts/run.sh
```

`swift build` validates the Swift target. `scripts/build.sh` must be used to create
a complete application bundle with the icon, Info.plist, MediaRemoteAdapter, and
license notice.

To sign with a specific local identity instead of ad-hoc signing:

```sh
EDGEBEAT_SIGN_ID="Developer ID Application: Example" bash scripts/build.sh
```

### Architecture

```text
Player metadata -> NowPlayingMonitor -> RenderState -> EdgeGlowView
Player audio    -> AudioTapEngine    -> BeatAnalyzer -> RenderState
Preferences     -> AppPreferences    -> Menu and overlay updates
```

Important components:

- `AppDelegate.swift` wires the application lifecycle and playback pipeline.
- `NowPlayingMonitor.swift` handles player detection, polling, and fallbacks.
- `MediaRemoteAdapter.swift` reads system Now Playing metadata and sends controls.
- `AudioTapEngine.swift` captures player or system audio through Core Audio.
- `BeatAnalyzer.swift` derives waveform, level, and beat information using vDSP.
- `PaletteExtractor.swift` extracts display colors from album artwork.
- `EdgeGlowView.swift` renders the edge and notch-aware wave contours.
- `OverlayPanel.swift` manages full-screen, multi-display, and lock-screen windows.
- `SkyLightLockBridge.swift` delegates windows into the private lock-screen Space.

## Privacy

- Audio samples are processed locally in memory.
- EdgeBeat does not access the microphone.
- EdgeBeat does not save captured audio.
- Track metadata and artwork are used only to render the interface.
- Spotify artwork may be downloaded from the artwork URL when the fallback path is
  active.
- EdgeBeat does not upload listening history or captured audio.

## Compatibility Notes

EdgeBeat relies on two implementation details that are not public macOS APIs:

- MediaRemote access through the open-source MediaRemoteAdapter workaround
- Lock-screen window placement through private SkyLight symbols

These features currently work on the supported development environment but may
require maintenance after macOS updates. They may also prevent distribution through
the Mac App Store.

## Third-Party Software

EdgeBeat includes MediaRemoteAdapter by Jonas van den Berg and contributors. It is
distributed under the BSD 3-Clause License. The complete notice is available in
`Resources/MediaRemoteAdapter.LICENSE` and is copied into every application bundle.

The lock-screen implementation was informed by the open-source
[BoringNotch](https://github.com/TheBoredTeam/boring.notch) and
[SkyLightWindow](https://github.com/Lakr233/SkyLightWindow) projects.

## Project License

EdgeBeat is open-source software released under the
[MIT License](LICENSE). Copyright (c) 2026 Chaitanya Sai Meka.
