import AppKit
import Carbon.HIToolbox

/// Draws the canvas and turns trackpad / mouse / keyboard input into camera and window moves.
/// Internally everything is top-left view coordinates; `flip` converts to layer coordinates.
final class CanvasView: NSView {
    weak var controller: CanvasController!

    private let wallpaper = CALayer()
    private let world = CALayer()
    private let labels = CALayer()

    /// App names (and the hovered window's title) above the windows. Off unless chosen in the menu.
    static var showsNames: Bool {
        get { UserDefaults.standard.bool(forKey: "showWindowNames") }
        set { UserDefaults.standard.set(newValue, forKey: "showWindowNames") }
    }
    /// Height of the menu bar strip the wallpaper extends under, so it lines up with the real desktop.
    var menuBarHeight: CGFloat = 0 { didSet { needsLayout = true } }
    private let guides = CAShapeLayer()
    private let marquee = CAShapeLayer()
    private let selectionBox = CAShapeLayer()
    /// Windows picked with a selection box or ⇧-click; dragging one moves them all.
    private(set) var selected = Set<CGWindowID>()
    private var spaceHeld = false
    private let minimap = Minimap()
    private let spacesBar = SpacesBar()
    private lazy var minimapGlass = GlassPanel(content: minimap) { [weak self] in self?.minimap.applyAppearance($0) }
    private lazy var spacesGlass = GlassPanel(content: spacesBar) { [weak self] in self?.spacesBar.applyAppearance($0) }
    var hovered: ManagedWindow?
    /// The frame under the pointer, between its windows (over one, it's that window's frame).
    private var hoveredFrame: Frame?
    /// Frames zoomed out: their boxes, under the windows, with each frame's name above.
    private let frameBoxes = CAShapeLayer()
    private let frameHover = CAShapeLayer()
    private let frameNames = CALayer()
    private var frameNameLayers: [String: CATextLayer] = [:]

