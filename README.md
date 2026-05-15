# Hush

Menu-bar app that closes apps you're not using.

Fork of [BigBerny/magicquit](https://github.com/BigBerny/magicquit) (after [ccarpiog/magicquit](https://github.com/ccarpiog/magicquit)). Stripped down, redesigned, no telemetry, no accounts, no network calls.

## What it does

- Tick the apps you want closed when idle. Pick a threshold (15 min to 72 h). Hush kills them when they've been out of sight that long.
- Focus session: 25/50/90 min button in the popover, or `⌥⌘H` from anywhere. Closes everything checked except the front app and tightens the idle threshold to 30s for the duration.
- Optional: mirror macOS Focus modes (DND, Work, custom). Turning on a Focus auto-starts a Hush session and ends it when the Focus turns off.
- By default `terminate()`-quits, so apps with unsaved data show a save dialog. There's a force-quit toggle if you want it more aggressive (escalates to SIGKILL after 4s for stuck apps like Office).
- Per-app RAM dot (green/amber/red), tooltip with actual figure.
- Battery-aware: halves the idle threshold when on battery below 30%.
- Quit on display sleep (lid close, idle, menu Sleep).
- Auto-check newly launched apps (off by default).

## Install

```bash
brew install adis-b/hush/hush
```

Or grab the DMG from [Releases](https://github.com/adis-b/hush/releases).

First launch is blocked by Gatekeeper because the build is ad-hoc signed, not notarized. Either go to System Settings → Privacy & Security and click "Open Anyway", or in Terminal:

```bash
xattr -dr com.apple.quarantine /Applications/Hush.app
open -a Hush
```

## Build

```bash
xcodebuild -scheme Hush -configuration Release build
# or
open Hush.xcodeproj
```

macOS 13.3+, Swift 5. One SPM dep: [LaunchAtLogin-Modern](https://github.com/sindresorhus/LaunchAtLogin-Modern).

## License

GPLv3, same as upstream.
