import AppKit

/// Single-key shortcuts. Listed in the order the shortcut overlay shows them.
enum AppShortcut: CaseIterable {
    case playPause, slower, faster, skipBack, skipForward, volumeDown, volumeUp
    case fullScreen, togglePreview, open, editHeaders, archive, help

    /// Playback shortcuts only apply while the preview is open.
    var needsPreview: Bool {
        switch self {
        case .togglePreview, .open, .editHeaders, .archive, .help: false
        default: true
        }
    }

    var keyLabel: String {
        switch self {
        case .playPause: "Space"
        case .slower: "["
        case .faster: "]"
        case .skipBack: "←"
        case .skipForward: "→"
        case .volumeDown: "−"
        case .volumeUp: "+"
        case .fullScreen: "F"
        case .togglePreview: "P"
        case .open: "O"
        case .editHeaders: "E"
        case .archive: "A"
        case .help: "?"
        }
    }

    var title: String {
        switch self {
        case .playPause: "Play / pause"
        case .slower: "Slower, then reverse"
        case .faster: "Faster"
        case .skipBack: "Back one minute"
        case .skipForward: "Forward one minute"
        case .volumeDown: "Volume down"
        case .volumeUp: "Volume up"
        case .fullScreen: "Full screen"
        case .togglePreview: "Open or close the preview"
        case .open: "Open in the default app"
        case .editHeaders: "Edit MKV headers"
        case .archive: "Archive…"
        case .help: "Show or hide this list"
        }
    }

    /// The shortcut for a key pressed without Command, Control or Option.
    static func matching(characters: String?, specialKey: NSEvent.SpecialKey?) -> AppShortcut? {
        switch specialKey {
        case .leftArrow?: return .skipBack
        case .rightArrow?: return .skipForward
        default: break
        }
        switch characters?.lowercased() {
        case " ": return .playPause
        case "[": return .slower
        case "]": return .faster
        case "-": return .volumeDown
        // "+" is Shift-"=" on most layouts; accept the key either way.
        case "+", "=": return .volumeUp
        case "f": return .fullScreen
        case "p": return .togglePreview
        case "o": return .open
        case "e": return .editHeaders
        case "a": return .archive
        case "?": return .help
        default: return nil
        }
    }
}