    private enum Drag {
        case none
        case pan(last: CGPoint)
        case window(ManagedWindow, startFrame: CGRect, startPoint: CGPoint)
        case frame(Frame, startRect: CGRect, starts: [(ManagedWindow, CGRect)], startPoint: CGPoint)
        case group(clicked: ManagedWindow, starts: [(ManagedWindow, CGRect)], startPoint: CGPoint)
        case marquee(start: CGPoint, base: Set<CGWindowID>)
        case minimap
    }
    private var drag: Drag = .none
    var isDragging: Bool { if case .none = drag { return false } else { return true } }
    private var dragged = false
    /// The drag started with ⌘ held to pick a window in a frame: ⌘ then doesn't turn snapping off.
    private var pickedInFrame = false
    private var lastDragEvent: CFTimeInterval = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        guard let root = layer else { return }
        root.masksToBounds = true
        wallpaper.contentsGravity = .resizeAspectFill
        wallpaper.actions = ["contents": NSNull()]
        // Underneath everything, the minimap and Spaces too when they go under the windows (see render).
        wallpaper.zPosition = -2
        root.addSublayer(wallpaper)
        frameBoxes.lineWidth = 1.5
        frameHover.fillColor = nil
        frameHover.strokeColor = NSColor.controlAccentColor.cgColor
        frameHover.lineWidth = 2
        for l in [frameBoxes, frameHover] {
            l.actions = ["path": NSNull()]
            root.addSublayer(l)
        }
        frameNames.actions = ["sublayers": NSNull()]
        root.addSublayer(frameNames)
        for l in [world, labels, guides] {
            l.actions = ["sublayers": NSNull()]
            root.addSublayer(l)
        }
        guides.fillColor = nil
        guides.strokeColor = NSColor.systemPink.cgColor
        guides.lineWidth = 1
        marquee.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        marquee.strokeColor = NSColor.controlAccentColor.cgColor
        marquee.lineWidth = 1
        selectionBox.fillColor = nil
        selectionBox.strokeColor = NSColor.controlAccentColor.cgColor
        selectionBox.lineWidth = 1
        selectionBox.lineDashPattern = [5, 4]
        for l in [marquee, selectionBox] {
            l.actions = ["path": NSNull()]
            root.addSublayer(l)
        }
        addSubview(spacesGlass)
        addSubview(minimapGlass)
        applyAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        world.anchorPoint = .zero
        for l in [world, labels, guides, marquee, selectionBox, frameBoxes, frameHover, frameNames] { l.frame = bounds }
        // Pinned exactly where the real desktop picture is: the top strip sits under the menu bar.
        wallpaper.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height + menuBarHeight)
        minimapGlass.frame = CGRect(origin: CGPoint(x: bounds.maxX - Minimap.size.width - 16, y: 16), size: Minimap.size)
        placeSpacesBar()
        CATransaction.commit()
        render()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let s = window?.backingScaleFactor ?? 2
        minimap.setContentsScale(s)
        spacesBar.setContentsScale(s)
        controller?.windows.forEach { $0.node.setContentsScale(s) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    /// The Spaces beside the minimap (see SpacesBar).
    func updateSpaces(_ spaces: [Spaces.Space], active: UInt64?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spacesBar.update(spaces: spaces, active: active, wallpaper: wallpaper.contents.map { $0 as! CGImage })
        placeSpacesBar()
        CATransaction.commit()
    }

    private func placeSpacesBar() {
        spacesGlass.isHidden = spacesBar.isHidden
        spacesGlass.frame = CGRect(x: minimapGlass.frame.minX - 12 - spacesBar.bounds.width, y: 16,
                                   width: spacesBar.bounds.width, height: spacesBar.bounds.height)
    }

    func setWallpaper(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wallpaper.contents = image
        wallpaper.isHidden = image == nil
        CATransaction.commit()
        applyAppearance()
    }

    private var hasWallpaper: Bool { wallpaper.contents != nil }

    /// The canvas's own background, behind its copy of the desktop picture (or instead of it).
    private var canvasBackground = NSColor(white: 0.85, alpha: 1).cgColor

    private func applyAppearance() {
        canvasBackground = (isDark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.85, alpha: 1)).cgColor
        // Light over a desktop picture or a dark background, dark over the light grey one.
        let light = hasWallpaper || isDark
        frameBoxes.fillColor = NSColor(white: light ? 1 : 0, alpha: light ? 0.12 : 0.05).cgColor
        frameBoxes.strokeColor = NSColor(white: light ? 1 : 0, alpha: light ? 0.45 : 0.22).cgColor
        render()
        controller?.windows.forEach { styleLabel($0.node.label) }
        frameNameLayers.values.forEach(styleLabel)
    }

    /// White with a shadow over a desktop picture; quiet grey over the plain background.
    private func styleLabel(_ label: CATextLayer) {
        if hasWallpaper {
            label.foregroundColor = NSColor(white: 1, alpha: 0.95).cgColor
            label.shadowColor = NSColor.black.cgColor
            label.shadowOpacity = 0.7
            label.shadowRadius = 2
            label.shadowOffset = CGSize(width: 0, height: -1)
        } else {
            label.foregroundColor = (isDark ? NSColor(white: 0.7, alpha: 1) : NSColor(white: 0.3, alpha: 1)).cgColor
            label.shadowOpacity = 0
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    // MARK: Nodes

    func addNode(_ n: WindowNode) {
        world.addSublayer(n.container)
        labels.addSublayer(n.label)
        styleLabel(n.label)
    }

    func removeNode(_ n: WindowNode) {
        n.container.removeFromSuperlayer()
        n.label.removeFromSuperlayer()
    }

    func bringToFront(_ n: WindowNode) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        world.addSublayer(n.container)
        CATransaction.commit()
    }

    /// Keyboard navigation on the canvas: the highlighted window is the one Return dives into.
    func highlight(_ w: ManagedWindow) {
        hovered?.node.label.string = hovered?.appName
        hovered = w
        w.node.label.string = w.title.isEmpty ? w.appName : "\(w.appName) — \(w.title)"
        render()
    }

    // MARK: Rendering

    func render() {
        guard let c = controller else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        labels.isHidden = !Self.showsNames
        // At 100% the real desktop shows through (see OverlayWindow.backdropLevel); the canvas, and
        // a glide across it, draw their own copy of it.
        wallpaper.isHidden = wallpaper.contents == nil || !c.isActive
        let background = c.isActive ? canvasBackground : NSColor.clear.cgColor
        if layer?.backgroundColor != background { layer?.backgroundColor = background }
        let viewRect = CGRect(origin: .zero, size: bounds.size)
        selected.formIntersection(c.windows.map(\.id))
        if !c.isActive { selected.removeAll() }
        // The camera is one transform on the world layer: window nodes sit in canvas space
        // (y up), so panning and zooming never touch them individually.
        let s = c.camera.scale
        world.sublayerTransform = CATransform3DMakeAffineTransform(
            CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: -s * c.camera.origin.x, ty: bounds.height + s * c.camera.origin.y))
        if !c.isActive { hoveredFrame = nil }
        renderFrames()
        // Hovering a window in a selection shows × on every selected window: it closes them all.
        let groupHovered = hovered.map(isInGroup) ?? false
        for w in c.windows {
            w.node.place(canvasFrame: w.canvasFrame)
            let r = c.camera.toView(w.canvasFrame)
            // In live mode the real window covers its proxy; only parked windows are drawn.
            let visible = r.insetBy(dx: -30, dy: -30).intersects(viewRect) && (c.isActive || w.parked)
            let isSelected = selected.contains(w.id)
            w.node.style(scale: s, hovered: w === hovered, selected: isSelected,
                         showsClose: w === hovered || (groupHovered && isSelected),
                         visible: visible, showsLabel: c.frame(of: w) == nil, screenRect: flip(r))
        }
        let picked = c.windows.filter { selected.contains($0.id) }.map { c.camera.toView($0.canvasFrame) }
        if picked.count > 1, let first = picked.first {
            let box = picked.reduce(first) { $0.union($1) }.insetBy(dx: -8, dy: -8)
            selectionBox.path = CGPath(roundedRect: flip(box), cornerWidth: 6, cornerHeight: 6, transform: nil)
        } else {
            selectionBox.path = nil
        }
        minimap.update(windows: c.windows.map(\.canvasFrame), viewport: c.camera.toCanvas(viewRect), scale: c.camera.scale)
        // Gliding at 100%, the overlay is over the real windows, showing their pictures for a
        // moment: the minimap and Spaces stay under the windows, as they are before and after,
        // rather than jumping in front of them. Zoomed out, they're on top to be clicked.
        minimapGlass.layer?.zPosition = c.gliding ? -1 : 0
        spacesGlass.layer?.zPosition = c.gliding ? -1 : 0
        CATransaction.commit()
    }

    /// The frames' boxes and names, zoomed out. At 100% (gliding included) you're in a frame or
    /// among windows, and the desktop shows as it is.
    private func renderFrames() {
        guard let c = controller else { return }
        let boxes = c.isActive && !c.gliding ? c.frameBoxes() : []
        let lit = hovered.flatMap(c.frame(of:)) ?? hoveredFrame
        let s = c.camera.scale
        let path = CGMutablePath()
        var litPath: CGPath?
        var shown = Set<String>()
        for (f, box) in boxes {
            let r = flip(c.camera.toView(box))
            let radius = max(18 * s, 3)
            path.addRoundedRect(in: r, cornerWidth: radius, cornerHeight: radius)
            if f === lit { litPath = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil) }
            let name = frameNameLayers[f.id] ?? {
                let l = CATextLayer()
                l.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
                l.fontSize = 12
                l.alignmentMode = .left
                l.truncationMode = .end
                l.anchorPoint = .zero
                l.contentsScale = window?.backingScaleFactor ?? 2
                styleLabel(l)
                frameNames.addSublayer(l)
                frameNameLayers[f.id] = l
                return l
            }()
            shown.insert(f.id)
            if name.string as? String != f.name { name.string = f.name }
            let width = max(min(r.width - 8, 320), 0)
            if name.bounds.width != width { name.bounds = CGRect(x: 0, y: 0, width: width, height: 16) }
            name.position = CGPoint(x: r.minX + 6, y: r.maxY + 4)
            name.isHidden = r.width < 80
        }
        for (id, l) in frameNameLayers where !shown.contains(id) {
            l.removeFromSuperlayer()
            frameNameLayers.removeValue(forKey: id)
        }
        frameBoxes.path = boxes.isEmpty ? nil : path
        frameHover.path = litPath
    }

    /// Part of a selection of more than one window (which × and ⌘W close together).
    private func isInGroup(_ w: ManagedWindow) -> Bool {
        selected.count > 1 && selected.contains(w.id)
    }

    /// Close `w`, or the whole selection if `w` is part of it.
    private func close(_ w: ManagedWindow) {
        if isInGroup(w) {
            controller.close(controller.windows.filter { selected.contains($0.id) })
            selected.removeAll()
        } else {
            controller.close([w])
        }
    }

    private func flip(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height)
    }

    private func flip(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: bounds.height - p.y) }

    private func showGuides(_ lines: [(CGPoint, CGPoint)]) {
        let path = CGMutablePath()
        for (a, b) in lines {
            path.move(to: flip(controller.camera.toView(a)))
            path.addLine(to: flip(controller.camera.toView(b)))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        guides.path = lines.isEmpty ? nil : path
        CATransaction.commit()
    }

    // MARK: Event helpers

    /// Event location in top-left view coordinates.
    private func point(_ e: NSEvent) -> CGPoint {
        flip(convert(e.locationInWindow, from: nil))
    }

    private func minimapPoint(_ e: NSEvent) -> CGPoint? {
        guard let root = layer else { return nil }
        let p = minimap.convert(convert(e.locationInWindow, from: nil), from: root)
        return minimap.bounds.contains(p) ? p : nil
    }

    /// Over the Spaces bar: which tile, if any (`nil` tile over the bar's background).
    private func spacesBarHit(_ e: NSEvent) -> (over: Bool, tile: Int?) {
        guard let root = layer, !spacesBar.isHidden else { return (false, nil) }
        let p = spacesBar.convert(convert(e.locationInWindow, from: nil), from: root)
        return (spacesBar.bounds.contains(p), spacesBar.tile(at: p))
    }

    // MARK: Trackpad

    override func scrollWheel(with e: NSEvent) {
        guard !controller.gliding else { return }
        guard controller.isActive else { controller.enter(zoomOut: false); return }
        if e.modifierFlags.contains(.command) {
            let k: CGFloat = e.hasPreciseScrollingDeltas ? 0.006 : 0.06
            controller.zoom(by: exp(e.scrollingDeltaY * k), at: point(e))
        } else {
            let k: CGFloat = e.hasPreciseScrollingDeltas ? 1 : 12
            controller.pan(by: CGVector(dx: e.scrollingDeltaX * k, dy: e.scrollingDeltaY * k))
            scrollMayEnd(e)
        }
    }

    private var scrollEnd: DispatchWorkItem?

    /// Tells the controller when a scroll that moved the view is over (see scrollEnded): when its
    /// momentum ends, or the fingers lift with none to follow. A wheel's ticks have no phases,
    /// so there a pause is the end.
    private func scrollMayEnd(_ e: NSEvent) {
        scrollEnd?.cancel()
        let wait: TimeInterval
        if e.momentumPhase == .ended || e.momentumPhase == .cancelled { wait = 0 }
        // Momentum, if any, starts straight after.
        else if e.momentumPhase == [], e.phase == .ended || e.phase == .cancelled { wait = 0.08 }
        else if e.momentumPhase == [], e.phase == [] { wait = 0.25 }
        else { return }
        let work = DispatchWorkItem { [weak self] in self?.controller.scrollEnded() }
        scrollEnd = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    override func magnify(with e: NSEvent) {
        guard !controller.gliding else { return }
        guard controller.isActive else { controller.enter(zoomOut: false); return }
        controller.zoom(by: 1 + e.magnification, at: point(e))
    }

    override func smartMagnify(with e: NSEvent) {
        guard !controller.gliding else { return }
        guard controller.isActive else { controller.enter(zoomOut: true); return }
        controller.toggleOverview(at: point(e))
    }

    // MARK: Mouse

    override func mouseDown(with e: NSEvent) {
        guard !controller.gliding else { return }
        guard controller.isActive else {
            // Live mode: a click on a parked window's picture on the backdrop goes to that window,
            // and the Spaces bar works here too; anywhere else Expanse draws (the minimap), it
            // zooms out. The bare desktop is see-through, so its clicks go to the desktop itself.
            drag = .none
            let bar = spacesBarHit(e)
            if let i = bar.tile {
                spacesBar.hovered = nil
                controller.switchToSpace(spacesBar.spaces[i])
                return
            }
            if let w = controller.window(atView: point(e), parkedOnly: true) {
                controller.focus(w)
            } else if !bar.over {
                controller.enter(zoomOut: true)
            }
            return
        }
        controller.cancelAnimation()
        dragged = false
        let bar = spacesBarHit(e)
        if bar.over {
            drag = .none
            if let i = bar.tile {
                // Hover only updates while zoomed out; don't leave the tile lit after leaving.
                spacesBar.hovered = nil
                controller.switchToSpace(spacesBar.spaces[i])
            }
            return
        }
        if let mp = minimapPoint(e) {
            drag = .minimap
            controller.center(on: minimap.canvasPoint(at: mp))
            return
        }
        let p = point(e)
        let shift = e.modifierFlags.contains(.shift)
        let command = e.modifierFlags.contains(.command)
        pickedInFrame = false
        if spaceHeld {
            drag = .pan(last: p)
            NSCursor.closedHand.set()
        } else if let w = controller.window(atView: p) {
            if w.node.closeVisible, WindowNode.closeRect(in: controller.camera.toView(w.canvasFrame)).contains(p) {
                drag = .none
                close(w)
                render()
                return
            }
            // A window in a frame stands for the frame: a drag moves the frame, a click goes into it.
            // With ⌘, it's the window itself: a drag moves it (out of the frame, dropped outside
            // its box), a click centres it.
            if !command, !shift, !(selected.contains(w.id) && selected.count > 1), let f = controller.frame(of: w) {
                selected.removeAll()
                drag = grab(f, at: p)
            } else if shift {
                // ⇧-click toggles the window in the selection.
                if selected.remove(w.id) == nil { selected.insert(w.id) }
                drag = .none
            } else if selected.contains(w.id) && selected.count > 1 {
                let group = controller.windows.filter { selected.contains($0.id) }
                group.forEach(controller.bringToFront)
                drag = .group(clicked: w, starts: group.map { ($0, $0.canvasFrame) }, startPoint: p)
            } else {
                selected.removeAll()
                controller.bringToFront(w)
                pickedInFrame = command && controller.frame(of: w) != nil
                drag = .window(w, startFrame: w.canvasFrame, startPoint: p)
            }
        } else if !shift, let f = controller.frame(atView: p) {
            // The frame's box, between its windows: a drag moves it with them, a click goes in.
            selected.removeAll()
            drag = grab(f, at: p)
        } else {
            drag = .marquee(start: p, base: shift ? selected : [])
            if !shift { selected.removeAll() }
        }
        render()
    }

    private func grab(_ f: Frame, at p: CGPoint) -> Drag {
        let members = controller.members(of: f)
        members.forEach(controller.bringToFront)
        return .frame(f, startRect: f.rect, starts: members.map { ($0, $0.canvasFrame) }, startPoint: p)
    }

    override func mouseDragged(with e: NSEvent) {
        guard !controller.gliding else { return }
        let started = CACurrentMediaTime()
        defer {
            let ms = Int((CACurrentMediaTime() - started) * 1000)
            if ms > 16 { logger.info("slow: drag step took \(ms)ms") }
            if lastDragEvent > 0, started - lastDragEvent > 0.1 {
                logger.info("slow: \(Int((started - self.lastDragEvent) * 1000))ms between drag events")
            }
            lastDragEvent = started
        }
        guard controller.isActive else { controller.enter(zoomOut: false); return }
        let p = point(e)
        let s = controller.camera.scale
        let snapEnabled = pickedInFrame || !e.modifierFlags.contains(.command)
        switch drag {
        case .none:
            break
        case .minimap:
            if let mp = minimapPoint(e) { controller.center(on: minimap.canvasPoint(at: mp)) }
        case .pan(let last):
            dragged = true
            controller.pan(by: CGVector(dx: p.x - last.x, dy: p.y - last.y))
            drag = .pan(last: p)
        case .window(let w, let startFrame, let startPoint):
            if !dragged && p.distance(to: startPoint) < 3 { return }
            dragged = true
            let proposed = startFrame.offsetBy(dx: (p.x - startPoint.x) / s, dy: (p.y - startPoint.y) / s)
            let (frame, lines) = snapEnabled ? controller.snap(proposed, excluding: [w.id]) : (proposed, [])
            w.canvasFrame = frame
            showGuides(lines)
            render()
        case .group(_, let starts, let startPoint):
            if !dragged && p.distance(to: startPoint) < 3 { return }
            dragged = true
            let d = CGVector(dx: (p.x - startPoint.x) / s, dy: (p.y - startPoint.y) / s)
            // Snap the group's bounding box as one block against everything else.
            let bounds = starts.map(\.1).reduce(starts[0].1) { $0.union($1) }
            let proposed = bounds.offsetBy(dx: d.dx, dy: d.dy)
            let (snapped, lines) = snapEnabled ? controller.snap(proposed, excluding: Set(starts.map { $0.0.id })) : (proposed, [])
            let dx = d.dx + snapped.minX - proposed.minX, dy = d.dy + snapped.minY - proposed.minY
            for (w, start) in starts { w.canvasFrame = start.offsetBy(dx: dx, dy: dy) }
            showGuides(lines)
            render()
        case .frame(let f, let startRect, let starts, let startPoint):
            if !dragged && p.distance(to: startPoint) < 3 { return }
            dragged = true
            // The box snaps to the windows around it, as a window does.
            let proposed = startRect.offsetBy(dx: (p.x - startPoint.x) / s, dy: (p.y - startPoint.y) / s)
            let (snapped, lines) = snapEnabled ? controller.snap(proposed, excluding: Set(starts.map { $0.0.id })) : (proposed, [])
            f.rect = snapped
            for (w, start) in starts { w.canvasFrame = start.offsetBy(dx: snapped.minX - startRect.minX, dy: snapped.minY - startRect.minY) }
            showGuides(lines)
            render()
        case .marquee(let start, let base):
            dragged = true
            let box = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
            marquee.path = CGPath(rect: flip(box), transform: nil)
            let hits = controller.windows.filter { controller.camera.toView($0.canvasFrame).intersects(box) }.map(\.id)
            selected = base.union(hits)
            render()
        }
    }

    override func mouseUp(with e: NSEvent) {
        lastDragEvent = 0
        showGuides([])
        marquee.path = nil
        switch drag {
        case .window(let w, let startFrame, _):
            if dragged {
                controller.noteUserMove(w, from: startFrame.origin)
                controller.scheduleSave()
            } else {
                selected.removeAll()
                // ⌘-clicked in a frame: that window, centred, not the frame's view.
                if pickedInFrame {
                    controller.exit(focus: w, camera: controller.centredCamera(for: w))
                } else {
                    controller.exit(focus: w)
                }
            }
        case .group(let w, let starts, _):
            if dragged {
                for (moved, start) in starts { controller.noteUserMove(moved, from: start.origin) }
                controller.scheduleSave()
            } else {
                selected.removeAll()
                controller.exit(focus: w)
            }
        case .frame(let f, _, let starts, _):
            if dragged {
                for (moved, start) in starts { controller.noteUserMove(moved, from: start.origin) }
                controller.scheduleSave()
            } else {
                controller.goInto(f)
            }
        case .pan:
            if spaceHeld { NSCursor.openHand.set() }
        default:
            break
        }
        drag = .none
        render()
    }

    override func mouseMoved(with e: NSEvent) {
        guard controller.isActive else { return }
        let bar = spacesBarHit(e)
        spacesBar.hovered = bar.tile
        updateHover(over: minimapPoint(e) == nil && !bar.over, at: point(e), command: e.modifierFlags.contains(.command))
    }

    /// ⌘ pressed or let go: over a frame, the hover goes between the window and its frame.
    override func flagsChanged(with e: NSEvent) {
        super.flagsChanged(with: e)
        guard controller.isActive, !controller.gliding, !isDragging, let w = window else { return }
        let p = flip(convert(w.mouseLocationOutsideOfEventStream, from: nil))
        let bar = spacesBar.isHidden ? false : spacesGlass.frame.contains(flip(p))
        updateHover(over: !minimapGlass.frame.contains(flip(p)) && !bar, at: p, command: e.modifierFlags.contains(.command))
    }

    /// What's under the pointer: a window, or a frame (its box, or one of its windows without ⌘).
    private func updateHover(over overCanvas: Bool, at p: CGPoint, command: Bool) {
        var w = overCanvas ? controller.window(atView: p) : nil
        var underPointer: Frame?
        if let hit = w, !command, let f = controller.frame(of: hit) {
            w = nil
            underPointer = f
        } else if overCanvas, w == nil {
            underPointer = controller.frame(atView: p)
        }
        if w !== hovered || underPointer !== hoveredFrame {
            hovered?.node.label.string = hovered?.appName
            hovered = w
            hoveredFrame = underPointer
            if let w { w.node.label.string = w.title.isEmpty ? w.appName : "\(w.appName) — \(w.title)" }
            render()
        }
    }

    // MARK: Keyboard

    override func keyDown(with e: NSEvent) {
        guard !controller.gliding else { return }
        guard controller.isActive else { super.keyDown(with: e); return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        // Which key does what comes from shortcuts.conf (see Shortcuts.swift).
        switch Shortcuts.canvasAction(for: e) {
        case .exit:
            if selected.isEmpty { controller.exit() } else { selected.removeAll(); render() }
        case .canvasLeft: controller.navigate(.left)
        case .canvasRight: controller.navigate(.right)
        case .canvasUp: controller.navigate(.up)
        case .canvasDown: controller.navigate(.down)
        case .pan:
            if !e.isARepeat { spaceHeld = true; NSCursor.openHand.set() }
        case .selectAll:
            selected = Set(controller.windows.map(\.id))
            render()
        case .dive:
            if hovered == nil, let f = hoveredFrame {
                controller.goInto(f)
            } else {
                controller.exit(focus: hovered ?? controller.windows.last)
            }
        case .newFrame:
            controller.newFrame(at: pointerOnCanvas())
        case .deleteFrame:
            if let f = hoveredFrame ?? hovered.flatMap(controller.frame(of:)) {
                controller.deleteFrame(f)
            } else {
                Toast.show("Point at a frame to delete it")
            }
        case .fit:
            controller.cameraMovedByUser()
            controller.animate(to: controller.fitCamera())
        case .tidy:
            controller.tidy()
        case .actualSize:
            controller.zoomAnimated(to: 1)
        case .zoomOut:
            var t = controller.camera
            t.zoom(to: t.scale / 1.5, anchor: center)
            controller.cameraMovedByUser()
            controller.animate(to: t, duration: 0.22)
        case .zoomIn:
            var t = controller.camera
            t.zoom(to: t.scale * 1.5, anchor: center)
            controller.cameraMovedByUser()
            controller.animate(to: t, duration: 0.22)
        case .close:
            // The selection if there is one, otherwise the window under the pointer.
            if let w = controller.windows.first(where: { selected.contains($0.id) }) ?? hovered {
                close(w)
                render()
            }
        default:
            super.keyDown(with: e)
        }
    }

    /// The canvas point under the pointer, if it's over the canvas.
    private func pointerOnCanvas() -> CGPoint? {
        guard let w = window else { return nil }
        let p = flip(convert(w.mouseLocationOutsideOfEventStream, from: nil))
        return bounds.contains(flip(p)) ? controller.camera.toCanvas(p) : nil
    }

    // MARK: Context menu

    override func rightMouseDown(with e: NSEvent) {
        guard controller.isActive, !controller.gliding else { super.rightMouseDown(with: e); return }
        let p = point(e)
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, _ object: Any) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = object
            menu.addItem(item)
        }
        let w = controller.window(atView: p)
        if let f = w.flatMap(controller.frame(of:)) ?? controller.frame(atView: p) {
            add("Go to \(f.name)", #selector(goToFrame(_:)), f)
            add("Rename \(f.name)…", #selector(renameFrame(_:)), f)
            if let w, w.frameID == f.id { add("Take \(w.appName) out of \(f.name)", #selector(takeOutOfFrame(_:)), w) }
            menu.addItem(.separator())
            add("Delete \(f.name)", #selector(deleteFrame(_:)), f)
        } else {
            add("New Frame Here", #selector(newFrameHere(_:)), NSValue(point: controller.camera.toCanvas(p)))
        }
        NSMenu.popUpContextMenu(menu, with: e, for: self)
    }

    @objc private func goToFrame(_ item: NSMenuItem) {
        if let f = item.representedObject as? Frame { controller.goInto(f) }
    }

    @objc private func deleteFrame(_ item: NSMenuItem) {
        if let f = item.representedObject as? Frame { controller.deleteFrame(f) }
    }

    @objc private func takeOutOfFrame(_ item: NSMenuItem) {
        if let w = item.representedObject as? ManagedWindow { controller.removeFromFrame(w) }
    }

    @objc private func newFrameHere(_ item: NSMenuItem) {
        if let p = (item.representedObject as? NSValue)?.pointValue { controller.newFrame(at: p) }
    }

    @objc private func renameFrame(_ item: NSMenuItem) {
        guard let f = item.representedObject as? Frame else { return }
        let alert = NSAlert()
        alert.messageText = "Rename \(f.name)"
        let field = NSTextField(string: f.name)
        field.frame = CGRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        // Above the canvas, which covers ordinary windows.
        alert.window.level = NSWindow.Level(rawValue: OverlayWindow.canvasLevel.rawValue + 1)
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn { controller.rename(f, to: field.stringValue) }
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
    }

    override func keyUp(with e: NSEvent) {
        // Letting go of the pan key ends panning, even if a modifier changed while it was held.
        if spaceHeld, Int(e.keyCode) == Shortcuts.shortcut(for: .pan)?.keyCode {
            spaceHeld = false
            NSCursor.arrow.set()
        } else {
            super.keyUp(with: e)
        }
    }
}
