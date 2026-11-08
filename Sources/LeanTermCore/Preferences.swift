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
    /// Blinks the cursor; the terminal keeps it steady when Reduce Motion is on.
    public var cursorBlink = false
    /// Multiplier for the terminal's row height, 1.0…1.6 in 0.05 steps.
    public var lineSpacing: Double = 1.0
    public var optionAsMeta = false
    public var showResourceUsage = true
    public var showActivityScanner = true
    public var showTabActivity = true
    public var showSessionMarks = true
    /// Margin bars, scanner pulses and the red finished ring for commands that report an exit code (OSC 133 `D`).
    public var showCommandStatus = true
    /// Off by default: turning it on triggers the macOS notification permission prompt.
    public var notifyInBackground = false
    public var hostColorRules: [HostColorRule] = []
    public var closeTabOnShellExit = false
    public var quitAfterLastSession = false
    public var restoreSessions = false
    public var secureKeyboardEntry = false
    public var confirmMultilinePaste = true
    public var redactCopies = false
    /// Slightly dims split panes other than the focused one.
    public var dimInactivePanes = true
    public var fileOpener = FileOpenerChoice.leanVSCode
    /// The find bar's "Aa" and ".*" toggles.
    public var findMatchCase = false
    public var findUseRegex = false
    /// The dropdown terminal that a global shortcut toggles.
    public var quickTerminalEnabled = true
    public var quickTerminalHotKey = QuickTerminalHotKey.default
    public var quickTerminalHidesOnDeactivate = true
    /// Lines of history each terminal keeps; always one of `scrollbackChoices`.
    public var scrollbackLines = 10_000
    public static let scrollbackChoices = [1_000, 5_000, 10_000, 50_000, 100_000]

    public init() {}

    public init(defaults: UserDefaults) {
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        palette = Palette(rawValue: defaults.string(forKey: "palette") ?? "") ?? .forest
        fontName = defaults.string(forKey: "fontName") ?? "SF Mono"
        let size = defaults.object(forKey: "fontSize") as? Double ?? 13
        fontSize = Self.validFontSize(size)
        scrollbackLines = Self.validScrollback(defaults.object(forKey: "scrollbackLines") as? Int ?? 10_000)
        cursor = Cursor(rawValue: defaults.string(forKey: "cursor") ?? "") ?? .bar
        cursorBlink = defaults.bool(forKey: "cursorBlink")
        lineSpacing = Self.validLineSpacing(defaults.object(forKey: "lineSpacing") as? Double ?? 1.0)
        optionAsMeta = defaults.bool(forKey: "optionAsMeta")
        showResourceUsage = defaults.object(forKey: "showResourceUsage") == nil ? true : defaults.bool(forKey: "showResourceUsage")
        showActivityScanner = defaults.object(forKey: "showActivityScanner") == nil ? true : defaults.bool(forKey: "showActivityScanner")
        showTabActivity = defaults.object(forKey: "showTabActivity") == nil ? true : defaults.bool(forKey: "showTabActivity")
        showSessionMarks = defaults.object(forKey: "showSessionMarks") == nil ? true : defaults.bool(forKey: "showSessionMarks")
        showCommandStatus = defaults.object(forKey: "showCommandStatus") == nil ? true : defaults.bool(forKey: "showCommandStatus")
        notifyInBackground = defaults.bool(forKey: "notifyInBackground")
        hostColorRules = defaults.data(forKey: "hostColorRules").flatMap { try? JSONDecoder().decode([HostColorRule].self, from: $0) } ?? []
        closeTabOnShellExit = defaults.bool(forKey: "closeTabOnShellExit")
        quitAfterLastSession = defaults.bool(forKey: "quitAfterLastSession")
        restoreSessions = defaults.bool(forKey: "restoreSessions")
        secureKeyboardEntry = defaults.bool(forKey: "secureKeyboardEntry")
        confirmMultilinePaste = defaults.object(forKey: "confirmMultilinePaste") == nil ? true : defaults.bool(forKey: "confirmMultilinePaste")
        redactCopies = defaults.bool(forKey: "redactCopies")
        dimInactivePanes = defaults.object(forKey: "dimInactivePanes") == nil ? true : defaults.bool(forKey: "dimInactivePanes")
        fileOpener = FileOpenerChoice(rawValue: defaults.string(forKey: "fileOpener") ?? "") ?? .leanVSCode
        findMatchCase = defaults.bool(forKey: "findMatchCase")
        findUseRegex = defaults.bool(forKey: "findUseRegex")
        quickTerminalEnabled = defaults.object(forKey: "quickTerminalEnabled") == nil ? true : defaults.bool(forKey: "quickTerminalEnabled")
        quickTerminalHidesOnDeactivate = defaults.object(forKey: "quickTerminalHidesOnDeactivate") == nil ? true : defaults.bool(forKey: "quickTerminalHidesOnDeactivate")
        quickTerminalHotKey = defaults.data(forKey: "quickTerminalHotKey")
            .flatMap { try? JSONDecoder().decode(QuickTerminalHotKey.self, from: $0) }
            .flatMap { $0.isValid ? $0 : nil } ?? .default
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

    /// Clamps to 1.0…1.6 and snaps to 0.05 steps.
    public static func validLineSpacing(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        return (min(1.6, max(1.0, value)) * 20).rounded() / 20
    }

    /// Snaps any value to the nearest allowed scrollback size; ties go to the larger one.
    public static func validScrollback(_ value: Int) -> Int {
        scrollbackChoices.min { (abs($0 - value), -$0) < (abs($1 - value), -$1) } ?? 10_000
    }

    public static func reset(in defaults: UserDefaults) {
        defaults.removeObject(forKey: "restoreSessions")
        SessionWorkspace.clear(in: defaults)
        for key in ["appearance", "palette", "fontName", "fontSize", "scrollbackLines", "cursor", "cursorBlink", "lineSpacing", "optionAsMeta", "showResourceUsage", "showActivityScanner", "showTabActivity", "showSessionMarks", "showCommandStatus", "notifyInBackground", "hostColorRules", "closeTabOnShellExit", "quitAfterLastSession", "secureKeyboardEntry", "confirmMultilinePaste", "redactCopies", "dimInactivePanes", "fileOpener", "findMatchCase", "findUseRegex", "quickTerminalEnabled", "quickTerminalHotKey", "quickTerminalHidesOnDeactivate", "shortcuts"] {
            defaults.removeObject(forKey: key)
        }
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(appearance.rawValue, forKey: "appearance")
        defaults.set(palette.rawValue, forKey: "palette")
        defaults.set(fontName, forKey: "fontName")
        defaults.set(Self.validFontSize(fontSize), forKey: "fontSize")
        defaults.set(Self.validScrollback(scrollbackLines), forKey: "scrollbackLines")
        defaults.set(cursor.rawValue, forKey: "cursor")
        defaults.set(cursorBlink, forKey: "cursorBlink")
        defaults.set(Self.validLineSpacing(lineSpacing), forKey: "lineSpacing")
        defaults.set(optionAsMeta, forKey: "optionAsMeta")
        defaults.set(showResourceUsage, forKey: "showResourceUsage")
        defaults.set(showActivityScanner, forKey: "showActivityScanner")
        defaults.set(showTabActivity, forKey: "showTabActivity")
        defaults.set(showSessionMarks, forKey: "showSessionMarks")
        defaults.set(showCommandStatus, forKey: "showCommandStatus")
        defaults.set(notifyInBackground, forKey: "notifyInBackground")
        defaults.set(try? JSONEncoder().encode(hostColorRules), forKey: "hostColorRules")
        defaults.set(closeTabOnShellExit, forKey: "closeTabOnShellExit")
        defaults.set(quitAfterLastSession, forKey: "quitAfterLastSession")
        defaults.set(restoreSessions, forKey: "restoreSessions")
        defaults.set(secureKeyboardEntry, forKey: "secureKeyboardEntry")
        defaults.set(confirmMultilinePaste, forKey: "confirmMultilinePaste")
        defaults.set(redactCopies, forKey: "redactCopies")
        defaults.set(dimInactivePanes, forKey: "dimInactivePanes")
        defaults.set(fileOpener.rawValue, forKey: "fileOpener")
        defaults.set(findMatchCase, forKey: "findMatchCase")
        defaults.set(findUseRegex, forKey: "findUseRegex")
        defaults.set(quickTerminalEnabled, forKey: "quickTerminalEnabled")
        defaults.set(try? JSONEncoder().encode(quickTerminalHotKey), forKey: "quickTerminalHotKey")
        defaults.set(quickTerminalHidesOnDeactivate, forKey: "quickTerminalHidesOnDeactivate")
    }
}
