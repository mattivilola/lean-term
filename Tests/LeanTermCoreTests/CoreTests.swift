import Foundation
import CoreGraphics
import Testing
@testable import LeanTermCore

@Test func shellLaunchPreservesUserEnvironmentAndUsesLoginShell() {
    let launch = ShellLaunch(account: .init(name: "tester", home: "/Users/tester", shell: "/bin/zsh"),
                             inherited: ["PATH": "/custom/bin:/usr/bin", "LANG": "fi_FI.UTF-8", "TERM": "dumb", "CUSTOM": "preserved"],
                             isExecutable: { $0 == "/bin/zsh" })
    #expect(launch.executable == "/bin/zsh" && launch.execName == "-zsh")
    #expect(launch.directory == "/Users/tester" && !launch.usedFallback)
    #expect(launch.environment.contains("PATH=/custom/bin:/usr/bin"))
    #expect(launch.environment.contains("LANG=fi_FI.UTF-8"))
    #expect(launch.environment.contains("CUSTOM=preserved"))
    #expect(launch.environment.contains("TERM=xterm-256color"))
    #expect(launch.environment.contains("HOME=/Users/tester"))
}

@Test func invalidShellFallsBackAndMissingEnvironmentGetsDefaults() {
    let launch = ShellLaunch(account: .init(name: "tester", home: "/tmp", shell: "relative-shell"),
                             inherited: [:], isExecutable: { _ in true })
    #expect(launch.usedFallback && launch.executable == "/bin/zsh")
    #expect(launch.environment.contains("LANG=en_US.UTF-8"))
    #expect(launch.environment.contains { $0.hasPrefix("PATH=") })
    let locale = ShellLaunch(inherited: ["LC_ALL": "C"], isExecutable: { _ in true })
    #expect(!locale.environment.contains { $0.hasPrefix("LANG=") })
}

@Test func preferencesRejectCorruptValuesAndRoundTrip() throws {
    let name = "LeanTermTests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set("unknown", forKey: "appearance")
    defaults.set(900.0, forKey: "fontSize")
    #expect(Preferences(defaults: defaults).appearance == .system)
    #expect(Preferences(defaults: defaults).fontSize == 32)
    #expect(Preferences.validFontSize(.nan) == 13)
    var value = Preferences()
    value.appearance = .dark; value.palette = .graphite; value.fontSize = 16; value.optionAsMeta = true
    value.showResourceUsage = false; value.showActivityScanner = false; value.showTabActivity = false; value.showSessionMarks = false; value.notifyInBackground = true; value.hostColorRules = [HostColorRule(pattern: "prod-*", color: .red)]; value.closeTabOnShellExit = true; value.quitAfterLastSession = true
    value.save(to: defaults)
    #expect(Preferences(defaults: defaults) == value)
}

@Test func cwdRequiresAnExistingLocalDirectory() {
    #expect(ShellLaunch.localDirectory(from: "file://localhost/tmp") == "/tmp")
    #expect(ShellLaunch.localDirectory(from: "file://untrusted.invalid/tmp") == nil)
    #expect(ShellLaunch.localDirectory(from: "https://example.com/tmp") == nil)
    #expect(ShellLaunch.localDirectory(from: "file:///definitely-not-an-existing-directory") == nil)
}

@Test func windowPlacementRoundTripsAndFitsChangedDisplays() throws {
    let name = "LeanTermTests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let placement = try #require(WindowPlacement(frame: CGRect(x: 200, y: 100, width: 900, height: 600)))
    placement.save(to: defaults)
    #expect(WindowPlacement(defaults: defaults) == placement)
    let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
    #expect(placement.fitted(to: [main]) == placement.frame)
    let disconnected = try #require(WindowPlacement(frame: CGRect(x: 5000, y: 0, width: 900, height: 600)))
    #expect(disconnected.fitted(to: [main]) == CGRect(x: 270, y: 150, width: 900, height: 600))
    let huge = try #require(WindowPlacement(frame: CGRect(x: 0, y: 0, width: 4000, height: 3000)))
    #expect(huge.fitted(to: [main]) == main)
    let external = CGRect(x: -1440, y: 0, width: 1440, height: 900)
    let onExternal = try #require(WindowPlacement(frame: CGRect(x: -1200, y: 50, width: 900, height: 600)))
    #expect(onExternal.fitted(to: [main, external]) == onExternal.frame)
    #expect(WindowPlacement(frame: CGRect(x: CGFloat.infinity, y: 0, width: 900, height: 600)) == nil)
    defaults.set([1, 2, 3], forKey: "windowFrame")
    #expect(WindowPlacement(defaults: defaults) == nil)
}

