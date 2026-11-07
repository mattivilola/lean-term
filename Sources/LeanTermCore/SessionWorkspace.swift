import Foundation

/// A tab's split arrangement as saved: the `PaneLayout` tree with each leaf carrying its pane's folder.
public indirect enum SavedPaneLayout: Codable, Equatable, Sendable {
    case pane(directory: String)
    case split(axis: PaneLayout.Axis, ratio: Double, first: SavedPaneLayout, second: SavedPaneLayout)

    /// At most this many panes are restored per tab; further splits are dropped.
    public static let maximumPanes = 16

    /// Converts a live layout, taking each pane's folder from `directories` (missing ids get `fallback`).
    public init(_ layout: PaneLayout, directories: [UUID: String], fallback: String) {
        switch layout {
        case .pane(let id):
            self = .pane(directory: directories[id] ?? fallback)
        case .split(let axis, let ratio, let first, let second):
            self = .split(axis: axis, ratio: ratio,
                          first: Self(first, directories: directories, fallback: fallback),
                          second: Self(second, directories: directories, fallback: fallback))
        }
    }

    /// The folders of all panes, in reading order.
    public var directories: [String] {
        switch self {
        case .pane(let directory): [directory]
        case .split(_, _, let first, let second): first.directories + second.directories
        }
    }

    /// Instantiates the tree with `ids` (one per leaf, in reading order) as pane ids.
    public func paneLayout(ids: [UUID]) -> PaneLayout {
        var next = ids.makeIterator()
        return paneLayout(&next)
    }

    private func paneLayout(_ ids: inout IndexingIterator<[UUID]>) -> PaneLayout {
        switch self {
        case .pane:
            return .pane(ids.next() ?? UUID())
        case .split(let axis, let ratio, let first, let second):
            let firstLayout = first.paneLayout(&ids)
            return .split(axis: axis, ratio: ratio, first: firstLayout, second: second.paneLayout(&ids))
        }
    }

    /// Clamps ratios, resolves folders and drops panes beyond `budget`; a split that loses a child becomes the other.
    fileprivate func validated(budget: inout Int, resolve: (String) -> String) -> SavedPaneLayout? {
        switch self {
        case .pane(let directory):
            guard budget > 0 else { return nil }
            budget -= 1
            return .pane(directory: resolve(directory))
        case .split(let axis, let ratio, let first, let second):
            let first = first.validated(budget: &budget, resolve: resolve)
            let second = second.validated(budget: &budget, resolve: resolve)
            guard let first else { return second }
            guard let second else { return first }
            let bounds = PaneLayout.ratioRange
            let safe = ratio.isFinite ? min(max(ratio, bounds.lowerBound), bounds.upperBound) : 0.5
            return .split(axis: axis, ratio: safe, first: first, second: second)
        }
    }
}

/// A local directory and optional user-facing name for a terminal tab, with its optional split layout.
/// `directory` is always the focused pane's folder, so the tab label and older readers keep working.
public struct SessionTab: Codable, Equatable, Sendable {
    public var directory: String
    public var customName: String?
    /// Nil for a single pane.
    public var layout: SavedPaneLayout?
    /// Index of the focused pane in the layout's reading order.
    public var focusedPane: Int

    public init(directory: String, customName: String? = nil, layout: SavedPaneLayout? = nil, focusedPane: Int = 0) {
        self.directory = directory
        self.customName = Self.cleanedName(customName)
        self.layout = layout
        self.focusedPane = focusedPane
    }

    private enum CodingKeys: String, CodingKey { case directory, customName, layout, focusedPane }

    /// A missing or unreadable layout (or focus) decodes as a single pane instead of failing the workspace.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            directory: try container.decode(String.self, forKey: .directory),
            customName: try container.decodeIfPresent(String.self, forKey: .customName),
            layout: try? container.decodeIfPresent(SavedPaneLayout.self, forKey: .layout),
            focusedPane: (try? container.decodeIfPresent(Int.self, forKey: .focusedPane)) ?? 0
        )
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

    /// Version 1 had no split layouts; both are readable, version 2 is always written.
    private static let currentVersion = 2
    private static let defaultsKey = "sessionWorkspace"
    private static let maximumGroups = 20
    private static let maximumTabs = 100

    public init(groups: [SessionWindowGroup], activeGroup: Int = 0) {
        self.version = Self.currentVersion
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
              (1...currentVersion).contains(decoded.version),
              decoded.groups.count <= maximumGroups,
              decoded.groups.reduce(0, { $0 + $1.tabs.count }) <= maximumTabs else {
            return nil
        }

        let groups = decoded.groups.compactMap { group -> SessionWindowGroup? in
            let tabs = group.tabs.map { tab -> SessionTab in
                func resolve(_ path: String) -> String {
                    path.hasPrefix("/") && directoryExists(path) ? path : home
                }
                var budget = SavedPaneLayout.maximumPanes
                if let layout = tab.layout?.validated(budget: &budget, resolve: resolve), layout.directories.count > 1 {
                    let directories = layout.directories
                    let focused = clamped(tab.focusedPane, count: directories.count)
                    return SessionTab(directory: directories[focused], customName: tab.customName,
                                      layout: layout, focusedPane: focused)
                }
                return SessionTab(directory: resolve(tab.directory), customName: tab.customName)
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
