import AppKit
import Carbon.HIToolbox

/// The keyboard shortcuts, read from ~/.config/expanse/shortcuts.conf: the global ones, and the
/// keys that work while the canvas is zoomed out. Each line is
/// `action = shortcut`, e.g. `overview = opt+grave`; `#` starts a comment. A shortcut of `none`
/// turns the action off, and anything missing or unreadable keeps its default.
enum Shortcuts {
    enum Action: String, CaseIterable {
        case overview, toggleAutoCentre = "toggle-auto-centre", centreWindow = "centre-window"
        case hopLeft = "hop-left", hopRight = "hop-right", hopUp = "hop-up", hopDown = "hop-down"
        // While zoomed out.
        case exit, dive, tidy, fit, actualSize = "actual-size", zoomOut = "zoom-out", zoomIn = "zoom-in"
        case selectAll = "select-all", close, pan, newFrame = "new-frame", deleteFrame = "delete-frame"
        case canvasLeft = "canvas-left", canvasRight = "canvas-right", canvasUp = "canvas-up", canvasDown = "canvas-down"

        /// Global shortcuts work anywhere; the rest only while the canvas is zoomed out.
        var isGlobal: Bool {
            switch self {
            case .overview, .toggleAutoCentre, .centreWindow, .hopLeft, .hopRight, .hopUp, .hopDown: true
            default: false
            }
        }

        var summary: String {
            switch self {
            case .overview: "Pull back from the focused app"
            case .toggleAutoCentre: "Turn auto-centring on or off"
            case .centreWindow: "Centre the window you're in"
            case .hopLeft, .hopRight, .hopUp, .hopDown: "Hop to the nearest window that way"
            case .exit: "Clear the selection, or go back to 100%"
            case .dive: "Dive into the highlighted window"
            case .tidy: "Tidy up: line up each group, where it is"
            case .fit: "Fit everything"
            case .actualSize: "Zoom to 100%"
            case .zoomOut: "Zoom out"
            case .zoomIn: "Zoom in"
            case .selectAll: "Select every window"
            case .close: "Close the selected windows, or the one under the pointer"
            case .pan: "Hold and drag to move around the canvas"
            case .newFrame: "Make a frame the size of the screen, under the pointer"
            case .deleteFrame: "Delete the frame under the pointer (its windows stay)"
            case .canvasLeft, .canvasRight, .canvasUp, .canvasDown: "Move to the nearest window that way"
            }
        }

        var defaultShortcut: String {
            switch self {
            case .overview: "opt+grave"
            case .toggleAutoCentre: "opt+shift+grave"
            case .centreWindow: "ctrl+opt+c"
            case .hopLeft: "ctrl+left"
            case .hopRight: "ctrl+right"
            case .hopUp: "ctrl+up"
            case .hopDown: "ctrl+down"
            case .exit: "escape"
            case .dive: "return"
            case .tidy: "t"
            case .fit: "0"
            case .actualSize: "1"
            case .zoomOut: "minus"
            case .zoomIn: "equal"
            case .selectAll: "cmd+a"
            case .close: "cmd+w"
            case .pan: "space"
            case .newFrame: "cmd+g"
            case .deleteFrame: "cmd+shift+g"
            case .canvasLeft: "left"
            case .canvasRight: "right"
            case .canvasUp: "up"
            case .canvasDown: "down"
            }
        }
    }

    struct Shortcut {
        let keyCode: Int
        /// Carbon modifier flags (cmdKey, optionKey, ...), as RegisterEventHotKey takes them.
        let modifiers: Int
        /// The menu item's keyEquivalent for this key, if it has one.
        let menuKey: String

        var menuModifiers: NSEvent.ModifierFlags {
            var flags: NSEvent.ModifierFlags = []
            if modifiers & controlKey != 0 { flags.insert(.control) }
            if modifiers & optionKey != 0 { flags.insert(.option) }
            if modifiers & shiftKey != 0 { flags.insert(.shift) }
            if modifiers & cmdKey != 0 { flags.insert(.command) }
            return flags
        }

        /// The key with exactly these modifiers: ⇧0 isn't 0, so 0 and ⇧0 can do different things.
        func matches(_ event: NSEvent) -> Bool {
            let held = event.modifierFlags.intersection([.control, .option, .shift, .command])
            return Int(event.keyCode) == keyCode && held == menuModifiers
        }

