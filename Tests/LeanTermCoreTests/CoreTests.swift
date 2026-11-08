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
    #expect(Preferences.validScrollback(0) == 1_000)
    #expect(Preferences.validScrollback(7_500) == 10_000)
    #expect(Preferences.validScrollback(2_000_000) == 100_000)
    defaults.set(12_345, forKey: "scrollbackLines")
    #expect(Preferences(defaults: defaults).scrollbackLines == 10_000)
    var value = Preferences()
    value.restoreSessions = true
    value.appearance = .dark; value.palette = .graphite; value.fontSize = 16; value.scrollbackLines = 50_000; value.optionAsMeta = true
    value.showResourceUsage = false; value.showActivityScanner = false; value.showTabActivity = false; value.showSessionMarks = false; value.showCommandStatus = false; value.notifyInBackground = true; value.hostColorRules = [HostColorRule(pattern: "prod-*", color: .red)]; value.closeTabOnShellExit = true; value.quitAfterLastSession = true; value.secureKeyboardEntry = true; value.confirmMultilinePaste = false; value.redactCopies = true; value.dimInactivePanes = false; value.fileOpener = .app("com.apple.TextEdit")
    value.findMatchCase = true; value.findUseRegex = true
    value.quickTerminalEnabled = false; value.quickTerminalHidesOnDeactivate = false
    value.quickTerminalHotKey = QuickTerminalHotKey(keyCode: 49, key: " ", modifiers: [.control, .option])
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
    #expect(value.binding(for: .tab1)?.display == "⌘1")
    #expect(value.binding(for: .lastTab)?.display == "⌘9")
    #expect(value.binding(for: .renameTab)?.display == "⇧⌘R")
    #expect(value.binding(for: .previousPrompt)?.display == "⌘↑")
    #expect(value.binding(for: .nextPrompt)?.display == "⌘↓")
    #expect(value.binding(for: .selectCommandOutput)?.display == "⇧⌘A")
    #expect(throws: ShortcutConfiguration.Failure.self) { try value.set(.init("1"), for: .newWindow) }
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
    defaults.set(["newWindow": ["key": "1", "modifiers": 1]], forKey: "shortcuts")
    let legacy = ShortcutConfiguration(defaults: defaults)
    #expect(legacy.binding(for: .newWindow) == .init("1"))
    #expect(legacy.binding(for: .tab1) == nil)
    #expect(legacy.binding(for: .nextTab)?.display == "⌘→")
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
    #expect(Preferences(defaults: defaults).showCommandStatus)
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

@Test func shellEscapeBackslashesMetacharactersLikeTerminalApp() {
    #expect(ShellEscape.path("/tmp/My Files/a&b (1).txt") == "/tmp/My\\ Files/a\\&b\\ \\(1\\).txt")
    #expect(ShellEscape.path("it's \"x\" $HOME `id` ~ #!") == "it\\'s\\ \\\"x\\\"\\ \\$HOME\\ \\`id\\`\\ \\~\\ \\#\\!")
    #expect(ShellEscape.path("/plain/path-1.2_x") == "/plain/path-1.2_x")
    #expect(ShellEscape.path("a\nrm -rf ~") == "$'a\\nrm -rf ~'")
    #expect(ShellEscape.path("a\tb'c\\d\u{1B}") == "$'a\\tb\\'c\\\\d\\x1B'")
}

@Test func sshLinksAcceptOnlySafeUsersHostsAndPorts() throws {
    func command(_ text: String) -> String? { URL(string: text).flatMap(SSHLink.init)?.command }
    #expect(command("ssh://example.com") == "ssh example.com")
    #expect(command("ssh://me.x_y@host-1.example.com:2222/") == "ssh -p 2222 me.x_y@host-1.example.com")
    #expect(command("SSH://10.0.0.1:22") == "ssh -p 22 10.0.0.1")
    #expect(command("ssh://root@[fe80::1]:2200") == "ssh -p 2200 root@fe80::1")
    for bad in ["ssh://", "ssh://-oProxyCommand=x", "ssh://a;rm@host", "ssh://host:0", "ssh://host:65536", "ssh://host:22:22",
                "ssh://user:pw@host", "ssh://host/path", "ssh://host?x=1", "ssh://ho%20st", "ssh://a@b@host", "ssh://[abc]", "https://host"] {
        #expect(command(bad) == nil, "\(bad)")
    }
}

