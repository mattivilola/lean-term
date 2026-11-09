import AppKit
import LeanTermCore

/// An opt-in, bounded native integration check. Normal sessions never run this task.
@MainActor
final class SmokeCheck {
    private weak var app: AppDelegate?
    private let report: URL
    private var checks: [String] = []
    private struct Failure: Error { let message: String }
    private enum ExitPolicy: String {
        case closeQuit = "close-quit"
        case closeKeep = "close-keep"
        case keepQuit = "keep-quit"
        case keepKeep = "keep-keep"

        var closesOnShellExit: Bool { self == .closeQuit || self == .closeKeep }
        var quitsAfterLastSession: Bool { self == .closeQuit || self == .keepQuit }
    }
    private enum PolicyStage {
        case automaticCloseThenQuit
        case automaticCloseKeepApp
        case waitingForRetainedExit
        case manualCloseThenQuit
        case manualCloseKeepApp
        case checkingKeepAlive
    }

    private let hasPolicyArgument: Bool
    private let requestedPolicy: String?
    private var policy: ExitPolicy?
    private var policyStage: PolicyStage?
    private var policySession: TerminalWindow?
    private var retainedExitVerified = false
    private var explicitWindowCloseRequested = false
    private var reportFinalized = false
    private var reportPassed: Bool?

