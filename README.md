# RateFollower

Menu-bar app that switches the default output device's sample rate and bit depth
to match the track Apple Music is playing, like doing it by hand in Audio MIDI Setup.

The menu bar shows the device's current format as `rate/bits` (e.g. `96/24`, `44.1/16`). Click it to
see the device name, its output format, and the format of the last track Music started.

## Why not LosslessSwitcher

LosslessSwitcher finds the track format by querying `OSLogStore` for the last 5 seconds
of logs, 5–6 times per track change. Each query reads the on-disk log archive. On a
machine with endpoint security software that hooks file I/O, one query measured
10.3 s cold / ~1.25 s warm, so queries back up and the 5-second window misses the
track-start message — it stops switching after a few songs.

RateFollower keeps one `log stream` subscription with a tight predicate and blocks
in `read()` until Music logs a new format:

```
[SampleRate 96000] [BitDepth 24]          (com.apple.coremedia, once per track start)
Creating AudioQueue … sampleRate:96000     (fallback, rate only)
```

No polling, no archive reads, no work on the main thread. Measured idle cost ≈ 0 CPU;
switching happens within milliseconds of Music logging the format.

## Build & install

```bash
scripts/build-app.sh --install
```

Builds `build/RateFollower.app`, copies it to `~/Applications`, and launches it.
Enable **Open at Login** from its menu. Quit LosslessSwitcher first — two switchers fight.

Debug output: run `~/Applications/RateFollower.app/Contents/MacOS/RateFollower` from a terminal.

**Requirements:** a Swift 5.9+ compiler and a macOS SDK — Command Line Tools are enough
(`xcode-select --install`); Xcode is not needed. The script calls `swiftc` per architecture
and merges with `lipo`, so there is no SwiftPM/xcbuild step. The result is a ~400 KB universal app that links only system frameworks
(AppKit, CoreAudio, ServiceManagement) and the OS's built-in Swift runtime; runs on macOS 13+.

**With Xcode:** `open Package.swift` and run the `RateFollower` scheme, or `swift build`.
That gives a bare executable for iterating; use the script above for the installable app
(Open at Login needs the bundle).

## Layout

| File | Role |
|---|---|
| `FormatMonitor.swift` | `log stream` subscription and line parsing |
| `Engine.swift` | switching state, device-change listeners (own serial queue) |
| `CoreAudio.swift` | CoreAudio reads/writes, format choice, formatting |
| `StatusController.swift` | menu-bar item and menu |

## Caveats

- Depends on Music's log wording; an Apple Music update could change it.
- Not yet verified whether Music logs the *next* track's format early during gapless
  preloading (which would switch slightly before the song changes).
