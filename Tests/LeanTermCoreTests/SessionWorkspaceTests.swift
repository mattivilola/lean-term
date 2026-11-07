import Foundation
import Testing
@testable import LeanTermCore

@Test func sessionWorkspaceRoundTripsOrderNamesAndClampedIndexes() throws {
    let name = "LeanTermTests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }

    let workspace = SessionWorkspace(groups: [
        SessionWindowGroup(tabs: [
            SessionTab(directory: "/home/test", customName: " \nFirst\u{7} tab \n"),
            SessionTab(directory: "/work/project", customName: String(repeating: "x", count: 70))
        ], selectedTab: 100),
        SessionWindowGroup(tabs: [SessionTab(directory: "/var/tmp")], selectedTab: -3)
    ], activeGroup: 100)

    workspace.save(to: defaults)
    let loaded = try #require(SessionWorkspace.load(
        from: defaults,
        home: "/home/test",
        directoryExists: { ["/home/test", "/work/project", "/var/tmp"].contains($0) }
    ))

    #expect(loaded.groups.map { $0.tabs.map(\.directory) } == [
        ["/home/test", "/work/project"], ["/var/tmp"]
    ])
    #expect(loaded.groups.map(\.selectedTab) == [1, 0])
    #expect(loaded.activeGroup == 1)
    #expect(loaded.groups[0].tabs.map(\.customName) == ["First tab", String(repeating: "x", count: 64)])
    #expect(SessionTab.cleanedName(" \u{7} name \n") == "name")
    #expect(SessionTab.cleanedName(" \n \t") == nil)
}

@Test func sessionWorkspaceRejectsCorruptUnsupportedAndOversizedData() throws {
    let name = "LeanTermTests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }

    defaults.set(Data("not JSON".utf8), forKey: "sessionWorkspace")
    #expect(SessionWorkspace.load(from: defaults) == nil)

    defaults.set(Data(#"{"version":3,"groups":[],"activeGroup":0}"#.utf8), forKey: "sessionWorkspace")
    #expect(SessionWorkspace.load(from: defaults) == nil)

    let tooManyGroups = SessionWorkspace(groups: (0..<21).map { _ in
        SessionWindowGroup(tabs: [SessionTab(directory: "/tmp")])
    })
    defaults.set(try JSONEncoder().encode(tooManyGroups), forKey: "sessionWorkspace")
    #expect(SessionWorkspace.load(from: defaults) == nil)

    let tooManyTabs = SessionWorkspace(groups: [
        SessionWindowGroup(tabs: (0..<101).map { _ in SessionTab(directory: "/tmp") })
    ])
    defaults.set(try JSONEncoder().encode(tooManyTabs), forKey: "sessionWorkspace")
    #expect(SessionWorkspace.load(from: defaults) == nil)
}

@Test func sessionWorkspaceFallsBackForRelativeAndMissingDirectories() throws {
    let name = "LeanTermTests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }

    SessionWorkspace(groups: [SessionWindowGroup(tabs: [
        SessionTab(directory: "relative/project"),
        SessionTab(directory: "/gone/project"),
        SessionTab(directory: "/existing/project")
    ])]).save(to: defaults)

    let loaded = try #require(SessionWorkspace.load(
        from: defaults,
        home: "/home/test",
        directoryExists: { $0 == "/existing/project" }
    ))
    #expect(loaded.groups[0].tabs.map(\.directory) == [
        "/home/test", "/home/test", "/existing/project"
    ])
}

@Test func sessionWorkspaceReadsVersionOneAndRoundTripsSplitLayouts() throws {
    let name = "LeanTermTests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let exists: (String) -> Bool = { ["/a", "/b", "/c"].contains($0) }

    defaults.set(Data(#"{"version":1,"groups":[{"tabs":[{"directory":"/a"}],"selectedTab":0}],"activeGroup":0}"#.utf8),
                 forKey: "sessionWorkspace")
    let old = try #require(SessionWorkspace.load(from: defaults, home: "/h", directoryExists: exists))
    #expect(old.groups[0].tabs == [SessionTab(directory: "/a")])

    let layout = SavedPaneLayout.split(axis: .horizontal, ratio: 0.3, first: .pane(directory: "/a"),
        second: .split(axis: .vertical, ratio: 2, first: .pane(directory: "/gone"), second: .pane(directory: "/c")))
    SessionWorkspace(groups: [SessionWindowGroup(tabs: [
        SessionTab(directory: "/gone", layout: layout, focusedPane: 1)
    ])]).save(to: defaults)
    let loaded = try #require(SessionWorkspace.load(from: defaults, home: "/h", directoryExists: exists))
    let tab = loaded.groups[0].tabs[0]
    #expect(loaded.version == 2)
    #expect(tab.focusedPane == 1 && tab.directory == "/h")
    #expect(tab.layout == .split(axis: .horizontal, ratio: 0.3, first: .pane(directory: "/a"),
        second: .split(axis: .vertical, ratio: 0.95, first: .pane(directory: "/h"), second: .pane(directory: "/c"))))

    defaults.set(Data(#"{"version":2,"groups":[{"tabs":[{"directory":"/b","layout":{"bogus":1},"focusedPane":"x"}],"selectedTab":0}],"activeGroup":0}"#.utf8),
                 forKey: "sessionWorkspace")
    let corrupt = try #require(SessionWorkspace.load(from: defaults, home: "/h", directoryExists: exists))
    #expect(corrupt.groups[0].tabs == [SessionTab(directory: "/b")])
}
