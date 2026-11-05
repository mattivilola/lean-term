import AppKit

/// Resolve the native monospace design through its supported API, without font files.
@MainActor
enum TerminalFont {
    static func make(name: String, size: Double) -> NSFont {
        if name == "SF Mono" { return .monospacedSystemFont(ofSize: size, weight: .regular) }
        return NSFont(name: name, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}
