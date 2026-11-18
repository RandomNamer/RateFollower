# RateFollower — agent context

macOS menu-bar app that switches the default output device's sample rate and bit depth
to match the track Apple Music is playing. Personal replacement for LosslessSwitcher.
`README.md` has the user-facing description; this file is what you need to work on it.

## Why this exists (the constraint that drives every design choice)

It targets Macs where endpoint security software makes file I/O and syscalls very slow.
LosslessSwitcher polls `OSLogStore` (reads the on-disk log archive) 5–6 times per track
change; on such a Mac one query measured 10.3 s cold / ~1.25 s warm against its own 5-second
look-back window, so it stops switching after a few songs.

Hard rules that follow from this:

- **No polling, no timers, no `OSLogStore`, no `log show`.** Detection is push-only.
- **Nothing blocking on the main thread.** All CoreAudio calls go through `Engine.queue`;
  the UI only receives finished snapshots via `Engine.onUpdate` on main.
- **No third-party dependencies.** System frameworks only.

## How detection works

`FormatMonitor` runs one long-lived child: `/usr/bin/log stream` with a predicate on
process `Music`, subsystem `com.apple.coremedia`. It blocks in `read()` and parses two lines:

```
… fpfs_ReportAudioPlaybackThroughFigLog: … [SampleRate 96000] [BitDepth 24]   authoritative: rate + bits
… subaq_buildCAAudioQueue: … Creating AudioQueue with format:'qlac', … sampleRate:96000   rate only
```

The AudioQueue line arrives ~250 ms before the FigLog line. `Engine` debounces it 0.6 s so
the DAC switches once, using the FigLog values when they arrive.

Music often starts a streamed track at a lower quality and upgrades it seconds later
(seen: 44.1/16 → 96/24 after 8 s). Each upgrade logs a fresh AudioQueue + FigLog pair, and
every line is applied (no per-track dedupe), so the DAC follows. The FigLog line can trail
the AudioQueue line by up to ~2.5 s, and can report `[BitDepth 0]` (treated as unknown).
Hi-Res gold deliberately follows Apple Music's line (> 48 kHz, 24-bit), not JAS's 96/24.

Verified on macOS 15 with a USB DAC: switch lands within ~1 ms of the log
line; whole process used ~0.1 s CPU across a test run.

Things already tried and rejected:

- AppleScript `sample rate of current track` — returns 44100 for a track streaming at 96 kHz. Wrong for streamed tracks.
- `com.apple.coreaudio` `ACAppleLosslessDecoder.cpp … Input format:` line (what LosslessSwitcher parses) — still exists and is correct, but only for ALAC; not needed.

## Code map

| File | Role |
|---|---|
| `Sources/RateFollower/main.swift` | App entry; accessory activation policy; SIGTERM/SIGINT → `NSApp.terminate` so the `log stream` child is killed |
| `FormatMonitor.swift` | `log stream` child, line parsing, auto-restart |
| `Engine.swift` | State (`lastTrack`, current device/stream), debounce, CoreAudio listeners for default-device and format changes |
| `CoreAudio.swift` | `CA` helpers, `CA.apply` (format choice + set), `Fmt` strings, `Log` (stderr) |
| `StatusController.swift` | `NSStatusItem` title + menu, Open at Login via `SMAppService` |

Format choice in `CA.apply`: exact rate match among the stream's available physical formats,
same channel count as current, exact bit depth else the deepest available; falls back to
nominal sample rate only. Unsupported rates are left alone (no nearest-rate logic yet).

## Build

Two paths; **keep both working**.

1. **Command-line script (canonical, produces the .app):**
   `scripts/build-app.sh` (add `--install` to copy to `~/Applications` and launch).
   Uses only `swiftc` + `lipo` + `codesign`, so it must stay buildable with Command Line
   Tools alone — do not add SwiftPM, xcodebuild, or Xcode-project steps to it.
2. **Xcode / SwiftPM (for iterating):** `open Package.swift`, or `swift build`, or
   `xcodebuild -scheme RateFollower -destination 'platform=macOS' build`.
   This yields a bare executable, not a bundle: the menu-bar item works, but
   `SMAppService` (Open at Login) needs the bundled app from path 1.

Machine-specific notes (toolchain quirks etc.) belong in an untracked `CLAUDE.local.md`,
not here — this file is public.

## Run and test

- Quit LosslessSwitcher first; two switchers fight over the device.
- Debug: run `build/RateFollower.app/Contents/MacOS/RateFollower` in a terminal; logs go to stderr.
- Drive a track change (this plays audio — pause afterwards):
  `osascript -e 'tell application "Music" to play' -e 'delay 4' -e 'tell application "Music" to next track'`
- Expected stderr: `<device name>: -> 44.1 kHz · 16-bit (track 44.1 kHz · 16-bit)`.
- After killing the app, `pgrep -fl "log stream --style compact"` must print nothing.
- There are no unit tests yet. Line parsing in `FormatMonitor` is the obvious first candidate.

## UI decisions (owner's explicit choices)

- Menu-bar title is `rate/bits` with no units: `44.1/16`, `96/24`.
  Keep it short — a 125 pt title was hidden behind the MacBook notch; ~69 pt fits.
- A `music.note` SF Symbol precedes the title: template (monochrome) normally; icon *and*
  title text turn Hi-Res gold when the device output is > 48 kHz at ≥ 24-bit (Apple's
  "Hi-Res Lossless" line). Two golds, picked by the menu bar's appearance (it flips with
  the wallpaper; KVO on the button's `effectiveAppearance` repaints): dark bar `#F8BD5D`
  (highlight-band peak in the official logo, owner's pick), light bar `#DF9430` (face
  gradient 74% stop, owner's pick). On an inactive second display macOS fades the whole
  status area, and the gold fades to near the bar color; the app can't style that copy per display.
- Click menu: device name, output format, song name (no prefix, cut to 40 chars with `…`), last track format,
  Open at Login, Quit. Keep it simple. The song comes from Music's
  `com.apple.Music.playerInfo` distributed notification (push, no AppleScript polling).

## Open questions / next ideas

- Gapless preloading: does Music log the *next* track's format seconds early? If so the
  DAC would switch before the song changes. Untested.
- Nearest-rate fallback when the device lacks the track's rate (LosslessSwitcher has this).
- Device picker (currently always follows the default output device).
- Upstream: vincentneo/LosslessSwitcher PR #235 attempts a similar fix; owner does not
  expect it to merge. This project is the working answer meanwhile.

## Conventions

- Swift 5 language mode, macOS 13+ deployment target, universal (arm64 + x86_64).
- Depends on Apple Music's private log wording. If switching stops after a macOS update,
  check the two log lines first:
  `/usr/bin/log stream --predicate 'process == "Music" AND subsystem == "com.apple.coremedia"'`
- Commit only when asked.
