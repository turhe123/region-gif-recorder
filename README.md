# RegionGifRecorder

Drag a region, record the screen, and save a small looping GIF with one hotkey and a live menu bar timer.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)
![License MIT](https://img.shields.io/badge/License-MIT-green)
![GitHub release](https://img.shields.io/github/v/release/turhe123/region-gif-recorder)

## Why

RegionGifRecorder is a free, open-source, 100% native, backend-free alternative to paid utilities in the *Screen & OCR* category. It was inspired by Gifox ($14.99 one-time), a long-standing Mac GIF recorder, and covers the core workflow of turning a screen region into a GIF with sensible compression.

## Features

- **Global hotkey** (default `⌃⇧G`, rebindable in Settings) starts region selection; pressing it again stops the recording.
- **Region selection** with a dimmed overlay, crosshair cursor and a live pixel-size label. `Esc` cancels; regions under 20 px are discarded.
- **Optional 3-second countdown** before recording starts, shown in the menu bar.
- **Live menu bar timer**: the icon turns into a red dot with elapsed time while recording.
- **Red outline** around the recorded region, excluded from the capture.
- **Capture with ScreenCaptureKit**, with a configurable frame rate (10, 15 or 20 fps), max width (scales output down; 0 = full resolution), max duration (3–30 s) and optional mouse cursor.
- **Loop count** setting: forever or 1–10 times.
- **Bounded memory**: frames are spooled to disk as JPEGs and assembled into the GIF on stop. Frames are skipped when the encoder falls behind.
- **Accurate timing**: per-frame delays come from capture timestamps.
- **Saved and copied**: GIFs get a timestamped name in your chosen folder (Desktop by default) and are copied to the clipboard as a file.
- **Notification** when a GIF is saved, with a *Reveal in Finder* action.
- **Recent recordings**: the last ten appear in the menu; click one to reveal it.
- **Safety nets**: auto-stop at the max duration, saves what exists if the display disconnects, and warns when the GIF is large (over about 15 MB) or the settings could produce a large one.
- **Launch at login** and a **Support / Donate ❤️** button in the menu and Settings.

## Screenshots

_Screenshots coming soon._

## Install

1. Download `RegionGifRecorder-macOS.zip` from the [latest release](https://github.com/turhe123/region-gif-recorder/releases/latest).
2. Unzip it and move `RegionGifRecorder.app` to `/Applications`.
3. Because the app is open source and not notarized, clear the quarantine flag:

   ```bash
   xattr -cr /Applications/RegionGifRecorder.app
   ```

4. Right-click the app and choose **Open** the first time you launch it.

## Build from source

Requires macOS 14+ and Xcode with Swift 5.9+.

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project RegionGifRecorder.xcodeproj -scheme RegionGifRecorder -configuration Release -derivedDataPath ./build build
```

The app is produced at `build/Build/Products/Release/RegionGifRecorder.app`.

## Permissions

- **Screen Recording** (required): used by ScreenCaptureKit to capture the selected region. The app asks the first time you record; after granting it in System Settings › Privacy & Security, quit and reopen the app. Settings shows the current status.
- **Notifications** (optional): used to tell you when a GIF is saved and to offer *Reveal in Finder*.
- **Accessibility**: not needed. The global hotkey uses Carbon's hotkey registration.
- **Microphone**: not needed. The app records video only, with no audio.

## Built with AI

RegionGifRecorder was written by [Claude Code](https://claude.com/claude-code) inside an automated pipeline, from a plain-English spec. No code, binaries or assets from any commercial app were used; it is a clean-room reimplementation of a feature set, not a copy.

What that means in practice:

- The full source is in this repo under the MIT license. Read it before you run it.
- No network calls, no analytics, no third-party dependencies. Only Apple frameworks.
- Ad-hoc signed and not notarized, which is why Gatekeeper warns on first launch.
- It has had less human review than a hand-written app. Bug reports and pull requests are welcome.

## Support ❤️

If this app is useful to you, you can support its development:

[Support Or (Leo) Davidai ❤️ on Ko-fi](https://ko-fi.com/leodavidai)

## License

MIT © Or Davidai Bachar
