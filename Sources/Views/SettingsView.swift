import SwiftUI
import AppKit
import ServiceManagement

/// Hosts the SwiftUI settings in a plain AppKit window, which is reliable for a menu-bar-only app.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "RegionGifRecorder Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Recording, output and general preferences, all persisted via `@AppStorage`.
struct SettingsView: View {
    @AppStorage(Prefs.fps) private var fps = 15
    @AppStorage(Prefs.maxWidth) private var maxWidth = 800
    @AppStorage(Prefs.maxDuration) private var maxDuration = 15
    @AppStorage(Prefs.showCursor) private var showCursor = true
    @AppStorage(Prefs.loopCount) private var loopCount = 0
    @AppStorage(Prefs.countdown) private var countdown = true
    @AppStorage(Prefs.outputFolder) private var outputFolder = Prefs.defaultFolder
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var hasPermission = CGPreflightScreenCaptureAccess()

    var body: some View {
        Form {
            Section("Recording") {
                LabeledContent("Record hotkey") { HotKeyRecorder() }
                Picker("Frame rate", selection: $fps) {
                    ForEach([10, 15, 20], id: \.self) { Text("\($0) fps").tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("Max width") {
                    HStack {
                        TextField("", value: $maxWidth, format: .number.grouping(.never))
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                        Text("px (0 = full resolution)").foregroundStyle(.secondary)
                    }
                }
                Stepper("Max duration: \(maxDuration) s", value: $maxDuration, in: 3...30)
                Stepper(loopCount == 0 ? "Loop: forever" : "Loop: \(loopCount)×", value: $loopCount, in: 0...10)
                Toggle("3-second countdown before recording", isOn: $countdown)
                Toggle("Show mouse cursor", isOn: $showCursor)
                sizeEstimate
            }

            Section("Output") {
                LabeledContent("Save to") {
                    HStack {
                        Text((outputFolder as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1).truncationMode(.middle)
                        Button("Choose…", action: chooseFolder)
                    }
                }
                Text("Each GIF gets a timestamped name and is also copied to the clipboard.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                LabeledContent("Screen Recording") {
                    if hasPermission {
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Grant Access…") {
                            hasPermission = CGRequestScreenCaptureAccess()
                            if !hasPermission, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            }

            Section {
                HStack {
                    Text("RegionGifRecorder is free and open source.")
                    Spacer()
                    Button("Support / Donate ❤️") { Support.open() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var sizeEstimate: some View {
        let mb = Prefs.estimatedMB(maxWidth: maxWidth, fps: fps, seconds: maxDuration)
        return HStack {
            Image(systemName: mb > 15 ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(mb > 15 ? .orange : .secondary)
            Text(String(format: "Worst case ≈ %.0f MB for a full-length, full-width recording.", mb)
                 + (mb > 15 ? " Consider a lower width or frame rate." : ""))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: outputFolder)
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { outputFolder = url.path }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn't update login item: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
