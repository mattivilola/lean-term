import Foundation

/// The global shortcut that toggles the Quick Terminal: a physical key (virtual key code) plus modifiers.
public struct QuickTerminalHotKey: Codable, Equatable, Sendable {
    /// Carbon/AppKit virtual key code.
    public var keyCode: UInt32
    /// The key's character without modifiers (lowercase), used only for display.
    public var key: String
    /// `ShortcutModifiers` raw value.
    public var modifiers: Int

    public static let `default` = QuickTerminalHotKey(keyCode: 17, key: "t", modifiers: [.control, .option, .command])

    public init(keyCode: UInt32, key: String, modifiers: ShortcutModifiers) {
        self.keyCode = keyCode
        self.key = ShortcutBinding(key, modifiers).key
        self.modifiers = modifiers.rawValue
    }

    public var shortcutModifiers: ShortcutModifiers { ShortcutModifiers(rawValue: modifiers) }

    /// A global shortcut needs at least two modifiers, one of them ⌃, ⌥ or ⌘, so it cannot collide with ordinary typing.
    public var isValid: Bool {
        let value = shortcutModifiers
        guard modifiers & ~15 == 0, key.unicodeScalars.count == 1 else { return false }
        let count = [ShortcutModifiers.control, .option, .command, .shift].filter { value.contains($0) }.count
        return count >= 2 && !value.isDisjoint(with: [.control, .option, .command])
    }

    public var display: String { ShortcutBinding(key, shortcutModifiers).display }
}
