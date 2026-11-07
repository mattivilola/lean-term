import Foundation

public enum HostColor: String, CaseIterable, Codable, Sendable {
    case red, amber, green, blue, purple
    public var title: String { rawValue.capitalized }
}

/// Colours remote tabs whose host matches the shell-style `pattern`, e.g. `prod-*`.
public struct HostColorRule: Codable, Equatable, Sendable {
    public var pattern: String
    public var color: HostColor

    public init(pattern: String, color: HostColor) {
        self.pattern = pattern
        self.color = color
    }
}

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

    /// What ⌘-click opens files with.
    public enum FileOpenerChoice: Equatable, Sendable, RawRepresentable {
        case leanVSCode
        case system
        /// An application's bundle identifier, or its path when it has none.
        case app(String)

        public init?(rawValue: String) {
            switch rawValue {
            case "leanVSCode": self = .leanVSCode
            case "system": self = .system
            default:
                guard rawValue.hasPrefix("app:"), rawValue.count > 4 else { return nil }
                self = .app(String(rawValue.dropFirst(4)))
            }
        }

        public var rawValue: String {
            switch self {
            case .leanVSCode: "leanVSCode"
            case .system: "system"
            case .app(let identifier): "app:" + identifier
            }
        }
    }

    public var appearance: Appearance = .system
    public var palette: Palette = .forest
    public var fontName = "SF Mono"
    public var fontSize: Double = 13
    public var cursor: Cursor = .bar
    public var optionAsMeta = false
    public var showResourceUsage = true
    public var showActivityScanner = true
    public var showTabActivity = true
    public var showSessionMarks = true
    /// Off by default: turning it on triggers the macOS notification permission prompt.
    public var notifyInBackground = false
    public var hostColorRules: [HostColorRule] = []
    public var closeTabOnShellExit = false
    public var quitAfterLastSession = false
    public var restoreSessions = false
    public var secureKeyboardEntry = false
    public var confirmMultilinePaste = true
    public var redactCopies = false
    public var fileOpener = FileOpenerChoice.leanVSCode
    public static let scrollbackLines = 10_000

    public init() {}

    public init(defaults: UserDefaults) {
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        palette = Palette(rawValue: defaults.string(forKey: "palette") ?? "") ?? .forest
        fontName = defaults.string(forKey: "fontName") ?? "SF Mono"
        let size = defaults.object(forKey: "fontSize") as? Double ?? 13
        fontSize = Self.validFontSize(size)
        cursor = Cursor(rawValue: defaults.string(forKey: "cursor") ?? "") ?? .bar
        optionAsMeta = defaults.bool(forKey: "optionAsMeta")
        showResourceUsage = defaults.object(forKey: "showResourceUsage") == nil ? true : defaults.bool(forKey: "showResourceUsage")
        showActivityScanner = defaults.object(forKey: "showActivityScanner") == nil ? true : defaults.bool(forKey: "showActivityScanner")
        showTabActivity = defaults.object(forKey: "showTabActivity") == nil ? true : defaults.bool(forKey: "showTabActivity")
        showSessionMarks = defaults.object(forKey: "showSessionMarks") == nil ? true : defaults.bool(forKey: "showSessionMarks")
        notifyInBackground = defaults.bool(forKey: "notifyInBackground")
        hostColorRules = defaults.data(forKey: "hostColorRules").flatMap { try? JSONDecoder().decode([HostColorRule].self, from: $0) } ?? []
        closeTabOnShellExit = defaults.bool(forKey: "closeTabOnShellExit")
        quitAfterLastSession = defaults.bool(forKey: "quitAfterLastSession")
        restoreSessions = defaults.bool(forKey: "restoreSessions")
        secureKeyboardEntry = defaults.bool(forKey: "secureKeyboardEntry")
        confirmMultilinePaste = defaults.object(forKey: "confirmMultilinePaste") == nil ? true : defaults.bool(forKey: "confirmMultilinePaste")
        redactCopies = defaults.bool(forKey: "redactCopies")
        fileOpener = FileOpenerChoice(rawValue: defaults.string(forKey: "fileOpener") ?? "") ?? .leanVSCode
    }

    /// The colour of the first rule whose pattern matches the host, case-insensitively. Empty patterns are ignored.
    public static func hostColor(for host: String, in rules: [HostColorRule]) -> HostColor? {
        rules.first { rule in
            let pattern = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            return !pattern.isEmpty && fnmatch(pattern, host, FNM_CASEFOLD) == 0
        }?.color
    }

    public static func validFontSize(_ value: Double) -> Double {
        value.isFinite ? min(32, max(10, value)) : 13
    }

    public static func reset(in defaults: UserDefaults) {
        defaults.removeObject(forKey: "restoreSessions")
        SessionWorkspace.clear(in: defaults)
        for key in ["appearance", "palette", "fontName", "fontSize", "cursor", "optionAsMeta", "showResourceUsage", "showActivityScanner", "showTabActivity", "showSessionMarks", "notifyInBackground", "hostColorRules", "closeTabOnShellExit", "quitAfterLastSession", "secureKeyboardEntry", "confirmMultilinePaste", "redactCopies", "fileOpener", "shortcuts"] {
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
        defaults.set(showResourceUsage, forKey: "showResourceUsage")
        defaults.set(showActivityScanner, forKey: "showActivityScanner")
        defaults.set(showTabActivity, forKey: "showTabActivity")
        defaults.set(showSessionMarks, forKey: "showSessionMarks")
        defaults.set(notifyInBackground, forKey: "notifyInBackground")
        defaults.set(try? JSONEncoder().encode(hostColorRules), forKey: "hostColorRules")
        defaults.set(closeTabOnShellExit, forKey: "closeTabOnShellExit")
        defaults.set(quitAfterLastSession, forKey: "quitAfterLastSession")
        defaults.set(restoreSessions, forKey: "restoreSessions")
        defaults.set(secureKeyboardEntry, forKey: "secureKeyboardEntry")
        defaults.set(confirmMultilinePaste, forKey: "confirmMultilinePaste")
        defaults.set(redactCopies, forKey: "redactCopies")
        defaults.set(fileOpener.rawValue, forKey: "fileOpener")
    }
}
