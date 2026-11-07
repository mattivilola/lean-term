import Foundation

public struct ShortcutModifiers: OptionSet, Equatable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = Self(rawValue: 1)
    public static let shift = Self(rawValue: 2)
    public static let option = Self(rawValue: 4)
    public static let control = Self(rawValue: 8)
}

public struct ShortcutBinding: Equatable, Sendable {
    public let key: String
    public let modifiers: ShortcutModifiers
    public init(_ key: String, _ modifiers: ShortcutModifiers = .command) {
        if let scalar = key.unicodeScalars.first, key.unicodeScalars.count == 1,
           (65...90).contains(scalar.value) {
            self.key = String(UnicodeScalar(scalar.value + 32)!)
        } else { self.key = key }
        self.modifiers = modifiers
    }
    public var isValid: Bool {
        key.unicodeScalars.count == 1 && modifiers.contains(.command) && modifiers.rawValue & ~15 == 0
    }
    public var isSystemReserved: Bool {
        key == " " || key == "\t" || (key == "\u{1B}" && modifiers.contains(.option))
    }
    public var display: String {
        let names = ["\u{F702}": "←", "\u{F703}": "→", "\u{F700}": "↑", "\u{F701}": "↓",
                     "\r": "↩", "\t": "⇥", " ": "Space", "\u{7F}": "⌫", "\u{1B}": "Esc"]
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        if let name = names[key] { return text + name }
        if let scalar = key.unicodeScalars.first {
            if (0xF704...0xF726).contains(scalar.value) { return text + "F\(scalar.value - 0xF704 + 1)" }
            if (97...122).contains(scalar.value) { return text + String(UnicodeScalar(scalar.value - 32)!) }
        }
        return text + key
    }
}

public enum ShortcutAction: String, CaseIterable, Sendable {
    case newWindow, newTab, close, previousTab, nextTab, find, findNext, findPrevious
    case clearScrollback, largerText, smallerText, defaultText, settings, shortcuts, about, updates, quit
    case copyWithoutSensitiveData, previousPrompt, nextPrompt, selectCommandOutput
    case splitRight, splitDown, selectPaneLeft, selectPaneRight, selectPaneAbove, selectPaneBelow, zoomPane, equalizePanes
    case renameTab, tab1, tab2, tab3, tab4, tab5, tab6, tab7, tab8, lastTab

    public var title: String {
        switch self {
        case .newWindow: "New Window"
        case .newTab: "New Tab"
        case .close: "Close Window or Tab"
        case .previousTab: "Previous Tab"
        case .nextTab: "Next Tab"
        case .find: "Find"
        case .findNext: "Find Next"
        case .findPrevious: "Find Previous"
        case .clearScrollback: "Clear Screen and Scrollback"
        case .largerText: "Larger Text"
        case .smallerText: "Smaller Text"
        case .defaultText: "Default Text Size"
        case .settings: "Settings"
        case .shortcuts: "Keyboard Shortcuts"
        case .about: "About Lean Term"
        case .updates: "Check for Updates"
        case .quit: "Quit Lean Term"
        case .copyWithoutSensitiveData: "Copy Without Sensitive Data"
        case .previousPrompt: "Previous Prompt"
        case .nextPrompt: "Next Prompt"
        case .selectCommandOutput: "Select Command Output"
        case .renameTab: "Rename Tab"
        case .splitRight: "Split Right"
        case .splitDown: "Split Down"
        case .selectPaneLeft: "Select Pane Left"
        case .selectPaneRight: "Select Pane Right"
        case .selectPaneAbove: "Select Pane Above"
        case .selectPaneBelow: "Select Pane Below"
        case .zoomPane: "Zoom Pane"
        case .equalizePanes: "Equalize Panes"
        case .tab1: "Select Tab 1"
        case .tab2: "Select Tab 2"
        case .tab3: "Select Tab 3"
        case .tab4: "Select Tab 4"
        case .tab5: "Select Tab 5"
        case .tab6: "Select Tab 6"
        case .tab7: "Select Tab 7"
        case .tab8: "Select Tab 8"
        case .lastTab: "Select Last Tab"
        }
    }
    public var defaultBinding: ShortcutBinding? {
        switch self {
        case .newWindow: .init("n")
        case .newTab: .init("t")
        case .close: .init("w")
        case .previousTab: .init("\u{F702}")
        case .nextTab: .init("\u{F703}")
        case .find: .init("f")
        case .findNext: .init("g")
        case .findPrevious: .init("g", [.command, .shift])
        case .clearScrollback: .init("k")
        case .largerText: .init("+")
        case .smallerText: .init("-")
        case .defaultText: .init("0")
        case .settings: .init(",")
        case .shortcuts: .init("?")
        case .quit: .init("q")
        case .copyWithoutSensitiveData: .init("c", [.command, .option])
        case .previousPrompt: .init("\u{F700}")
        case .nextPrompt: .init("\u{F701}")
        case .selectCommandOutput: .init("a", [.command, .shift])
        case .renameTab: .init("r", [.command, .shift])
        case .splitRight: .init("d")
        case .splitDown: .init("d", [.command, .shift])
        case .selectPaneLeft: .init("\u{F702}", [.command, .option])
        case .selectPaneRight: .init("\u{F703}", [.command, .option])
        case .selectPaneAbove: .init("\u{F700}", [.command, .option])
        case .selectPaneBelow: .init("\u{F701}", [.command, .option])
        case .zoomPane: .init("\r", [.command, .shift])
        case .equalizePanes: .init("=", [.command, .control])
        case .tab1: .init("1")
        case .tab2: .init("2")
        case .tab3: .init("3")
        case .tab4: .init("4")
        case .tab5: .init("5")
        case .tab6: .init("6")
        case .tab7: .init("7")
        case .tab8: .init("8")
        case .lastTab: .init("9")
        case .about, .updates: nil
        }
    }
    public var aliases: [ShortcutBinding] {
        switch self {
        case .previousTab: [.init("[", [.command, .shift])]
        case .nextTab: [.init("]", [.command, .shift])]
        default: []
        }
    }
}

