import AppKit

/// Covers every display with a dimmed overlay and reports the rectangle the user drags (global coordinates).
@MainActor
final class RegionSelector {
    private var windows: [NSWindow] = []
    private var finished = false
    private let completion: (NSRect?, NSScreen?) -> Void

    init(completion: @escaping (NSRect?, NSScreen?) -> Void) {
        self.completion = completion
    }

    func begin() {
        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            let window = KeyableWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.acceptsMouseMovedEvents = true
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.scale = screen.backingScaleFactor
            view.onFinish = { [weak self] rect in
                self?.finish(rect.map { $0.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY) }, screen)
            }
            window.contentView = view
            window.setFrame(screen.frame, display: true)
            if screen.frame.contains(mouse) {
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(view)
            } else {
                window.orderFrontRegardless()
            }
            windows.append(window)
        }
        NSCursor.crosshair.push()
    }

    func cancel() { finish(nil, nil) }

    private func finish(_ rect: NSRect?, _ screen: NSScreen?) {
        guard !finished else { return }
        finished = true
        NSCursor.pop()
        windows.forEach { $0.orderOut(nil) }
        windows = []
        completion(rect, screen)
    }
}

/// Borderless windows refuse key status by default; the overlay needs it for Esc.
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// Draws the dim layer, crosshair, selection hole and a live pixel-size label.
final class SelectionView: NSView {
    var onFinish: ((NSRect?) -> Void)?
    var scale: CGFloat = 2
    private var start: NSPoint?
    private var current: NSPoint?
    private var mouse: NSPoint?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self))
        super.updateTrackingAreas()
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    private var selection: NSRect? {
        guard let start, let current else { return nil }
        return NSRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(current.x - start.x), height: abs(current.y - start.y))
    }

    private func clamp(_ p: NSPoint) -> NSPoint {
        NSPoint(x: min(max(p.x, 0), bounds.maxX), y: min(max(p.y, 0), bounds.maxY))
    }

    override func mouseMoved(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        start = clamp(convert(event.locationInWindow, from: nil))
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = clamp(convert(event.locationInWindow, from: nil))
        mouse = current
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        onFinish?(selection?.integral)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(nil) } else { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        if let mouse {
            NSColor.white.withAlphaComponent(0.5).setFill()
            NSRect(x: mouse.x.rounded(), y: 0, width: 1, height: bounds.height).fill()
            NSRect(x: 0, y: mouse.y.rounded(), width: bounds.width, height: 1).fill()
        }
        guard let rect = selection else { return }
        NSColor.clear.setFill()
        rect.fill(using: .copy)
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        border.stroke()

        let text = "\(Int(rect.width * scale)) × \(Int(rect.height * scale))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attrs)
        var origin = NSPoint(x: rect.maxX - size.width - 8, y: rect.minY - size.height - 10)
        if origin.y < 4 { origin.y = rect.minY + 6 }
        origin.x = max(4, origin.x)
        let pill = NSRect(x: origin.x - 6, y: origin.y - 3, width: size.width + 12, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 5, yRadius: 5).fill()
        text.draw(at: origin, withAttributes: attrs)
    }
}

/// Click-through red frame drawn just outside the recorded region; also shows the countdown.
final class OutlineWindow: NSPanel {
    private let outlineView = OutlineView()

    init(region: NSRect) {
        super.init(contentRect: region.insetBy(dx: -4, dy: -4), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .statusBar
        sharingType = .none
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        contentView = outlineView
    }

    func setCountdown(_ value: Int?) {
        outlineView.countdown = value
        outlineView.needsDisplay = true
    }
}

/// Renders the outline stroke and an optional large countdown digit.
final class OutlineView: NSView {
    var countdown: Int?

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        path.lineWidth = 3
        path.stroke()
        guard let countdown else { return }
        let circle = NSRect(x: bounds.midX - 45, y: bounds.midY - 45, width: 90, height: 90)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(ovalIn: circle).fill()
        let text = "\(countdown)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 52, weight: .bold), .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attrs)
    }
}