@Test func pathDetectionFindsPathsWithLocationsAroundAColumn() {
    func detect(_ line: String, _ marker: String) -> DetectedPath? {
        let offset = line.distance(from: line.startIndex, to: line.range(of: marker)!.lowerBound)
        return PathDetection.path(in: line, at: offset)
    }
    #expect(detect("error: /Users/me/ab.swift:12:5: oops", "Users") == DetectedPath(path: "/Users/me/ab.swift", line: 12, column: 5))
    #expect(detect("see Sources/App/main.swift:12:5: error", "main") == DetectedPath(path: "Sources/App/main.swift", line: 12, column: 5))
    #expect(detect("at (./lib/x.ts:7)", "lib") == DetectedPath(path: "./lib/x.ts", line: 7, column: nil))
    #expect(detect("'../up/file.c'.", "file") == DetectedPath(path: "../up/file.c", line: nil, column: nil))
    #expect(detect("open ~/notes.md,", "notes") == DetectedPath(path: "~/notes.md", line: nil, column: nil))
    #expect(detect("Foo.java(12,5) failed", "Foo") == DetectedPath(path: "Foo.java", line: 12, column: 5))
    #expect(detect("  File \"/tmp/t.py\", line 12, in <module>", "tmp") == DetectedPath(path: "/tmp/t.py", line: 12, column: nil))
    #expect(detect("diff --git a/src/x.rs b/src/x.rs", "src/x.rs b") == DetectedPath(path: "a/src/x.rs", line: nil, column: nil))
    #expect(detect("version 1.2.3 and https://example.com/a/b", "1.2") == nil)
    #expect(detect("https://example.com/a/b", "example") == nil)
    #expect(detect("plain words", "words") == nil)
    #expect(PathDetection.strippingGitPrefix("b/src/x.rs") == "src/x.rs")
    #expect(PathDetection.strippingGitPrefix("src/x.rs") == nil)
    // Wide characters occupy two columns but one character.
    #expect(PathDetection.characterOffset(ofColumn: 5, in: "日本ab") == 3)
    #expect(PathDetection.characterOffset(ofColumn: 4, in: "日本ab") == 2)
    #expect(PathDetection.characterOffset(ofColumn: 3, in: "日本ab") == 1)
    #expect(PathDetection.column(ofCharacterOffset: 2, in: "日本ab") == 4)
    #expect(PathDetection.column(ofCharacterOffset: 4, in: "日本ab") == 6)
    // The highlighted token includes a location suffix but not surrounding punctuation.
    #expect(PathDetection.match(in: "error: /a/b.swift:12:5: oops", at: 10)?.characters == 7..<22)
    #expect(PathDetection.match(in: "at (./lib/x.ts:7)", at: 6)?.characters == 4..<16)
    #expect(PathDetection.match(in: "Foo.java(12,5) failed", at: 1)?.characters == 0..<14)
    #expect(PathDetection.match(in: "'../up/file.c'.", at: 4)?.characters == 1..<13)
}

@Test func commandOutputCandidatesFollowViewportOrLiveBottom() {
    let spans = [CommandSpan(promptRow: 1, lastRow: 3, exitCode: 0),
                 CommandSpan(promptRow: 6, lastRow: 7, exitCode: 2),
                 CommandSpan(promptRow: 8, lastRow: 9, exitCode: nil)]
    #expect(CommandOutputLocator.candidates(spans: spans, viewportTop: 5, atLiveBottom: false) == [spans[0]])
    #expect(CommandOutputLocator.candidates(spans: spans, viewportTop: 7, atLiveBottom: false) == [spans[1]])
    #expect(CommandOutputLocator.candidates(spans: spans, viewportTop: 0, atLiveBottom: false).isEmpty)
    #expect(CommandOutputLocator.candidates(spans: spans, viewportTop: 5, atLiveBottom: true) == spans.reversed())
}

