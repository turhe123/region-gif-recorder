import SwiftUI
import AppKit

/// The status-bar icon: a plain symbol when idle, a red dot plus elapsed time while recording.
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        switch model.phase {
        case .recording:
            Image(nsImage: Self.badge(model.elapsedText))
        case .countdown(let n):
            Image(nsImage: Self.badge("\(n)…"))
        case .saving:
            Image(systemName: "hourglass")
        case .idle, .selecting:
            Image(systemName: "record.circle")
        }
    }

    /// Non-template image so the menu bar keeps it red.
    private static func badge(_ text: String) -> NSImage {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.systemRed,
        ]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let size = NSSize(width: 16 + textSize.width, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: 1, y: 4, width: 10, height: 10)).fill()
            (text as NSString).draw(at: NSPoint(x: 15, y: (18 - textSize.height) / 2), withAttributes: attrs)
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// Menu items: record/stop, recent recordings, settings, donation and quit.
struct MenuContent: View {
    @ObservedObject var model: AppModel
    @AppStorage(Prefs.hotKeyLabel) private var hotKey = "⌃⇧G"

    var body: some View {
        Button("Record Region   \(hotKey)") { model.beginSelection() }
            .disabled(model.phase != .idle)
        Button(stopTitle) { model.toggle() }
            .disabled(!canStop)

        Divider()
        Text("Recent Recordings")
        if model.recents.isEmpty {
            Text("Nothing recorded yet")
        } else {
            ForEach(model.recents, id: \.self) { url in
                Button(url.lastPathComponent) { model.reveal(url) }
            }
            Button("Clear History") { model.clearRecents() }
        }

        Divider()
        Button("Settings…") { SettingsWindowController.shared.show() }
            .keyboardShortcut(",")
        Button("Support / Donate ❤️") { Support.open() }
        Divider()
        Button("Quit RegionGifRecorder") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var canStop: Bool {
        switch model.phase {
        case .recording, .countdown: return true
        default: return false
        }
    }

    private var stopTitle: String {
        switch model.phase {
        case .recording: return "Stop Recording (\(model.elapsedText))"
        case .countdown: return "Cancel Countdown"
        default: return "Stop"
        }
    }
}