public struct ShortcutConfiguration: Equatable, Sendable {
    private var overrides: [ShortcutAction: ShortcutBinding] = [:]
    public init() {}
    public init(defaults: UserDefaults) {
        let values = defaults.dictionary(forKey: "shortcuts") ?? [:]
        for action in ShortcutAction.allCases {
            guard let entry = values[action.rawValue] as? [String: Any],
                  let key = entry["key"] as? String, let modifiers = entry["modifiers"] as? Int else { continue }
            let binding = ShortcutBinding(key, .init(rawValue: modifiers))
            if binding.isValid && !binding.isSystemReserved { overrides[action] = binding }
        }
        // Invalid external edits must not shadow essential menu commands.
        for (action, binding) in overrides {
            if conflict(for: binding, excluding: action) != nil { overrides = [:]; break }
        }
    }
    public func binding(for action: ShortcutAction) -> ShortcutBinding? {
        if let override = overrides[action] { return override }
        let binding = action.defaultBinding
        // Existing personal bindings take precedence over newly introduced tab defaults.
        let newTabActions: Set<ShortcutAction> = [.copyWithoutSensitiveData, .previousPrompt, .nextPrompt, .selectCommandOutput, .renameTab, .splitRight, .splitDown, .selectPaneLeft, .selectPaneRight, .selectPaneAbove, .selectPaneBelow, .zoomPane, .equalizePanes, .tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8, .lastTab]
        if newTabActions.contains(action), let binding, overrides.values.contains(binding) { return nil }
        return binding
    }
    public mutating func set(_ binding: ShortcutBinding, for action: ShortcutAction) throws {
        guard binding.isValid else { throw Failure(message: "Include ⌘ and one other key.") }
        guard !binding.isSystemReserved else { throw Failure(message: "That combination is reserved by macOS.") }
        if let conflict = conflict(for: binding, excluding: action) {
            throw Failure(message: "\(binding.display) is already used by \(conflict).")
        }
        overrides[action] = binding == action.defaultBinding ? nil : binding
    }
    public mutating func reset(_ action: ShortcutAction) throws {
        if let binding = action.defaultBinding, let other = conflict(for: binding, excluding: action) {
            throw Failure(message: "The default shortcut is currently used by \(other). Change that shortcut first, or restore all defaults.")
        }
        overrides.removeValue(forKey: action)
    }
    public func save(to defaults: UserDefaults) {
        var values: [String: [String: Any]] = [:]
        for (action, binding) in overrides { values[action.rawValue] = ["key": binding.key, "modifiers": binding.modifiers.rawValue] }
        defaults.set(values, forKey: "shortcuts")
    }
    private func conflict(for candidate: ShortcutBinding, excluding action: ShortcutAction) -> String? {
        for other in ShortcutAction.allCases where other != action {
            if binding(for: other) == candidate || other.aliases.contains(candidate) { return other.title }
        }
        let fixed: [(String, ShortcutBinding)] = [
            ("Copy", .init("c")), ("Paste", .init("v")), ("Cut", .init("x")), ("Select All", .init("a")),
            ("Undo", .init("z")), ("Redo", .init("z", [.command, .shift])), ("Minimize", .init("m")),
            ("Hide", .init("h")), ("Hide Others", .init("h", [.command, .option])),
            ("Full Screen", .init("f", [.command, .control]))
        ]
        return fixed.first { $0.1 == candidate }?.0
    }
    public struct Failure: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }
}
