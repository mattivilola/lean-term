import Foundation

/// A local directory and optional user-facing name for a terminal tab.
public struct SessionTab: Codable, Equatable, Sendable {
    public var directory: String
    public var customName: String?

    public init(directory: String, customName: String? = nil) {
        self.directory = directory
        self.customName = Self.cleanedName(customName)
    }

    /// Trims whitespace, removes control scalars, and limits names to 64 characters.
    public static func cleanedName(_ value: String?) -> String? {
        guard let value else { return nil }
        let withoutControls = String(value.unicodeScalars.filter {
            $0.properties.generalCategory != .control
        })
        let trimmed = withoutControls.trimmingCharacters(in: .whitespacesAndNewlines)
        let bounded = String(trimmed.prefix(64))
        let result = bounded.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}

/// The tabs that were open in one terminal window and its selected tab.
public struct SessionWindowGroup: Codable, Equatable, Sendable {
    public var tabs: [SessionTab]
    public var selectedTab: Int

    public init(tabs: [SessionTab], selectedTab: Int = 0) {
        self.tabs = tabs
        self.selectedTab = selectedTab
    }
}

/// A bounded snapshot of local terminal workspace state.
public struct SessionWorkspace: Codable, Equatable, Sendable {
    public let version: Int
    public var groups: [SessionWindowGroup]
    public var activeGroup: Int

    private static let defaultsKey = "sessionWorkspace"
    private static let maximumGroups = 20
    private static let maximumTabs = 100

    public init(groups: [SessionWindowGroup], activeGroup: Int = 0) {
        self.version = 1
        self.groups = groups
        self.activeGroup = activeGroup
    }

    /// Loads and validates a saved workspace, replacing unusable directories with `home`.
    public static func load(
        from defaults: UserDefaults,
        home: String = NSHomeDirectory(),
        directoryExists: (String) -> Bool = { path in
            var isDirectory = ObjCBool(false)
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    ) -> SessionWorkspace? {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(SessionWorkspace.self, from: data),
              decoded.version == 1,
              decoded.groups.count <= maximumGroups,
              decoded.groups.reduce(0, { $0 + $1.tabs.count }) <= maximumTabs else {
            return nil
        }

        let groups = decoded.groups.compactMap { group -> SessionWindowGroup? in
            let tabs = group.tabs.map { tab -> SessionTab in
                let path = tab.directory
                let directory = path.hasPrefix("/") && directoryExists(path) ? path : home
                return SessionTab(directory: directory, customName: tab.customName)
            }
            guard !tabs.isEmpty else { return nil }
            return SessionWindowGroup(tabs: tabs, selectedTab: clamped(group.selectedTab, count: tabs.count))
        }

        return SessionWorkspace(groups: groups, activeGroup: clamped(decoded.activeGroup, count: groups.count))
    }

    public func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    public static func clear(in defaults: UserDefaults) {
        defaults.removeObject(forKey: defaultsKey)
    }

    private static func clamped(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index, 0), count - 1)
    }
}