        /// e.g. "⌃⌥C", for messages and logs.
        var symbols: String {
            var s = ""
            if modifiers & controlKey != 0 { s += "⌃" }
            if modifiers & optionKey != 0 { s += "⌥" }
            if modifiers & shiftKey != 0 { s += "⇧" }
            if modifiers & cmdKey != 0 { s += "⌘" }
            return s + (Shortcuts.keySymbols[menuKey] ?? menuKey.uppercased())
        }
    }

    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/expanse/shortcuts.conf")

    /// Each action's shortcut, or nil if the config turns it off.
    private(set) static var current: [Action: Shortcut] = defaults

    private static var defaults: [Action: Shortcut] {
        var map: [Action: Shortcut] = [:]
        for action in Action.allCases { map[action] = parse(action.defaultShortcut) }
        return map
    }

    static func shortcut(for action: Action) -> Shortcut? { current[action] }

    /// The zoomed-out action for a key press, if it's one of theirs.
    static func canvasAction(for event: NSEvent) -> Action? {
        Action.allCases.first { !$0.isGlobal && current[$0]?.matches(event) == true }
    }

    /// Reads the config file, writing one with the defaults first if there isn't one yet.
    static func load() {
        if !FileManager.default.fileExists(atPath: url.path) { writeDefaultFile() }
        var map = defaults
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            current = map
            return
        }
        for (n, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let action = Action(rawValue: parts[0].lowercased()) else {
                logger.info("shortcuts.conf line \(n + 1): unknown setting \"\(line)\"")
                continue
            }
            if parts[1].lowercased() == "none" || parts[1].isEmpty {
                map[action] = nil
            } else if let shortcut = parse(parts[1]) {
                map[action] = shortcut
            } else {
                logger.info("shortcuts.conf line \(n + 1): can't read \"\(parts[1])\", keeping the default")
            }
        }
        current = map
        logConflicts()
        logger.info("shortcuts: \(Action.allCases.map { "\($0.rawValue)=\(map[$0]?.symbols ?? "none")" }.joined(separator: " "))")
    }

    /// Two actions on one shortcut: a global one always wins (macOS hands it over first), and
    /// between zoomed-out ones the first in the file's order does.
    private static func logConflicts() {
        let actions = Action.allCases.filter { current[$0] != nil }
        for (i, a) in actions.enumerated() {
            for b in actions[(i + 1)...] {
                guard let sa = current[a], let sb = current[b],
                      sa.keyCode == sb.keyCode, sa.modifiers == sb.modifiers else { continue }
                logger.info("shortcuts.conf: \(a.rawValue) and \(b.rawValue) are both \(sa.symbols); \(b.rawValue) won't work")
            }
        }
    }

    /// "ctrl+opt+c" → key code and modifiers. Modifiers can go in any order; the key comes last.
    static func parse(_ text: String) -> Shortcut? {
        let tokens = text.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyName = tokens.last, let (keyCode, menuKey) = keys[keyName] else { return nil }
        var modifiers = 0
        for token in tokens.dropLast() {
            switch token {
            case "ctrl", "control", "⌃": modifiers |= controlKey
            case "opt", "option", "alt", "⌥": modifiers |= optionKey
            case "shift", "⇧": modifiers |= shiftKey
            case "cmd", "command", "⌘": modifiers |= cmdKey
            default: return nil
            }
        }
        return Shortcut(keyCode: keyCode, modifiers: modifiers, menuKey: menuKey)
    }

    private static func writeDefaultFile() {
        var text = """
        # Expanse keyboard shortcuts. Quit and reopen Expanse after changing this file.
        #
        # Format:  action = modifiers+key
        # Modifiers: ctrl, opt, shift, cmd
        # Keys: a-z, 0-9, f1-f12, left, right, up, down, space, return, tab, escape, delete,
        #       grave (`), minus, equal, leftbracket, rightbracket, backslash, semicolon,
        #       quote, comma, period, slash
        # Set an action to "none" to turn its shortcut off.

        """
        for (title, global) in [("Anywhere", true), ("While zoomed out", false)] {
            text += "\n# ---- \(title) ----\n"
            for action in Action.allCases where action.isGlobal == global {
                text += "\n# \(action.summary)\n\(action.rawValue) = \(action.defaultShortcut)\n"
            }
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            logger.info("couldn't write \(url.path): \(error.localizedDescription)")
        }
    }

    /// Key name → (Carbon key code, NSMenuItem keyEquivalent).
    private static let keys: [String: (Int, String)] = {
        var map: [String: (Int, String)] = [
            "a": (kVK_ANSI_A, "a"), "b": (kVK_ANSI_B, "b"), "c": (kVK_ANSI_C, "c"), "d": (kVK_ANSI_D, "d"),
            "e": (kVK_ANSI_E, "e"), "f": (kVK_ANSI_F, "f"), "g": (kVK_ANSI_G, "g"), "h": (kVK_ANSI_H, "h"),
            "i": (kVK_ANSI_I, "i"), "j": (kVK_ANSI_J, "j"), "k": (kVK_ANSI_K, "k"), "l": (kVK_ANSI_L, "l"),
            "m": (kVK_ANSI_M, "m"), "n": (kVK_ANSI_N, "n"), "o": (kVK_ANSI_O, "o"), "p": (kVK_ANSI_P, "p"),
            "q": (kVK_ANSI_Q, "q"), "r": (kVK_ANSI_R, "r"), "s": (kVK_ANSI_S, "s"), "t": (kVK_ANSI_T, "t"),
            "u": (kVK_ANSI_U, "u"), "v": (kVK_ANSI_V, "v"), "w": (kVK_ANSI_W, "w"), "x": (kVK_ANSI_X, "x"),
            "y": (kVK_ANSI_Y, "y"), "z": (kVK_ANSI_Z, "z"),
            "0": (kVK_ANSI_0, "0"), "1": (kVK_ANSI_1, "1"), "2": (kVK_ANSI_2, "2"), "3": (kVK_ANSI_3, "3"),
            "4": (kVK_ANSI_4, "4"), "5": (kVK_ANSI_5, "5"), "6": (kVK_ANSI_6, "6"), "7": (kVK_ANSI_7, "7"),
            "8": (kVK_ANSI_8, "8"), "9": (kVK_ANSI_9, "9"),
            "grave": (kVK_ANSI_Grave, "`"), "`": (kVK_ANSI_Grave, "`"),
            "minus": (kVK_ANSI_Minus, "-"), "-": (kVK_ANSI_Minus, "-"),
            "equal": (kVK_ANSI_Equal, "="), "=": (kVK_ANSI_Equal, "="),
            "leftbracket": (kVK_ANSI_LeftBracket, "["), "[": (kVK_ANSI_LeftBracket, "["),
            "rightbracket": (kVK_ANSI_RightBracket, "]"), "]": (kVK_ANSI_RightBracket, "]"),
            "backslash": (kVK_ANSI_Backslash, "\\"), "\\": (kVK_ANSI_Backslash, "\\"),
            "semicolon": (kVK_ANSI_Semicolon, ";"), ";": (kVK_ANSI_Semicolon, ";"),
            "quote": (kVK_ANSI_Quote, "'"), "'": (kVK_ANSI_Quote, "'"),
            "comma": (kVK_ANSI_Comma, ","), ",": (kVK_ANSI_Comma, ","),
            "period": (kVK_ANSI_Period, "."), ".": (kVK_ANSI_Period, "."),
            "slash": (kVK_ANSI_Slash, "/"), "/": (kVK_ANSI_Slash, "/"),
            "space": (kVK_Space, " "),
            "return": (kVK_Return, "\r"), "enter": (kVK_Return, "\r"),
            "tab": (kVK_Tab, "\t"),
            "escape": (kVK_Escape, "\u{1B}"), "esc": (kVK_Escape, "\u{1B}"),
            "delete": (kVK_Delete, "\u{8}"),
            "left": (kVK_LeftArrow, String(UnicodeScalar(NSLeftArrowFunctionKey)!)),
            "right": (kVK_RightArrow, String(UnicodeScalar(NSRightArrowFunctionKey)!)),
            "up": (kVK_UpArrow, String(UnicodeScalar(NSUpArrowFunctionKey)!)),
            "down": (kVK_DownArrow, String(UnicodeScalar(NSDownArrowFunctionKey)!)),
        ]
        let fKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        for (i, code) in fKeys.enumerated() {
            map["f\(i + 1)"] = (code, String(UnicodeScalar(NSF1FunctionKey + i)!))
        }
        return map
    }()

    /// Readable names for keyEquivalents that don't print as themselves.
    fileprivate static let keySymbols: [String: String] = {
        var map: [String: String] = [
            " ": "Space", "\r": "↩", "\t": "⇥", "\u{1B}": "⎋", "\u{8}": "⌫",
            String(UnicodeScalar(NSLeftArrowFunctionKey)!): "←",
            String(UnicodeScalar(NSRightArrowFunctionKey)!): "→",
            String(UnicodeScalar(NSUpArrowFunctionKey)!): "↑",
            String(UnicodeScalar(NSDownArrowFunctionKey)!): "↓",
        ]
        for i in 0..<12 { map[String(UnicodeScalar(NSF1FunctionKey + i)!)] = "F\(i + 1)" }
        return map
    }()
}
