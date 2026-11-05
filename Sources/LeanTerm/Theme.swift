import AppKit
import LeanTermCore
import SwiftTerm

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                  green: CGFloat((hex >> 8) & 255) / 255,
                  blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}

struct TerminalTheme {
    let background: NSColor
    let foreground: NSColor
    let accent: NSColor
    /// Brand CRT phosphor from the emerald `>_` icon, independent of palette.
    let phosphor: NSColor
    /// Amber CRT phosphor for remote and root marks, independent of palette.
    let amber: NSColor
    let selection: NSColor
    let ansi: [SwiftTerm.Color]

    init(palette: Preferences.Palette, dark: Bool) {
        let forest = palette == .forest
        background = NSColor(hex: dark ? (forest ? 0x101b17 : 0x181c23) : (forest ? 0xf5f8f3 : 0xf7f8fa))
        foreground = NSColor(hex: dark ? 0xe6eee8 : 0x24332b)
        accent = NSColor(hex: dark ? (forest ? 0x95e6af : 0x9cc3f5) : (forest ? 0x24693d : 0x305b96))
        phosphor = NSColor(hex: dark ? 0xb9f6c6 : 0x008a48)
        amber = NSColor(hex: dark ? 0xffb547 : 0x9a5b00)
        selection = NSColor(hex: dark ? (forest ? 0x304c3c : 0x34455f) : (forest ? 0xd1e6d5 : 0xd3e0f3))
        let colors: [UInt32] = dark
            ? [0x202923, 0xf08080, 0x9bd4a2, 0xe8ca8a, 0x91b8ed, 0xc2a1df, 0x89cfcd, 0xd8e2dc,
               0x718078, 0xffa0a0, 0xb7ebba, 0xf9dea1, 0xb2d1ff, 0xdbc0f5, 0xa9e7e4, 0xf5faf6]
            : [0x25332c, 0xb32e39, 0x28683b, 0x89600a, 0x285b9b, 0x7f408e, 0x176a70, 0xc3cec7,
               0x63746a, 0xc43c43, 0x327747, 0x946c0c, 0x356bac, 0x8c4a9c, 0x227b80, 0xe9eeea]
        ansi = colors.map { .init(red8: UInt16(($0 >> 16) & 255), green8: UInt16(($0 >> 8) & 255), blue8: UInt16($0 & 255)) }
    }
}

@MainActor
final class TerminalSurface: NSView {
    var appearanceChanged: (() -> Void)?
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        appearanceChanged?()
    }
}
