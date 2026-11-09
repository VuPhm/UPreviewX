import AppKit

/// Actions that can be bound to customizable keyboard shortcuts.
public enum ShortcutAction: String, Codable, CaseIterable, Sendable {
    case playPause = "playPause"
    case seekBackward = "seekBackward"
    case seekForward = "seekForward"
    case shuttleBackward = "shuttleBackward"
    case shuttleForward = "shuttleForward"
    case toggleSpeed = "toggleSpeed"
    case saveFrame = "saveFrame"
    case toggleFastPreview = "toggleFastPreview"
    case toggleDiagnostics = "toggleDiagnostics"
    case toggleMute = "toggleMute"
    case toggleFullscreen = "toggleFullscreen"

    public var displayName: String {
        switch self {
        case .playPause:
            return "Play / Pause"
        case .seekBackward:
            return "Seek Backward (Short Press)"
        case .seekForward:
            return "Seek Forward (Short Press)"
        case .shuttleBackward:
            return "Hold to Shuttle Backward"
        case .shuttleForward:
            return "Hold to Shuttle Forward"
        case .toggleSpeed:
            return "Toggle 1× / 2× Playback"
        case .saveFrame:
            return "Save Current Frame"
        case .toggleFastPreview:
            return "Toggle Fast Preview Mode"
        case .toggleDiagnostics:
            return "Toggle Playback Diagnostics"
        case .toggleMute:
            return "Mute / Unmute"
        case .toggleFullscreen:
            return "Toggle Fullscreen"
        }
    }

    public var isHoldAction: Bool {
        return self == .shuttleBackward || self == .shuttleForward
    }
}

/// Representation of a keyboard shortcut with physical key code and modifier mask.
public struct KeyShortcut: Codable, Equatable, Sendable {
    public var keyCode: UInt16
    public var modifierFlagsRaw: UInt
    public var displayKeyName: String

    public init(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags = [], displayKeyName: String? = nil) {
        self.keyCode = keyCode
        let relevant = modifierFlags.intersection([.command, .option, .shift, .control])
        self.modifierFlagsRaw = relevant.rawValue
        self.displayKeyName = displayKeyName ?? KeyShortcut.keyName(for: keyCode)
    }

    public var modifierFlags: NSEvent.ModifierFlags {
        return NSEvent.ModifierFlags(rawValue: modifierFlagsRaw)
    }

    public var displayString: String {
        var str = ""
        if modifierFlags.contains(.control) { str += "⌃" }
        if modifierFlags.contains(.option) { str += "⌥" }
        if modifierFlags.contains(.shift) { str += "⇧" }
        if modifierFlags.contains(.command) { str += "⌘" }
        str += displayKeyName
        return str
    }

    /// Evaluates if an incoming `NSEvent` matches this shortcut.
    public func matches(event: NSEvent) -> Bool {
        guard event.keyCode == keyCode else { return false }
        let currentMods = event.modifierFlags.intersection([.command, .option, .shift, .control])
        return currentMods.rawValue == modifierFlagsRaw
    }

    public static func defaultShortcut(for action: ShortcutAction) -> KeyShortcut {
        switch action {
        case .playPause:
            return KeyShortcut(keyCode: 49, modifierFlags: [], displayKeyName: "Space")
        case .seekBackward:
            return KeyShortcut(keyCode: 123, modifierFlags: [], displayKeyName: "←")
        case .seekForward:
            return KeyShortcut(keyCode: 124, modifierFlags: [], displayKeyName: "→")
        case .shuttleBackward:
            return KeyShortcut(keyCode: 123, modifierFlags: [], displayKeyName: "←")
        case .shuttleForward:
            return KeyShortcut(keyCode: 124, modifierFlags: [], displayKeyName: "→")
        case .toggleSpeed:
            return KeyShortcut(keyCode: 19, modifierFlags: [], displayKeyName: "2")
        case .saveFrame:
            return KeyShortcut(keyCode: 1, modifierFlags: [.command, .shift], displayKeyName: "S")
        case .toggleFastPreview:
            return KeyShortcut(keyCode: 35, modifierFlags: [], displayKeyName: "P")
        case .toggleDiagnostics:
            return KeyShortcut(keyCode: 2, modifierFlags: [], displayKeyName: "D")
        case .toggleMute:
            return KeyShortcut(keyCode: 46, modifierFlags: [], displayKeyName: "M")
        case .toggleFullscreen:
            return KeyShortcut(keyCode: 3, modifierFlags: [], displayKeyName: "F")
        }
    }

    public static func keyName(for keyCode: UInt16) -> String {
        switch keyCode {
        case 49: return "Space"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 53: return "⎋"
        case 36: return "↩"
        case 48: return "⇥"
        case 51: return "⌫"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 23: return "5"
        case 22: return "6"
        case 26: return "7"
        case 28: return "8"
        case 25: return "9"
        case 29: return "0"
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 4: return "H"
        case 5: return "G"
        case 6: return "Z"
        case 7: return "X"
        case 8: return "C"
        case 9: return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 16: return "Y"
        case 17: return "T"
        case 31: return "O"
        case 32: return "U"
        case 34: return "I"
        case 35: return "P"
        case 37: return "L"
        case 38: return "J"
        case 40: return "K"
        case 45: return "N"
        case 46: return "M"
        case 47: return "."
        case 43: return ","
        case 44: return "/"
        case 27: return "-"
        case 24: return "="
        case 30: return "]"
        case 33: return "["
        default: return "Key \(keyCode)"
        }
    }

    public static func isReservedSystemShortcut(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Bool {
        let flags = modifierFlags.intersection([.command, .option, .shift, .control])
        if flags == [.command] {
            // ⌘Q (Quit: 12), ⌘W (Close: 13), ⌘H (Hide: 4), ⌘M (Minimize: 46), ⌘, (Settings: 43)
            if keyCode == 12 || keyCode == 13 || keyCode == 4 || keyCode == 46 || keyCode == 43 {
                return true
            }
        }
        return false
    }
}
