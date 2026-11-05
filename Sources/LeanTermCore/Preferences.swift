import Foundation

public struct Preferences: Equatable, Sendable {
    public enum Appearance: String, CaseIterable, Sendable {
        case system, light, dark
        public var title: String { rawValue.capitalized }
    }
    public enum Palette: String, CaseIterable, Sendable {
        case forest, graphite
        public var title: String { rawValue.capitalized }
    }
    public enum Cursor: String, CaseIterable, Sendable {
        case bar, block, underline
        public var title: String { rawValue.capitalized }
    }

    public var appearance: Appearance = .system
    public var palette: Palette = .forest
    public var fontName = "Menlo"
    public var fontSize: Double = 13
    public var cursor: Cursor = .bar
    public var optionAsMeta = false
    public static let scrollbackLines = 10_000

    public init() {}

    public init(defaults: UserDefaults) {
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        palette = Palette(rawValue: defaults.string(forKey: "palette") ?? "") ?? .forest
        fontName = defaults.string(forKey: "fontName") ?? "Menlo"
        let size = defaults.object(forKey: "fontSize") as? Double ?? 13
        fontSize = Self.validFontSize(size)
        cursor = Cursor(rawValue: defaults.string(forKey: "cursor") ?? "") ?? .bar
        optionAsMeta = defaults.bool(forKey: "optionAsMeta")
    }

    public static func validFontSize(_ value: Double) -> Double {
        value.isFinite ? min(32, max(10, value)) : 13
    }

    public static func reset(in defaults: UserDefaults) {
        for key in ["appearance", "palette", "fontName", "fontSize", "cursor", "optionAsMeta"] {
            defaults.removeObject(forKey: key)
        }
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(appearance.rawValue, forKey: "appearance")
        defaults.set(palette.rawValue, forKey: "palette")
        defaults.set(fontName, forKey: "fontName")
        defaults.set(Self.validFontSize(fontSize), forKey: "fontSize")
        defaults.set(cursor.rawValue, forKey: "cursor")
        defaults.set(optionAsMeta, forKey: "optionAsMeta")
    }
}