    init(app: AppDelegate, report: String) {
        self.app = app; self.report = URL(fileURLWithPath: report)
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--smoke-policy") {
            hasPolicyArgument = true
            let nextIndex = index + 1
            requestedPolicy = nextIndex < arguments.count && !arguments[nextIndex].hasPrefix("--")
                ? arguments[nextIndex] : nil
        } else {
            hasPolicyArgument = false
            requestedPolicy = nil
        }
    }

    func start() {
        Task { @MainActor in
            do {
                if requestedPolicy == "quit-cancel" {
                    try await runQuitCancellation()
                } else if requestedPolicy == "resource-footer" {
                    try await runResourceFooter()
                    finish(passed: true)
                } else if hasPolicyArgument {
                    guard let requestedPolicy, let policy = ExitPolicy(rawValue: requestedPolicy) else {
                        throw Failure(message: "Invalid --smoke-policy value: \(requestedPolicy ?? "missing")")
                    }
                    try await run(policy: policy)
                } else {
                    try await run()
                    finish(passed: true)
                }
            } catch {
                await failAndCleanUp(error)
            }
        }
    }

    private func run() async throws {
        guard let app, let first = app.newTerminal(smoke: true) else { throw Failure(message: "No native session") }
        try expect(!first.terminal.isUsingMetalRenderer, "CoreGraphics selected")
        try expect(app.preferences.fontName == "SF Mono" && first.terminal.font.fontName == NSFont.monospacedSystemFont(ofSize: 13, weight: .regular).fontName,
                   "SF Mono default resolves through the native system font API")
        first.terminal.send(txt: "printf '\\033[32mLEAN_TERM_RUNTIME_%s\\033[0m · café 日本語 👋\\n' 'OK'\r")
        try await wait { first.terminal.findNext("LEAN_TERM_RUNTIME_OK") }
        try expect(first.terminal.findNext("café 日本語"), "PTY echo, ANSI and Unicode output searchable")
        let before = first.terminal.terminalDimensions
        first.window?.setContentSize(NSSize(width: 780, height: 480))
        first.window?.contentView?.layoutSubtreeIfNeeded()
        try expect(first.terminal.terminalDimensions.cols != before.cols, "Native resize reaches the terminal")
        for mode in Preferences.Appearance.allCases {
            for palette in Preferences.Palette.allCases {
                var value = app.preferences
                value.appearance = mode; value.palette = palette; value.fontSize = 15
                app.updatePreferences(value)
                try expect(first.terminal.font.pointSize == 15 && !first.terminal.isUsingMetalRenderer,
                           "\(mode.title)/\(palette.title) applies without changing renderer")
            }
        }
        let find = NSMenuItem(); find.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        first.terminal.performFindPanelAction(find)
        let hide = NSMenuItem(); hide.tag = NSTextFinder.Action.hideFindInterface.rawValue
        first.terminal.performTextFinderAction(hide)
        first.terminal.send(txt: "for n in {1..120}; do printf 'LT_OLD_ROW_%s\\n' $n; done; printf 'LT_VISIBLE_%s\\n' 'NOW'\r")
        try await wait { first.terminal.findNext("LT_VISIBLE_NOW") }
        try expect(first.terminal.findNext("LT_OLD_ROW_1"), "History marker is searchable before clear")
        first.terminal.selectAll()
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: first.window!.windowNumber,
            context: nil, characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40)!
        try expect(NSApp.mainMenu?.performKeyEquivalent(with: key) == true, "Cmd-K invokes the configured clear action")
        try await wait { !first.terminal.findNext("LT_VISIBLE_NOW") && !first.terminal.findNext("LT_OLD_ROW_1") }
        try expect(first.terminal.visibleRowsText(0..<first.terminal.terminalDimensions.rows).allSatisfy {
            $0.trimmingCharacters(in: .whitespaces).isEmpty
        } && !first.terminal.selectionActive, "Cmd-K clears the screen, history, search results and selection")
        try expect(first.scrollbackStatus.stringValue == "Scrollback 0 / 10k (0%)",
                   "Cmd-K resets the footer’s scrollback count")

        first.terminal.feed(text: String(repeating: "test row\r\n", count: 1_200))
        try await wait { !first.scrollbackStatus.stringValue.hasSuffix("(0%)") }
        var history = app.preferences
        history.scrollbackLines = 1_000
        app.updatePreferences(history)
        let full = "Scrollback \(1_000.formatted()) / 1k (100%)"
        try expect(first.scrollbackStatus.stringValue == full, "Reducing the history limit updates the footer and trims the buffer")
        first.terminal.feed(text: "\u{1B}[?1049h\u{1B}[?2004hALT_CLEAR_TARGET")
        try await wait { first.terminal.findNext("ALT_CLEAR_TARGET") }
        try expect(first.scrollbackStatus.stringValue == full, "The footer still counts retained history on the alternate screen")
        first.focusedPane.clearScreenAndScrollback()
        try await wait { !first.terminal.findNext("ALT_CLEAR_TARGET") }
        let modes = first.terminal.terminalInputStateSnapshot()
        try expect(modes?.isAlternateBuffer == true && modes?.bracketedPasteMode == true,
                   "Clearing an alternate screen preserves terminal input modes")
        try expect(first.scrollbackStatus.stringValue == "Scrollback 0 / 1k (0%)",
                   "Clearing scrollback from the alternate screen resets the footer")
        first.terminal.feed(text: "\u{1B}[?1049l")
        first.terminal.feed(text: String(repeating: "test row\r\n", count: 1_200))
        try await wait { first.scrollbackStatus.stringValue == full }
        first.terminal.send(txt: "printf '\\033[3J'\r")
        try await wait { first.scrollbackStatus.stringValue.hasSuffix("(0%)") }
        try expect(true, "Shell-driven scrollback erase refreshes the footer")
        first.terminal.send(txt: "printf 'LT_AFTER_CLEAR_%s\\n' 'OK'\r")
        try await wait { first.terminal.findNext("LT_AFTER_CLEAR_OK") }
        try expect(true, "Shell remains usable after local clear")
        try await wait { app.metricsMonitor.snapshot.cpuPercent != nil }
        try expect(app.metricsMonitor.snapshot.physicalFootprintBytes != nil,
                   "Visible status bar samples total CPU and physical footprint")
        var disabled = app.preferences; disabled.showResourceUsage = false; app.updatePreferences(disabled)
        try expect(app.metricsMonitor.snapshot.status == .paused && first.resourceStatus.isHidden,
                   "Disabling resource graphs stops the shared sampler")
        disabled.showResourceUsage = true; app.updatePreferences(disabled)
        first.terminal.send(txt: "exit\r")
        try await wait { first.state == .exited }
        try expect(first.terminationCount == 1, "Shell exit callback delivered once after reap")
        first.window?.setContentSize(NSSize(width: 480, height: 320))
        first.window?.contentView?.layoutSubtreeIfNeeded()
        try expect(!first.resourceStatus.showsSparklines && first.resourceStatus.frame.width == first.resourceStatus.intrinsicContentSize.width &&
                   first.resourceStatus.frame.minX >= 0 &&
                   first.resourceStatus.frame.maxX <= (first.resourceStatus.superview?.bounds.width ?? 0) + 0.1,
                   "Resource labels fit a minimum-width ended session")
        first.window?.close()

        // Keep one live anchor so auto-close can be checked without terminating the smoke host.
        guard let anchor = app.newTerminal(smoke: true) else { throw Failure(message: "No exit-policy anchor") }
        var closing = app.preferences; closing.closeTabOnShellExit = true; app.updatePreferences(closing)
        guard let exits = app.newTerminal(tabOf: anchor, smoke: true) else { throw Failure(message: "No auto-close session") }
        exits.terminal.send(txt: "exit\r")
        try await wait { app.sessions[exits.id] == nil }
        try expect(exits.terminationCount == 1 && app.sessions[anchor.id] != nil,
                   "Shell exit closes only its tab when configured")
        closing.closeTabOnShellExit = false; app.updatePreferences(closing)
        anchor.beginShutdown()
        try await wait { app.sessions[anchor.id] == nil }

        let savedFrame = WindowPlacement(defaults: app.defaults)?.fitted(to: NSScreen.screens.map(\.visibleFrame))
        guard let resistant = app.newTerminal(smoke: true) else { throw Failure(message: "No resistant session") }
        try expect(savedFrame != nil && resistant.window?.frame == savedFrame,
                   "New window restores the saved position and size")
        resistant.terminal.send(txt: "trap '' HUP TERM; printf 'LEAN_TERM_RESIST_%s\\n' 'READY'; while true; do sleep 1; done\r")
        try await wait { resistant.terminal.findNext("LEAN_TERM_RESIST_READY") }
        resistant.beginShutdown()
        try await wait { resistant.state == .exited }
        try expect(resistant.terminationCount == 1, "HUP/TERM-resistant child force-closes through the safe reaper")

        // Cancelling Quit can restore another application’s activation. Reassert
        // the interactive foreground context before testing tab-key navigation.
        NSApp.activate(ignoringOtherApps: true)
        guard let a = app.newTerminal(smoke: true), let b = app.newTerminal(tabOf: a, smoke: true) else {
            throw Failure(message: "No tab group")
        }
        try expect(a.window?.tabGroup === b.window?.tabGroup && a.window?.tabbedWindows?.count == 2,
                   "Two native tabs own independent sessions")
        try await wait { app.activeSession === b }
        app.nextTab(nil)
        try await wait { app.activeSession === a }
        app.previousTab(nil)
        try await wait { app.activeSession === b }
        try expect(true, "Tab navigation wraps forward and backward")
        guard let c = app.newTerminal(smoke: true) else { throw Failure(message: "No independent window") }
        a.window?.setFrame(CGRect(x: 50, y: 80, width: 700, height: 480), display: true)
        a.window?.makeKeyAndOrderFront(nil)
        c.window?.setFrame(CGRect(x: 100, y: 140, width: 820, height: 540), display: true)
        c.window?.makeKeyAndOrderFront(nil)
        try await wait { app.activeSession === c }
        c.savePlacement()
        let current = WindowPlacement(defaults: app.defaults)
        a.savePlacement() // A late callback from a background window must not win.
        try expect(current?.frame == c.window?.frame && WindowPlacement(defaults: app.defaults) == current,
                   "Only the last active window updates saved placement")
        a.terminal.send(txt: "cd /private/tmp; printf 'LT_DIRECTORY_%s\\n' 'READY'\r")
        try await wait { a.terminal.findNext("LT_DIRECTORY_READY") }
        try expect(a.directoryForNewSession == "/private/tmp" && a.window?.tab.title == "tmp",
                   "Hook-free shell cwd produces a short folder label")
        a.setCustomName("Backend")
        try expect(a.window?.tab.title == "Backend", "Custom tab name overrides the automatic folder label")
        a.setCustomName(" ")
        try expect(a.window?.tab.title == "tmp", "Blank tab name restores the automatic label")
        a.setCustomName("Backend")
        a.window?.makeKeyAndOrderFront(nil)
        try await wait { app.activeSession === a }
        let oldIDs = Set(app.sessions.keys)
        app.newTab(nil)
        guard let inherited = app.sessions.values.first(where: { !oldIDs.contains($0.id) }) else {
            throw Failure(message: "No inherited tab")
        }
        try expect(inherited.currentDirectory == "/private/tmp", "New Tab inherits the current shell folder")
        try await wait { app.activeSession === inherited }
        let one = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: inherited.window!.windowNumber,
            context: nil, characters: "1", charactersIgnoringModifiers: "1", isARepeat: false, keyCode: 18)!
        try expect(NSApp.mainMenu?.performKeyEquivalent(with: one) == true, "Cmd-1 invokes native tab selection")
        try await wait { app.activeSession === a }
        let last = NSMenuItem(); last.tag = 9
        app.selectTab(last)
        try await wait { app.activeSession?.window === a.window?.tabGroup?.windows.last }
        try expect(true, "Cmd-9 action selects the last tab")
        c.window?.makeKeyAndOrderFront(nil)
        try await wait { app.activeSession === c }
        var restoring = app.preferences; restoring.restoreSessions = true
        app.updatePreferences(restoring)
        let snapshot = app.workspaceSnapshot()
        app.saveWorkspaceForQuit()
        try expect(snapshot.groups.count == 2 && snapshot.groups.flatMap(\.tabs).count == 4 &&
                   SessionWorkspace.load(from: app.defaults) == snapshot,
                   "Workspace snapshot preserves window groups, tab order, selection, names and folders")
        for session in Array(app.sessions.values) { session.beginShutdown() }
        try await wait { app.sessions.isEmpty }
        try expect(a.terminationCount == 1 && b.terminationCount == 1 && c.terminationCount == 1,
                   "Multiple sessions close and release without duplicate callbacks")
        try expect(app.restoreWorkspace(smoke: true), "Saved workspace reopens fresh native terminal sessions")
        try await wait { app.sessions.count == 4 }
        try expect(app.workspaceSnapshot() == snapshot, "Restored native groups retain names, folders, order and selection")
        for session in Array(app.sessions.values) { session.beginShutdown() }
        try await wait { app.sessions.isEmpty }
    }

    private func runResourceFooter() async throws {
        guard let app, let session = app.newTerminal(smoke: true), let window = session.window,
              let content = window.contentView else { throw Failure(message: "No native session") }
        window.setContentSize(NSSize(width: 780, height: 480))
        let metrics = app.metricsMonitor
        let idlePane = session.focusedPane
        try await wait { metrics.snapshot.status == .available || metrics.snapshot.status == .unavailable }
        try expect(metrics.snapshot.status == .available, "Local process sampler can read the process tree")
        try await wait { metrics.paneUsage[idlePane.id]?.cpuPercent != nil }

        session.split(.horizontal)
        let busyPane = session.focusedPane
        try expect(busyPane !== idlePane, "Split focuses the new pane")
        try await wait { metrics.paneUsage[busyPane.id]?.cpuPercent != nil }
        busyPane.terminal.send(txt: "\u{15}/bin/zsh -fc 'while (( SECONDS < 5 )); do :; done'\r")
        try await wait {
            let usage = metrics.paneUsage
            return (usage[busyPane.id]?.cpuPercent ?? 0) > 35 && (usage[idlePane.id]?.cpuPercent ?? 100) < 35
        }
        let busy = metrics.paneUsage[busyPane.id]
        let idle = metrics.paneUsage[idlePane.id]
        try expect((metrics.snapshot.cpuPercent ?? 0) >= (busy?.cpuPercent ?? 0) &&
                   (metrics.snapshot.physicalFootprintBytes ?? 0) > (busy?.physicalFootprintBytes ?? 0) + (idle?.physicalFootprintBytes ?? 0),
                   "Focused pane includes the local child process and total includes both panes and the app")

        let busyDescription = session.resourceStatus.toolTip
        window.makeFirstResponder(idlePane.terminal)
        try expect(session.focusedPane === idlePane && session.resourceStatus.toolTip != busyDescription,
                   "Footer switches to the newly focused pane immediately")
        content.layoutSubtreeIfNeeded()
        let scrollback = session.scrollbackStatus.convert(session.scrollbackStatus.bounds, to: content)
        let resources = session.resourceStatus.convert(session.resourceStatus.bounds, to: content)
        try expect(!session.scrollbackStatus.isHidden && scrollback.maxX < resources.minX,
                   "Scrollback is visible to the left of the resource metrics")
        window.setContentSize(NSSize(width: 480, height: 320))
        content.layoutSubtreeIfNeeded()
        let compact = session.resourceStatus.convert(session.resourceStatus.bounds, to: content)
        try expect(!session.resourceStatus.showsSparklines && compact.width == session.resourceStatus.intrinsicContentSize.width &&
                   compact.minX >= 0 && compact.maxX <= content.bounds.width,
                   "Resource labels fit a minimum-width terminal window")
        session.beginShutdown()
        try await wait { app.sessions.isEmpty }
    }

    private func expect(_ value: Bool, _ description: String) throws {
        guard value else { throw Failure(message: description) }
        checks.append(description)
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Failure(message: "Timed out waiting for native session state")
    }
    private func runQuitCancellation() async throws {
        guard let app else { throw Failure(message: "No app for cancellation check") }
        var value = app.preferences
        value.closeTabOnShellExit = true; value.quitAfterLastSession = true
        value.showResourceUsage = false
        app.updatePreferences(value)
        guard let first = app.newTerminal(smoke: true) else { throw Failure(message: "No cancellation session") }
        let quitEvent = Timer(timeInterval: 0.05, repeats: false) { _ in
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
        RunLoop.main.add(quitEvent, forMode: .common)
        try await wait { first.window?.attachedSheet != nil }
        first.terminal.send(txt: "exit\r")
        try await wait { first.state == .exited }
        try expect(first.terminationCount == 1 && app.sessions[first.id] != nil,
                   "A shell finishing during quit preserves its confirmation window")
        guard let sheet = first.window?.attachedSheet else { throw Failure(message: "Quit sheet disappeared") }
        first.window?.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        try await wait { first.window?.attachedSheet == nil && app.permitsAutomaticSessionClose }
        try await Task.sleep(for: .milliseconds(350))
        try expect(app.sessions[first.id] != nil, "Cancel quit retains finished output instead of quitting again")
        value.closeTabOnShellExit = false; value.quitAfterLastSession = false
        app.updatePreferences(value)
        first.window?.close()
        finish(passed: true)
    }

    private func run(policy: ExitPolicy) async throws {
        guard let app else { throw Failure(message: "No app for exit policy") }
        self.policy = policy
        var value = app.preferences
        value.closeTabOnShellExit = policy.closesOnShellExit
        value.quitAfterLastSession = policy.quitsAfterLastSession
        value.showResourceUsage = false
        app.updatePreferences(value)
        guard let session = app.newTerminal(smoke: true) else { throw Failure(message: "No policy session") }
        policySession = session
        policyStage = policy.closesOnShellExit
            ? (policy.quitsAfterLastSession ? .automaticCloseThenQuit : .automaticCloseKeepApp)
            : .waitingForRetainedExit
        session.terminal.send(txt: "exit\r")
        if policy.closesOnShellExit {
            if policy.quitsAfterLastSession {
                try await wait { self.reportFinalized }
                return
            }
            try await wait { app.sessions[session.id] == nil }
            try expect(session.terminationCount == 1, "Natural shell exit closed its tab once")
        } else {
            try await wait { session.state == .exited }
            try await Task.sleep(for: .milliseconds(350))
            try expect(app.sessions[session.id] != nil && session.window?.isVisible == true,
                       "Keep-open policy retains final output after shell exit")
            retainedExitVerified = true
            explicitWindowCloseRequested = true
            policyStage = policy.quitsAfterLastSession ? .manualCloseThenQuit : .manualCloseKeepApp
            session.window?.close()
            if policy.quitsAfterLastSession {
                try await wait { self.reportFinalized }
                return
            }
            try await wait { app.sessions[session.id] == nil }
        }
        policyStage = .checkingKeepAlive
        try await Task.sleep(for: .milliseconds(350))
        try expect(app.sessions.isEmpty && session.terminationCount == 1,
                   "Quit-last disabled keeps the app alive after the last terminal closes")
        finish(passed: true)
    }

    /// Called only when the real NSApplication termination path is completing.
    func willTerminate() {
        guard hasPolicyArgument, !reportFinalized else { return }
        let stageAllowsQuit = policyStage == .automaticCloseThenQuit || policyStage == .manualCloseThenQuit
        let retainedCaseCorrect = policy?.closesOnShellExit == true || (retainedExitVerified && explicitWindowCloseRequested)
        let passed = policy?.quitsAfterLastSession == true && stageAllowsQuit && retainedCaseCorrect &&
            app?.sessions.isEmpty == true && policySession?.state == .exited && policySession?.terminationCount == 1
        checks.append(passed ? "Last terminal closure naturally terminated NSApplication" : "FAILED: unexpected app termination during exit-policy check")
        writeReport(passed: passed, automaticTerminationObserved: true)
    }

    private func failAndCleanUp(_ error: Error) async {
        guard !reportFinalized else { return }
        checks.append("FAILED: \(error)")
        writeReport(passed: false)
        if let app {
            var value = app.preferences
            value.quitAfterLastSession = false; value.closeTabOnShellExit = false
            app.updatePreferences(value)
            for session in Array(app.sessions.values) where session.live { session.beginShutdown() }
            try? await wait { !app.sessions.values.contains(where: \.live) }
            for session in Array(app.sessions.values) { session.window?.close() }
        }
        NSApp.terminate(nil)
    }

    private func finish(passed: Bool) {
        guard !reportFinalized else { return }
        writeReport(passed: passed)
        NSApp.terminate(nil)
    }
    private func writeReport(passed: Bool, automaticTerminationObserved: Bool = false) {
        guard !reportFinalized else { return }
        reportFinalized = true; reportPassed = passed
        var result: [String: Any] = ["passed": passed, "checks": checks, "renderer": "CoreGraphics",
                                   "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
                                   "sessionCount": app?.sessions.count ?? -1]
        if !passed, let app {
            result["sessionDiagnostics"] = app.sessions.values.map { session in
                ["state": String(describing: session.state),
                 "lastVisibleRows": Array(session.terminal.visibleRowsText(0..<session.terminal.terminalDimensions.rows).suffix(12))] as [String: Any]
            }
        }
        if requestedPolicy == "quit-cancel" { result["scenario"] = "quit-cancel" }
        if let policy {
            result["exitPolicy"] = policy.rawValue
            result["automaticTerminationObserved"] = automaticTerminationObserved
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: report, options: .atomic)
        } catch { fputs("Could not write native smoke report: \(error)\n", stderr) }
    }
}
