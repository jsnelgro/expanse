import AppKit

/// A real window for each frame, so window switchers (AltTab, Mission Control) list frames by
/// name next to app windows: picking one goes into the frame (see CanvasController.goInto). Each
/// sits parked in the screen corner, as Expanse parks windows out of view, with only a sliver
/// showing; its picture, which switchers show, is the frame's name.
final class FrameWindows: NSObject, NSWindowDelegate {
    /// A frame's window was picked (it became key).
    var onPick: ((String) -> Void)?
    private var windows: [String: FrameWindow] = [:]
    private var hidden = false

    /// One window per frame, titled with its name, at `corner` (global CG coordinates: where
    /// its top-left goes).
    func update(_ frames: [Frame], corner: CGPoint) {
        let ids = Set(frames.map(\.id))
        for (id, w) in windows where !ids.contains(id) {
            w.orderOut(nil)
            windows.removeValue(forKey: id)
        }
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        for f in frames {
            let w = windows[f.id] ?? {
                let w = FrameWindow(frameID: f.id)
                w.delegate = self
                windows[f.id] = w
                if !hidden { w.orderBack(nil) }
                return w
            }()
            w.show(name: f.name)
            w.setFrameTopLeftPoint(NSPoint(x: corner.x, y: primaryHeight - corner.y))
        }
    }

    /// Paused or quitting: out of the switchers until shown again.
    func setHidden(_ hide: Bool) {
        hidden = hide
        for w in windows.values {
            if hide { w.orderOut(nil) } else { w.orderBack(nil) }
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let w = notification.object as? FrameWindow else { return }
        logger.info("frame window picked: \(w.title, privacy: .public)")
        onPick?(w.frameID)
    }
}

private final class FrameWindow: NSWindow {
    let frameID: String
    private let label = NSTextField(labelWithString: "")

    init(frameID: String) {
        self.frameID = frameID
        super.init(contentRect: CGRect(x: 0, y: 0, width: 480, height: 300), styleMask: [.titled],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        animationBehavior = .none
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        label.font = .systemFont(ofSize: 40, weight: .semibold)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -40),
        ])
        contentView = content
    }

    func show(name: String) {
        if title != name { title = name }
        if label.stringValue != name { label.stringValue = name }
    }

    /// Stays parked: AppKit would otherwise pull a titled window back on screen.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { true }
}