@Test func statusBarsCoverFinishedCommandsClippedToTheViewport() {
    let spans = [CommandSpan(promptRow: 0, lastRow: 4, exitCode: 0, hasOutput: true),
                 CommandSpan(promptRow: 5, lastRow: 9, exitCode: 130),
                 CommandSpan(promptRow: 10, lastRow: 14, exitCode: 1),
                 CommandSpan(promptRow: 15, lastRow: 16, exitCode: nil),
                 CommandSpan(promptRow: 17, lastRow: 17, exitCode: 0),
                 CommandSpan(promptRow: 18, lastRow: 18, exitCode: 1)]
    let bars = CommandStatusLayout.bars(spans: spans, viewportTop: 3, visibleRows: 10)
    #expect(bars.map(\.promptRow) == [0, 5, 10])
    #expect(bars.map(\.firstRow) == [0, 2, 7])
    #expect(bars.map(\.lastRow) == [1, 6, 9])
    #expect(bars.map(\.outcome) == [.succeeded, .interrupted(signal: 2), .failed(exitCode: 1)])
    // A silent success (row 17) gets no bar, a silent failure (row 18) does.
    #expect(CommandStatusLayout.bars(spans: spans, viewportTop: 17, visibleRows: 5).map(\.promptRow) == [18])
    #expect(CommandStatusLayout.bars(spans: spans, viewportTop: 19, visibleRows: 5).isEmpty)
}

@Test func commandOutcomeClassifiesExitCodes() {
    #expect(CommandOutcome(exitCode: 0) == .succeeded)
    #expect(CommandOutcome(exitCode: 2) == .failed(exitCode: 2))
    #expect(CommandOutcome(exitCode: 127).summary == "Failed · exit 127")
    #expect(CommandOutcome(exitCode: 130) == .interrupted(signal: 2))
    #expect(CommandOutcome(exitCode: 130).summary == "Interrupted · signal 2")
    #expect(CommandOutcome.succeeded.summary == "Succeeded")
    #expect(CommandOutcome(exitCode: 1).pulse(after: 0.1) == .failure)
    #expect(CommandOutcome(exitCode: 130).pulse(after: 60) == nil)
    #expect(CommandOutcome(exitCode: 0).pulse(after: 9.9) == nil)
    #expect(CommandOutcome(exitCode: 0).pulse(after: nil) == nil)
    #expect(CommandOutcome(exitCode: 0).pulse(after: 10) == .success)
    #expect(CommandOutcome.notificationBody(exitCode: 3, duration: "12 s") == "Failed (exit 3) after 12 s")
    #expect(CommandOutcome.notificationBody(exitCode: 0, duration: "12 s") == "Finished after 12 s")
    #expect(CommandOutcome.notificationBody(exitCode: nil, duration: "12 s") == "Finished after 12 s")
}

@Test func shellMarksParseOsc133Payloads() {
    func mark(_ text: String) -> ShellMark { ShellMark(osc133: Array(text.utf8)) }
    #expect(mark("A") == .promptStart)
    #expect(mark("A;k=s") == .promptStart)
    #expect(mark("C") == .commandStart)
    #expect(mark("D;0") == .commandEnd(exitCode: 0))
    #expect(mark("D;127;aid=1") == .commandEnd(exitCode: 127))
    #expect(mark("D") == .commandEnd(exitCode: nil))
    #expect(mark("D;") == .commandEnd(exitCode: nil))
    #expect(mark("D;err=1") == .commandEnd(exitCode: nil))
    #expect(mark("D;-1") == .commandEnd(exitCode: nil))
    #expect(mark("B") == .other)
    #expect(mark("") == .other)
}

@Test func quickTerminalHotKeyNeedsTwoModifiersAndDefaultsOnCorruption() throws {
    #expect(QuickTerminalHotKey.default.isValid)
    #expect(QuickTerminalHotKey.default.display == "⌃⌥⌘T")
    #expect(!QuickTerminalHotKey(keyCode: 17, key: "t", modifiers: .command).isValid)
    #expect(!QuickTerminalHotKey(keyCode: 17, key: "t", modifiers: [.shift]).isValid)
    #expect(QuickTerminalHotKey(keyCode: 17, key: "t", modifiers: [.shift, .option]).isValid)
    let name = "LeanTermTests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    #expect(Preferences(defaults: defaults).quickTerminalEnabled)
    #expect(Preferences(defaults: defaults).quickTerminalHidesOnDeactivate)
    defaults.set(try JSONEncoder().encode(QuickTerminalHotKey(keyCode: 17, key: "t", modifiers: .command)), forKey: "quickTerminalHotKey")
    #expect(Preferences(defaults: defaults).quickTerminalHotKey == .default)
}
