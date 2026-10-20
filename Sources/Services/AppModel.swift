import AppKit
import UserNotifications

/// UserDefaults keys and defaults shared by `@AppStorage` views and the recording pipeline.
enum Prefs {
    static let fps = "fps"
    static let maxWidth = "maxWidth"
    static let maxDuration = "maxDuration"
    static let showCursor = "showCursor"
    static let loopCount = "loopCount"
    static let countdown = "useCountdown"
    static let outputFolder = "outputFolder"
    static let hotKeyCode = "hotKeyCode"
    static let hotKeyMods = "hotKeyMods"
    static let hotKeyLabel = "hotKeyLabel"
    static let recents = "recentRecordings"

    static var defaultFolder: String {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory()
    }

    static func register() {
        UserDefaults.standard.register(defaults: [
            fps: 15, maxWidth: 800, maxDuration: 15, showCursor: true, loopCount: 0, countdown: true,
            outputFolder: defaultFolder, hotKeyCode: 5, hotKeyMods: 4096 | 512, hotKeyLabel: "⌃⇧G",
        ])
    }

    /// Rough upper bound of the GIF size in megabytes for a full-width 16:10 region.
    static func estimatedMB(maxWidth: Int, fps: Int, seconds: Int) -> Double {
        let w = Double(maxWidth > 0 ? maxWidth : 1600)
        return w * w * 0.625 * Double(fps * seconds) * 0.12 / 1_000_000
    }
}

