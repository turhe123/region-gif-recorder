# RegionGifRecorder — specification

**Tagline:** Drag a region, record the screen, and save a small looping GIF with one hotkey and a live menu bar timer.

**Category:** Screen & OCR

**Inspired by (paid):** Gifox ($14.99 one-time)

**Frameworks:** SwiftUI, AppKit, ScreenCaptureKit, ImageIO, UniformTypeIdentifiers, CoreGraphics, ServiceManagement

**Donation URL (Support button):** https://ko-fi.com/leodavidai

## Spec

What the paid app does: Gifox is a long-running Mac app that records any part of the screen into GIFs and short videos, sold at about 14.99 dollars with a strong review history and constant recommendation for bug reports, docs and chat replies. Our free clean-room version covers region to GIF with sensible compression.

Feature set: A global hotkey lets the user drag a rectangle on screen, then recording starts after a three second countdown or immediately by choice. Pressing the hotkey again or clicking the menu bar item stops it. Settings control frame rate of 10, 15 or 20 frames per second, a maximum width that scales the output down, a maximum duration up to 30 seconds, whether to show the cursor, and loop count. After stopping, the GIF is written to a chosen folder with a timestamped name, copied to the clipboard as a file, and a notification offers Reveal in Finder. A small history list of the last ten recordings sits in the menu.

UI spec: MenuBarExtra whose icon turns red with an elapsed time label while recording. The menu shows Record Region, Stop, recent recordings with a click to reveal, and Settings. Region selection uses a dimmed overlay with a crosshair and a live size label. While recording, a thin red outline window marks the region and is excluded from capture. The Settings window has the hotkey recorder, frame rate picker, max width field, max duration stepper, output folder chooser, cursor toggle, and launch at login. Empty state: recent recordings area says nothing recorded yet.

Technical approach: Use SCStream with an SCContentFilter for the chosen display and a sourceRect set to the selected region, with the configured frame interval and the pixel format of BGRA. Receive sample buffers on a queue, convert each to a CGImage through a CIContext or CGBitmapContext, downscale to the max width, and append it to a CGImageDestination created with the GIF type from UniformTypeIdentifiers, setting a per-frame delay and loop count properties. Because ImageIO needs the frame count in advance, create the destination with a generous count, or write frames to a temporary array of JPEG data on disk and finalize at stop to bound memory. Request permission via CGRequestScreenCaptureAccess. The hotkey uses Carbon. The clipboard receives a file URL through NSPasteboard writeObjects. Settings are stored with AppStorage, and launch at login with SMAppService.

Edge cases and error handling: Enforce the maximum duration by stopping automatically and telling the user. If the region is under 20 pixels, cancel. If disk write fails, show an alert with the reason. Handle display disconnection mid recording by stopping and saving what exists. Warn when the estimated size is large. Skip frames when the encoder falls behind instead of ballooning memory. Aim for about 550 lines.
