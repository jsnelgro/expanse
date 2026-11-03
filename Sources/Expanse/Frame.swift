import CoreGraphics
import Foundation

/// A named screen ("frame" in the code): a screen-sized place on the canvas with a name, kept in
/// the layout and listed in window switchers (see FrameWindows). It's what a screen group (see
/// CanvasController.screenGroups) or the screen tool's screen becomes when named: ⌘G names the
/// group, window or selection under the pointer, and finishing the screen tool names its screen.
/// At 100% it's a desktop: its view is the screen, and focusing one of its windows keeps it there,
/// rather than centring that window. Zoomed out it's one unit: a click goes into it, dragging it
/// (or all its windows) moves it with its windows, Tidy Up leaves its inside alone. An empty one
/// is drawn as a box to put windows in.
///
/// A window is in a frame when it's put down (dragged on the canvas, or for real at 100%) with
/// its middle inside the box. Membership lives on the windows (ManagedWindow.frameID), so it goes
/// wherever a window's spot goes: into the saved layout, while its app is hidden, to its app's
/// next windows after a relaunch.
final class Frame {
    /// How a frame arranges its windows. Only freeform so far; tab and scrolling frames would
    /// arrange their members themselves (see IDEAS.md).
    enum Kind: String, Codable {
        /// Windows stay wherever you put them.
        case freeform
    }

    let id: String
    var kind: Kind
    var name: String
    /// The box, in canvas space: the screen it was made for, at 100%.
    var rect: CGRect

    init(id: String = UUID().uuidString, kind: Kind = .freeform, name: String, rect: CGRect) {
        self.id = id
        self.kind = kind
        self.name = name
        self.rect = rect
    }

    /// The frame's view at 100% on a screen of `size`: the box exactly, on the screen it was made
    /// for; centred on it on any other.
    func camera(on size: CGSize) -> Camera {
        let origin = CGPoint(x: (rect.midX - size.width / 2).rounded(), y: (rect.midY - size.height / 2).rounded())
        return Camera(origin: abs(size.width - rect.width) < 1 && abs(size.height - rect.height) < 1 ? rect.origin : origin, scale: 1)
    }

    /// As the layout file keeps it.
    struct Saved: Codable {
        var id: String
        var kind: Kind
        var name: String
        var x: Double
        var y: Double
        var w: Double?
        var h: Double?
    }

    var saved: Saved {
        Saved(id: id, kind: kind, name: name, x: Double(rect.minX), y: Double(rect.minY),
              w: Double(rect.width), h: Double(rect.height))
    }

    convenience init(_ s: Saved, defaultSize: CGSize) {
        self.init(id: s.id, kind: s.kind, name: s.name,
                  rect: CGRect(x: s.x, y: s.y, width: s.w ?? Double(defaultSize.width), height: s.h ?? Double(defaultSize.height)))
    }
}