/// Drives the record flow (select → countdown → capture → encode → save) and owns recent history.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum Phase: Equatable { case idle, selecting, countdown(Int), recording, saving }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var elapsed = 0
    @Published private(set) var recents: [URL] = []

    private let defaults = UserDefaults.standard
    private var selector: RegionSelector?
    private var outline: OutlineWindow?
    private var recorder: ScreenRecorder?
    private var countdownTask: Task<Void, Never>?
    private var timer: Timer?
    private var startDate = Date()
    private var displayID: CGDirectDisplayID = 0
    private var screenObserver: NSObjectProtocol?

    private init() {
        recents = (defaults.stringArray(forKey: Prefs.recents) ?? []).map { URL(fileURLWithPath: $0) }
    }

    var elapsedText: String { String(format: "%d:%02d", elapsed / 60, elapsed % 60) }

    /// Hotkey behaviour: start a selection when idle, otherwise stop or cancel what is running.
    func toggle() {
        switch phase {
        case .idle: beginSelection()
        case .selecting: selector?.cancel()
        case .countdown: cancelCountdown()
        case .recording: stop(reason: nil)
        case .saving: NSSound.beep()
        }
    }

    func beginSelection() {
        guard phase == .idle, ensurePermission() else { return }
        phase = .selecting
        let selector = RegionSelector { [weak self] rect, screen in
            self?.selector = nil
            self?.didSelect(rect, on: screen)
        }
        self.selector = selector
        selector.begin()
    }

    private func didSelect(_ rect: NSRect?, on screen: NSScreen?) {
        guard let rect, let screen else { phase = .idle; return }
        guard rect.width >= 20, rect.height >= 20 else { phase = .idle; NSSound.beep(); return }
        let outline = OutlineWindow(region: rect)
        outline.orderFrontRegardless()
        self.outline = outline
        let useCountdown = defaults.bool(forKey: Prefs.countdown)
        countdownTask = Task { [weak self] in
            if useCountdown {
                for n in stride(from: 3, through: 1, by: -1) {
                    self?.phase = .countdown(n)
                    outline.setCountdown(n)
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled { return }
                }
                outline.setCountdown(nil)
            }
            await self?.startRecording(region: rect, screen: screen)
        }
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        closeOutline()
        phase = .idle
    }

    private func startRecording(region: NSRect, screen: NSScreen) async {
        guard let id = screen.displayID else { fail("Couldn't identify the selected display."); return }
        let scale = screen.backingScaleFactor
        var size = CGSize(width: region.width * scale, height: region.height * scale)
        let maxWidth = CGFloat(defaults.integer(forKey: Prefs.maxWidth))
        if maxWidth >= 50, size.width > maxWidth {
            size = CGSize(width: maxWidth, height: size.height * maxWidth / size.width)
        }
        let local = CGRect(x: region.minX - screen.frame.minX, y: screen.frame.maxY - region.maxY,
                           width: region.width, height: region.height)
        let recorder = ScreenRecorder()
        recorder.onStop = { error in
            Task { @MainActor in
                AppModel.shared.stop(reason: "Capture ended unexpectedly (\(error.localizedDescription)). The frames captured so far were saved.")
            }
        }
        do {
            try await recorder.start(displayID: id, sourceRect: local,
                                     size: CGSize(width: size.width.rounded(), height: size.height.rounded()),
                                     fps: max(1, defaults.integer(forKey: Prefs.fps)),
                                     showsCursor: defaults.bool(forKey: Prefs.showCursor))
        } catch {
            recorder.cleanup()
            fail("Couldn't start recording: \(error.localizedDescription)")
            return
        }
        self.recorder = recorder
        displayID = id
        phase = .recording
        startDate = Date()
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            Task { @MainActor in AppModel.shared.tick() }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in AppModel.shared.checkDisplayStillConnected() }
        }
    }

    private func tick() {
        guard phase == .recording else { return }
        let seconds = Int(Date().timeIntervalSince(startDate))
        if seconds != elapsed { elapsed = seconds }
        let limit = max(1, defaults.integer(forKey: Prefs.maxDuration))
        if Date().timeIntervalSince(startDate) >= Double(limit) {
            stop(reason: "Reached the \(limit)-second maximum duration, so recording stopped automatically.")
        }
    }

    private func checkDisplayStillConnected() {
        guard phase == .recording else { return }
        if !NSScreen.screens.contains(where: { $0.displayID == displayID }) {
            stop(reason: "The display was disconnected. The frames captured so far were saved.")
        }
    }

    /// Stops capture and encodes the GIF in the background; `reason` explains automatic stops.
    func stop(reason: String?) {
        guard phase == .recording, let recorder else { return }
        phase = .saving
        self.recorder = nil
        timer?.invalidate()
        timer = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        closeOutline()
        let folder = URL(fileURLWithPath: defaults.string(forKey: Prefs.outputFolder) ?? Prefs.defaultFolder)
        let loops = defaults.integer(forKey: Prefs.loopCount)
        let fps = max(1, defaults.integer(forKey: Prefs.fps))
        Task {
            let frames = await recorder.stop()
            do {
                let url = try await Task.detached {
                    try GifEncoder.write(frames: frames, scratch: recorder.tempDir, folder: folder, loopCount: loops, fps: fps)
                }.value
                finished(url, reason: reason, dropped: recorder.droppedFrames)
            } catch {
                fail("Couldn't save the GIF: \(error.localizedDescription)")
            }
            recorder.cleanup()
            phase = .idle
        }
    }

    private func finished(_ url: URL, reason: String?, dropped: Int) {
        recents.removeAll { $0 == url }
        recents.insert(url, at: 0)
        recents = Array(recents.prefix(10))
        defaults.set(recents.map(\.path), forKey: Prefs.recents)

        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])

        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        var body = "\(url.lastPathComponent) (\(size)) was copied to the clipboard."
        if bytes > 15_000_000 { body += " ⚠️ This GIF is large — try a lower frame rate or max width." }
        if dropped > 0 { body += " \(dropped) frames were skipped to keep up." }
        if let reason { body = reason + "\n" + body }
        Notifier.post(title: "GIF saved", body: body, file: url)
    }

    func reveal(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            recents.removeAll { $0 == url }
            defaults.set(recents.map(\.path), forKey: Prefs.recents)
            fail("“\(url.lastPathComponent)” no longer exists.")
        }
    }

    func clearRecents() {
        recents = []
        defaults.removeObject(forKey: Prefs.recents)
    }

    private func closeOutline() {
        outline?.orderOut(nil)
        outline = nil
    }

    private func fail(_ message: String) {
        closeOutline()
        phase = .idle
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "RegionGifRecorder"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    /// Screen Recording permission: asks once, then explains how to grant it in System Settings.
    private func ensurePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() { return true }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission needed"
        alert.informativeText = "Enable RegionGifRecorder in System Settings › Privacy & Security › Screen & System Audio Recording, then quit and reopen the app."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        return false
    }
}

/// Posts local notifications with a "Reveal in Finder" action.
enum Notifier {
    static let category = "GIF_SAVED"

    static func setup(delegate: UNUserNotificationCenterDelegate) {
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        let reveal = UNNotificationAction(identifier: "REVEAL", title: "Reveal in Finder", options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: category, actions: [reveal],
                                                                 intentIdentifiers: [], options: [])])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String, file: URL) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        content.userInfo = ["path": file.path]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
