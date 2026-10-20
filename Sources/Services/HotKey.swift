import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Registers a single system-wide hotkey through Carbon (no Accessibility permission required).
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    var handler: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerInstalled = false

    func registerFromDefaults() {
        let d = UserDefaults.standard
        register(keyCode: UInt32(d.integer(forKey: Prefs.hotKeyCode)), modifiers: UInt32(d.integer(forKey: Prefs.hotKeyMods)))
    }

    func register(keyCode: UInt32, modifiers: UInt32) {
        unregister()
        if !handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { HotKeyCenter.shared.handler?() }
                return noErr
            }, 1, &spec, nil, nil)
            handlerInstalled = true
        }
        let id = EventHotKeyID(signature: OSType(0x5247_4946), id: 1) // "RGIF"
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }
}

/// Settings control that captures the next key combination and stores it as the global hotkey.
struct HotKeyRecorder: View {
    @AppStorage(Prefs.hotKeyCode) private var keyCode = 5
    @AppStorage(Prefs.hotKeyMods) private var modifiers = 4096 | 512
    @AppStorage(Prefs.hotKeyLabel) private var label = "⌃⇧G"
    @State private var monitor: Any?

    var body: some View {
        Button(monitor == nil ? label : "Type shortcut… (Esc cancels)") {
            monitor == nil ? startListening() : stopListening()
        }
        .monospacedDigit()
        .onDisappear(perform: stopListening)
    }

    private func startListening() {
        HotKeyCenter.shared.unregister()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) { stopListening(); return nil }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !flags.intersection([.command, .option, .control]).isEmpty else { NSSound.beep(); return nil }
            keyCode = Int(event.keyCode)
            modifiers = Self.carbonFlags(flags)
            label = Self.symbols(flags) + Self.keyName(event)
            stopListening()
            return nil
        }
    }

    private func stopListening() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        HotKeyCenter.shared.registerFromDefaults()
    }

    private static func carbonFlags(_ flags: NSEvent.ModifierFlags) -> Int {
        var result = 0
        if flags.contains(.command) { result |= cmdKey }
        if flags.contains(.option) { result |= optionKey }
        if flags.contains(.control) { result |= controlKey }
        if flags.contains(.shift) { result |= shiftKey }
        return result
    }

    private static func symbols(_ flags: NSEvent.ModifierFlags) -> String {
        (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
    }

    private static func keyName(_ event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        default: return event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
        }
    }
}
