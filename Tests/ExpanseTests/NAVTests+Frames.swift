import Testing
import AppKit
@_private(sourceFile: "CanvasController.swift") @testable import Expanse
@_private(sourceFile: "CanvasView.swift") @testable import Expanse

/// Named screens (the fork's frames, see Frame): ⌘G on a group, a window or the selection, or
/// finishing the screen tool, gives a screen a name, kept in the layout and listed in AltTab.
extension NAVTests {

    @Test("FRAME-01 Naming a group makes a frame round it, with its windows in it")
    func frame01() throws {
        let (a, b, c) = Self.groupLayout()
        let canvas = TestCanvas.make(windows: [a, b, c])
        try Self.onCanvas(canvas) {
            let group = try #require(canvas.screenGroup(of: b))
            let f = try #require(canvas.nameScreen(group))
            #expect(canvas.members(of: f).map(\.id) == [22, 23])
            #expect(a.frameID == nil)
            #expect(f.rect.contains(CanvasController.outline(of: group)))
            #expect(canvas.sharedFrame(of: group) === f)
            // Named again (⌘G twice), it keeps the frame it has.
            #expect(canvas.nameScreen(group) === f)
            #expect(canvas.frames.count == 1)
        }
    }

    @Test("FRAME-02 A screen you built is named with its screen as the frame's box")
    func frame02() throws {
        let canvas = TestCanvas.make()
        let size = canvas.viewSize, gap = CanvasController.gap
        let screen = CGRect(origin: CGPoint(x: 4000, y: 0), size: size)
        let left = Screens.frame(of: .left, in: screen, gap: gap), right = Screens.frame(of: .right, in: screen, gap: gap)
        let b = Self.win(31, left.minX, left.minY, left.width, left.height)
        let c = Self.win(32, right.minX, right.minY, right.width, right.height)
        canvas.windows = [b, c]
        try Self.onCanvas(canvas) {
            let built = try #require(canvas.builtScreens().first)
            let f = try #require(canvas.nameScreen([b, c]))
            #expect(f.rect == built.screen)
        }
    }

    @Test("FRAME-03 Going to a named group shows the group, as a click on one of its windows does")
    func frame03() throws {
        let (a, b, c) = Self.groupLayout()
        let canvas = TestCanvas.make(windows: [a, b, c])
        try Self.onCanvas(canvas) {
            let f = try #require(canvas.nameScreen([b, c]))
            canvas.camera = canvas.overviewCamera()
            canvas.goInto(f)
            #expect(canvas.animation?.to == Self.framing(CGRect(x: 0, y: 0, width: 1220, height: 400)))
            #expect(canvas.animation?.to == canvas.viewCamera(for: c))
        }
    }

    @Test("FRAME-04 A named group's name is a handle; the gaps between its windows are its ring's, not the frame's")
    func frame04() throws {
        let (a, b, c) = Self.groupLayout()
        let canvas = TestCanvas.make(windows: [a, b, c])
        try Self.onCanvas(canvas) {
            let f = try #require(canvas.nameScreen([b, c]))
            canvas.camera = Camera(origin: CGPoint(x: -100, y: -100), scale: 1)
            // B and C are at x 100–700 and 720–1320, y 100–500 in the view; the ring is 12pt out.
            #expect(canvas.frame(atView: CGPoint(x: 200, y: 75)) === f)
            #expect(canvas.frame(atView: CGPoint(x: 710, y: 300)) == nil)
            // An empty frame's box is the frame's all over.
            let empty = canvas.nameScreen(at: canvas.screenRect(at: CGPoint(x: -8000, y: 0))).frame
            #expect(canvas.frame(atView: canvas.camera.toView(empty.rect).center) === empty)
        }
    }

    @Test("FRAME-05 A named group is saved: the frame and which windows are in it")
    func frame05() throws {
        let (a, b, c) = Self.groupLayout()
        let canvas = TestCanvas.make(windows: [a, b, c])
        canvas.hasSynced = true
        try Self.onCanvas(canvas) {
            let f = try #require(canvas.nameScreen([b, c]))
            canvas.rename(f, to: "Work")
            canvas.save()
        }
        let layout = try #require(LayoutStore.load())
        let saved = try #require(layout.frames?.first)
        #expect(saved.name == "Work")
        #expect(layout.windows.filter { $0.frameID == saved.id }.compactMap(\.id).sorted() == [22, 23])
    }

    @Test("FRAME-06 A window on its own can be a named screen, centred on it; windows too spread out can't")
    func frame06() throws {
        let (a, b, c) = Self.groupLayout()
        let canvas = TestCanvas.make(windows: [a, b, c])
        try Self.onCanvas(canvas) {
            let f = try #require(canvas.nameScreen([a]))
            #expect(canvas.members(of: f).map(\.id) == [21])
            #expect(f.rect.size == canvas.viewSize)
            #expect(f.rect.center.distance(to: a.canvasFrame.center) < 1)   // origins are whole points
            // A 3000pt-wide spread doesn't fit one screen.
            #expect(canvas.nameScreen([b, c, Self.win(24, 3000, 0, 600, 400)]) == nil)
            #expect(canvas.frames.count == 1)
        }
    }

    @Test("FRAME-07 Finishing the screen tool names its screen, empty or not, once")
    func frame07() throws {
        let canvas = TestCanvas.make(windows: [Self.win(25, 100, 100, 600, 400)])
        try Self.onCanvas(canvas) {
            let rect = canvas.screenRect(at: .zero)
            let first = canvas.nameScreen(at: rect)
            #expect(first.new)
            #expect(canvas.members(of: first.frame).map(\.id) == [25])
            let again = canvas.nameScreen(at: rect)
            #expect(!again.new && again.frame === first.frame)
            let empty = canvas.nameScreen(at: canvas.screenRect(at: CGPoint(x: 5000, y: 0)))
            #expect(empty.new && canvas.members(of: empty.frame).isEmpty)
        }
    }

    @Test("FRAME-08 Moving all of a named screen's windows takes the screen with them")
    func frame08() throws {
        let (a, b, c) = Self.groupLayout()
        let canvas = TestCanvas.make(windows: [a, b, c])
        try Self.onCanvas(canvas) {
            let f = try #require(canvas.nameScreen([b, c]))
            // A selection with both of its windows (and another) carries it; one of them alone doesn't.
            #expect(canvas.framesCarried(by: [a, b, c]).map(\.id) == [f.id])
            #expect(canvas.framesCarried(by: [b]).isEmpty)
            // Built into a screen elsewhere, its windows stay in it and it goes with them.
            canvas.arrange([(b, .left), (c, .right)], screen: CGPoint(x: 6000, y: 0), how: "test")
            #expect(f.rect == canvas.screenRect(at: CGPoint(x: 6000, y: 0)))
            #expect(canvas.members(of: f).map(\.id) == [22, 23])
        }
    }
}