@Test func recoveryResetsOnlyTheRequestedAppPreferences() throws {
    let name = "LeanTermTests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    var prefs = Preferences(); prefs.appearance = .dark; prefs.fontSize = 18
    prefs.save(to: defaults)
    try #require(WindowPlacement(frame: CGRect(x: 20, y: 20, width: 900, height: 600))).save(to: defaults)
    defaults.set("retained", forKey: "unrelated")
    WindowPlacement.reset(in: defaults)
    #expect(WindowPlacement(defaults: defaults) == nil)
    #expect(Preferences(defaults: defaults) == prefs)
    Preferences.reset(in: defaults)
    #expect(Preferences(defaults: defaults) == Preferences())
    #expect(defaults.string(forKey: "unrelated") == "retained")
}

@Test func shortcutsPersistRejectConflictsAndReset() throws {
    let name = "LeanTermTests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    var value = ShortcutConfiguration()
    #expect(value.binding(for: .previousTab)?.display == "⌘←")
    #expect(value.binding(for: .nextTab)?.display == "⌘→")
    try value.set(.init("n", [.command, .option]), for: .newWindow)
    value.save(to: defaults)
    #expect(ShortcutConfiguration(defaults: defaults) == value)
    #expect(throws: ShortcutConfiguration.Failure.self) { try value.set(.init("t"), for: .newWindow) }
    #expect(throws: ShortcutConfiguration.Failure.self) { try value.set(.init("[", [.command, .shift]), for: .newWindow) }
    #expect(throws: ShortcutConfiguration.Failure.self) { try value.set(.init("c"), for: .newWindow) }
    #expect(throws: ShortcutConfiguration.Failure.self) { try value.set(.init(" "), for: .newWindow) }
    #expect(throws: ShortcutConfiguration.Failure.self) { try value.set(.init("x", .option), for: .newWindow) }
    try value.reset(.newWindow)
    #expect(value == ShortcutConfiguration())
    defaults.set(["newWindow": ["key": "q", "modifiers": 1]], forKey: "shortcuts")
    #expect(ShortcutConfiguration(defaults: defaults) == ShortcutConfiguration())
    Preferences.reset(in: defaults)
    #expect(defaults.object(forKey: "shortcuts") == nil)
}

@Test func sessionExitPreferencesPreserveExistingDefaultsAndPersistIndependently() throws {
    let name = "LeanTermTests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    #expect(!Preferences(defaults: defaults).closeTabOnShellExit)
    #expect(!Preferences(defaults: defaults).quitAfterLastSession)
    #expect(Preferences(defaults: defaults).showResourceUsage)
    #expect(Preferences(defaults: defaults).showActivityScanner)
    #expect(Preferences(defaults: defaults).showTabActivity)
    #expect(Preferences(defaults: defaults).showSessionMarks)
    #expect(Preferences(defaults: defaults).fontName == "SF Mono")
    #expect(Preferences(defaults: defaults).fontSize == 13)
    defaults.set("Menlo", forKey: "fontName")
    #expect(Preferences(defaults: defaults).fontName == "Menlo")
    for close in [false, true] {
        for quit in [false, true] {
            var prefs = Preferences()
            prefs.closeTabOnShellExit = close; prefs.quitAfterLastSession = quit
            prefs.save(to: defaults)
            #expect(Preferences(defaults: defaults) == prefs)
        }
    }
    Preferences.reset(in: defaults)
    #expect(Preferences(defaults: defaults) == Preferences())
}

@Test func hostColorRulesMatchCaseInsensitivelyAndFirstWins() {
    let rules = [HostColorRule(pattern: " ", color: .green), HostColorRule(pattern: "prod-*", color: .red),
                 HostColorRule(pattern: "*", color: .blue)]
    #expect(Preferences.hostColor(for: "PROD-db1", in: rules) == .red)
    #expect(Preferences.hostColor(for: "staging", in: rules) == .blue)
    #expect(Preferences.hostColor(for: "staging", in: Array(rules.prefix(2))) == nil)
}
