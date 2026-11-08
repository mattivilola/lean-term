import AppKit

/// Resolve the native monospace design through its supported API, without font files.
@MainActor
enum TerminalFont {
    static func make(name: String, size: Double) -> NSFont {
        if name == "SF Mono" { return .monospacedSystemFont(ofSize: size, weight: .regular) }
        let font = NSFont(name: name, size: size)
            ?? NSFontManager.shared.font(withFamily: name, traits: [], weight: 5, size: size)
        return font ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}
