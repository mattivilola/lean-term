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

    defaults.set(Data(#"{"version":2,"groups":[],"activeGroup":0}"#.utf8), forKey: "sessionWorkspace")
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
