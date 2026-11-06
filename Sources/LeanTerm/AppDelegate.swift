import AppKit
import LeanTermCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private(set) var sessions: [UUID: TerminalWindow] = [:]
    private(set) var preferences: Preferences
    private(set) var shortcuts: ShortcutConfiguration
    let defaults: UserDefaults
    private let isolatedDefaultsDomain: String?
    private let isBenchmarkSession: Bool
    private var benchmarkTermination: DispatchSourceSignal?
    private var settingsWindow: SettingsWindow?
    private var shortcutsWindow: ShortcutsWindow?
    private var aboutWindow: AboutWindow?
    private var terminationPending = false
    private var quitApproved = false
    private var lastActiveSessionID: UUID?
    private var smokeCheck: SmokeCheck?
    private var lastSessionQuitQueued = false
    var permitsAutomaticSessionClose: Bool { !terminationPending }
    let metricsMonitor = ProcessMetricsMonitor()
    let activityMonitor = SessionActivityMonitor()
    lazy var notifier = BackgroundNotifier(disabled: isolatedDefaultsDomain != nil)
    lazy var updates = Updates(disabled: isolatedDefaultsDomain != nil)
    var activeSession: TerminalWindow? { sessions.values.first { $0.window === NSApp.keyWindow } }

    override init() {
        let benchmark = CommandLine.arguments.contains("--benchmark-session")
        isBenchmarkSession = benchmark
        if benchmark || CommandLine.arguments.contains("--smoke-test") {
            let name = (benchmark ? "LeanTerm.Bench." : "LeanTerm.Smoke.") + UUID().uuidString
            isolatedDefaultsDomain = name
            defaults = UserDefaults(suiteName: name)!
        } else { defaults = .standard; isolatedDefaultsDomain = nil }
        if CommandLine.arguments.contains("--reset-settings") {
            Preferences.reset(in: defaults)
            WindowPlacement.reset(in: defaults)
            defaults.removeObject(forKey: "SUEnableAutomaticChecks")
            defaults.removeObject(forKey: "SUAutomaticallyUpdate")
        } else if CommandLine.arguments.contains("--reset-window") {
            WindowPlacement.reset(in: defaults)
        }
        preferences = Preferences(defaults: defaults)
        if !preferences.restoreSessions { SessionWorkspace.clear(in: defaults) }
        shortcuts = ShortcutConfiguration(defaults: defaults)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSWindow.allowsAutomaticWindowTabbing = true
        metricsMonitor.onChange = { [weak self] snapshot in
            guard let self, self.preferences.showResourceUsage else { return }
            for session in self.sessions.values where session.isResourceDisplayVisible {
                session.resourceStatus.update(snapshot)
            }
        }
        activityMonitor.sessions = { [weak self] in self.map { Array($0.sessions.values) } ?? [] }
        notifier.openSession = { [weak self] id in
            guard let session = self?.sessions[id] else { return }
            NSApp.activate(ignoringOtherApps: true)
            session.present()
        }
        notifier.setEnabled(preferences.notifyInBackground, onDenied: nil)
        buildMenus()
        applyPreferences()
        if let report = argument("--smoke-test") {
            smokeCheck = SmokeCheck(app: self, report: report)
            smokeCheck?.start()
        } else {
            let directory = argument("--working-directory")
            if isBenchmarkSession { newTerminal(directory: directory) }
            else if let directory, ShellLaunch.localDirectory(from: URL(fileURLWithPath: directory).absoluteString) == nil {
                let alert = NSAlert()
                alert.messageText = "That folder isn’t available"
                alert.informativeText = "Lean Term will open your home folder instead."
                alert.runModal()
                newTerminal()
            } else if directory != nil || !restoreWorkspace() { newTerminal(directory: directory) }
        }
        if isBenchmarkSession { startBenchmarkSession() }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Benchmark sessions open a fixed tab count and quit cleanly on SIGTERM so the isolated defaults suite is removed.
    private func startBenchmarkSession() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        benchmarkTermination = source
        let requested = argument("--benchmark-tabs").flatMap(Int.init) ?? 1
        guard let first = sessions.values.first else { return }
        for _ in 1..<min(max(requested, 1), 8) { newTerminal(tabOf: first) }
        if let window = first.window { window.tabGroup?.selectedWindow = window }
    }

    @discardableResult
    func newTerminal(directory: String? = nil, tabOf: TerminalWindow? = nil, smoke: Bool = false, separateWindow: Bool = false) -> TerminalWindow? {
        guard !terminationPending else { return nil }
        let session = TerminalWindow(preferences: preferences, directory: directory)
        session.app = self
        session.activityMonitor = activityMonitor
        let placement = WindowPlacement(defaults: defaults)
        session.restorePlacement(placement, tabOf: tabOf)
        sessions[session.id] = session
        if let parent = tabOf?.window, let window = session.window {
            parent.addTabbedWindow(window, ordered: .above)
        }
        if separateWindow { session.window?.tabbingMode = .disallowed }
        session.present()
        if separateWindow { session.window?.tabbingMode = .automatic }
        session.start(smoke: smoke || isolatedDefaultsDomain != nil)
        refreshResourceMonitoring()
        return session
    }
    @objc func newWindow(_ sender: Any?) { newTerminal(directory: activeSession?.directoryForNewSession, separateWindow: true) }
    @objc func newTab(_ sender: Any?) {
        let parent = activeSession
        newTerminal(directory: parent?.directoryForNewSession, tabOf: parent)
    }
    @objc func selectTab(_ sender: NSMenuItem) {
        guard let current = activeSession?.window else { return }
        let windows = current.tabGroup?.windows ?? [current]
        let index = sender.tag == 9 ? windows.count - 1 : sender.tag - 1
        guard windows.indices.contains(index) else { return }
        let next = windows[index]
        next.tabGroup?.selectedWindow = next
        next.makeKeyAndOrderFront(nil)
    }
    @objc func renameTab(_ sender: Any?) {
        guard !terminationPending, let session = activeSession, let window = session.window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Tab"
        alert.informativeText = "Leave the name blank to use the folder name."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = session.customName ?? session.folderName
        field.placeholderString = session.folderName
        field.setAccessibilityLabel("Tab name")
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak session] response in
            if response == .alertFirstButtonReturn { session?.setCustomName(field.stringValue) }
        }
        field.selectText(nil)
    }
    @objc func nextTab(_ sender: Any?) { cycleTab(by: 1) }
    @objc func previousTab(_ sender: Any?) { cycleTab(by: -1) }
    private func cycleTab(by offset: Int) {
        guard let current = activeSession?.window, let group = current.tabGroup,
              group.windows.count > 1, let index = group.windows.firstIndex(of: current) else { return }
        let windows = group.windows
        let next = windows[(index + offset + windows.count) % windows.count]
        group.selectedWindow = next
        next.makeKeyAndOrderFront(nil)
    }
    func remove(_ session: TerminalWindow) {
        guard sessions.removeValue(forKey: session.id) != nil else { return }
        notifier.clear(sessionID: session.id)
        unseenActivityChanged()
        sessionDidFinish()
        refreshResourceMonitoring()
        scheduleLastSessionQuit()
    }
    private func scheduleLastSessionQuit() {
        guard preferences.quitAfterLastSession, sessions.isEmpty, !terminationPending, !lastSessionQuitQueued else { return }
        lastSessionQuitQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lastSessionQuitQueued = false
            guard self.preferences.quitAfterLastSession, self.sessions.isEmpty, !self.terminationPending else { return }
            NSApp.terminate(nil)
        }
    }
    func sessionDidFinish() {
        if quitApproved && !sessions.values.contains(where: \.live) {
            quitApproved = false
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }
    func savePlacement(of session: TerminalWindow) {
        guard !terminationPending, !isBenchmarkSession, (activeSession?.id ?? lastActiveSessionID) == session.id, let window = session.window,
              !window.styleMask.contains(.fullScreen), let placement = WindowPlacement(frame: window.frame) else { return }
        placement.save(to: defaults)
    }
    func recordActiveSession(_ session: TerminalWindow) {
        if session.window?.isKeyWindow == true { lastActiveSessionID = session.id }
    }
    func workspaceSnapshot() -> SessionWorkspace {
        let owned = Dictionary(uniqueKeysWithValues: sessions.values.compactMap { session in
            session.window.map { (ObjectIdentifier($0), session) }
        })
        let windows = NSApp.orderedWindows + sessions.values.compactMap(\.window).sorted { $0.windowNumber < $1.windowNumber }
        var visited = Set<UUID>()
        var groups: [SessionWindowGroup] = []
        var activeGroup = 0
        let activeID = activeSession?.id ?? lastActiveSessionID
        for window in windows {
            let members = (window.tabGroup?.windows ?? [window]).compactMap { owned[ObjectIdentifier($0)] }
                .filter { $0.state != .closing && !visited.contains($0.id) }
            guard !members.isEmpty else { continue }
            visited.formUnion(members.map(\.id))
            let selected = members.firstIndex { $0.window === window.tabGroup?.selectedWindow } ?? 0
            if members.contains(where: { $0.id == activeID }) { activeGroup = groups.count }
            groups.append(SessionWindowGroup(tabs: members.map {
                SessionTab(directory: $0.directoryForNewSession, customName: $0.customName)
            }, selectedTab: selected))
        }
        return SessionWorkspace(groups: groups, activeGroup: activeGroup)
    }
    func saveWorkspaceForQuit() {
        guard !isBenchmarkSession else { return }
        guard preferences.restoreSessions else { SessionWorkspace.clear(in: defaults); return }
        let snapshot = workspaceSnapshot()
        if snapshot.groups.isEmpty { SessionWorkspace.clear(in: defaults) }
        else { snapshot.save(to: defaults) }
    }
    @discardableResult
    func restoreWorkspace(smoke: Bool = false) -> Bool {
        guard preferences.restoreSessions, let saved = SessionWorkspace.load(from: defaults) else { return false }
        var selectedWindows: [NSWindow] = []
        for group in saved.groups {
            var restored: [TerminalWindow] = []
            for tab in group.tabs {
                guard let session = newTerminal(directory: tab.directory, tabOf: restored.last, smoke: smoke,
                                                separateWindow: restored.isEmpty) else { continue }
                session.setCustomName(tab.customName)
                restored.append(session)
            }
            if restored.indices.contains(group.selectedTab), let window = restored[group.selectedTab].window {
                window.tabGroup?.selectedWindow = window
                selectedWindows.append(window)
            }
        }
        if selectedWindows.indices.contains(saved.activeGroup) {
            selectedWindows[saved.activeGroup].makeKeyAndOrderFront(nil)
        }
        return !selectedWindows.isEmpty
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newTerminal() }
        return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        smokeCheck?.willTerminate()
        metricsMonitor.setRunning(false)
        activityMonitor.enabled = false
        if let isolatedDefaultsDomain { defaults.removePersistentDomain(forName: isolatedDefaultsDomain) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationPending { return .terminateLater }
        if isBenchmarkSession { return .terminateNow }
        let live = sessions.values.filter(\.live)
        (activeSession ?? lastActiveSessionID.flatMap { sessions[$0] })?.savePlacement()
        guard !live.isEmpty else { saveWorkspaceForQuit(); return .terminateNow }
        terminationPending = true
        refreshActivityMonitoring()
        refreshResourceMonitoring()
        let alert = NSAlert()
        alert.messageText = live.count == 1 ? "Quit this terminal session?" : "Quit \(live.count) terminal sessions?"
        alert.informativeText = "The shells and programs running in these terminals will be stopped."
        alert.addButton(withTitle: "Quit Lean Term")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.last?.keyEquivalent = "\r"
        if let window = NSApp.keyWindow ?? live.first?.window {
            alert.beginSheetModal(for: window) { [weak self] response in self?.finishQuitConfirmation(response) }
        } else { finishQuitConfirmation(alert.runModal()) }
        return .terminateLater
    }
    private func finishQuitConfirmation(_ response: NSApplication.ModalResponse) {
        guard response == .alertFirstButtonReturn else {
            terminationPending = false
            refreshResourceMonitoring()
            refreshActivityMonitoring()
            NSApp.reply(toApplicationShouldTerminate: false)
            return
        }
        quitApproved = true
        saveWorkspaceForQuit()
        for session in Array(sessions.values) where session.live { session.beginShutdown() }
        sessionDidFinish()
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil { settingsWindow = SettingsWindow(app: self) }
        settingsWindow?.refresh()
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }
    @objc func showShortcuts(_ sender: Any?) {
        if shortcutsWindow == nil { shortcutsWindow = ShortcutsWindow(app: self) }
        shortcutsWindow?.refresh()
        shortcutsWindow?.showWindow(nil)
        shortcutsWindow?.window?.makeKeyAndOrderFront(nil)
    }
    func updateShortcuts(_ value: ShortcutConfiguration) {
        shortcuts = value
        value.save(to: defaults)
        buildMenus()
        shortcutsWindow?.refresh()
    }
    func updatePreferences(_ value: Preferences) {
        var value = value
        value.fontSize = Preferences.validFontSize(value.fontSize)
        guard value != preferences else { return }
        preferences = value
        if !value.restoreSessions { SessionWorkspace.clear(in: defaults) }
        preferences.save(to: defaults)
        applyPreferences()
        notifier.setEnabled(preferences.notifyInBackground) { [weak self] in
            guard let self else { return }
            var value = self.preferences
            value.notifyInBackground = false
            self.updatePreferences(value)
            BackgroundNotifier.showDeniedSheet(on: self.settingsWindow?.window)
        }
        unseenActivityChanged()
        settingsWindow?.refresh()
    }
    /// The Dock badge counts tabs with an unseen finished command or bell.
    func unseenActivityChanged() {
        notifier.refreshBadge(count: sessions.values.filter(\.hasUnseenActivity).count)
    }
    private func applyPreferences() {
        switch preferences.appearance {
        case .system:
            if NSApp.appearance != nil { NSApp.appearance = nil }
        case .light:
            if NSApp.appearance?.name != .aqua { NSApp.appearance = NSAppearance(named: .aqua) }
        case .dark:
            if NSApp.appearance?.name != .darkAqua { NSApp.appearance = NSAppearance(named: .darkAqua) }
        }
        for session in sessions.values { session.apply(preferences) }
        refreshResourceMonitoring()
        refreshActivityMonitoring()
    }
    private func refreshActivityMonitoring() {
        // Directory labels also follow PTY activity, without adding an idle timer.
        activityMonitor.enabled = !terminationPending
    }
    func refreshResourceMonitoring() {
        metricsMonitor.setRunning(preferences.showResourceUsage && !terminationPending && sessions.values.contains { $0.isResourceDisplayVisible })
        for session in sessions.values where preferences.showResourceUsage && session.isResourceDisplayVisible {
            session.resourceStatus.update(metricsMonitor.snapshot)
        }
    }
    @objc private func largerFont(_ sender: Any?) { changeFont(by: 1) }
    @objc private func smallerFont(_ sender: Any?) { changeFont(by: -1) }
    @objc private func resetFont(_ sender: Any?) {
        var value = preferences; value.fontSize = 13; updatePreferences(value)
    }
    private func changeFont(by delta: Double) {
        var value = preferences; value.fontSize += delta; updatePreferences(value)
    }
    @objc func clearScreenAndScrollback(_ sender: Any?) { activeSession?.clearScreenAndScrollback() }
    @objc private func about(_ sender: Any?) {
        if aboutWindow == nil { aboutWindow = AboutWindow() }
        aboutWindow?.showWindow(nil)
        aboutWindow?.window?.makeKeyAndOrderFront(nil)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if [#selector(nextTab), #selector(previousTab), #selector(selectTab), #selector(renameTab)].contains(menuItem.action) {
            return activeSession != nil && !terminationPending
        }
        if [#selector(clearScreenAndScrollback), #selector(largerFont), #selector(smallerFont), #selector(resetFont)].contains(menuItem.action) {
            return activeSession != nil
        }
        return !terminationPending
    }

    private func buildMenus() {
        let menu = NSMenu()
        func group(_ title: String) -> NSMenu {
            let item = NSMenuItem(); let child = NSMenu(title: title)
            item.submenu = child; menu.addItem(item); return child
        }
        func add(_ menu: NSMenu, _ title: String, _ selector: Selector, _ key: String = "", target: AnyObject? = nil,
                 modifiers: NSEvent.ModifierFlags = [.command], tag: Int = 0, shortcut: ShortcutAction? = nil) {
            let binding = shortcut.flatMap { shortcuts.binding(for: $0) }
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: shortcut == nil ? key : (binding?.key ?? ""))
            item.target = target; item.keyEquivalentModifierMask = shortcut == nil ? modifiers : (binding?.modifiers.eventFlags ?? .command)
            item.tag = tag
            if let shortcut { item.representedObject = "shortcut:" + shortcut.rawValue }
            menu.addItem(item)
        }
        let application = group("Lean Term")
        add(application, "About Lean Term", #selector(about), target: self, shortcut: .about)
        if updates.available {
            add(application, "Check for Updates…", #selector(Updates.checkForUpdates(_:)), target: updates, shortcut: .updates)
        }
        application.addItem(.separator())
        add(application, "Settings…", #selector(showSettings), target: self, shortcut: .settings)
        application.addItem(.separator())
        add(application, "Hide Lean Term", #selector(NSApplication.hide(_:)), "h")
        add(application, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", modifiers: [.command, .option])
        add(application, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        application.addItem(.separator())
        add(application, "Quit Lean Term", #selector(NSApplication.terminate(_:)), shortcut: .quit)
        let file = group("File")
        add(file, "New Window", #selector(newWindow), target: self, shortcut: .newWindow)
        add(file, "New Tab", #selector(newTab), target: self, shortcut: .newTab)
        file.addItem(.separator())
        add(file, "Close", #selector(NSWindow.performClose(_:)), shortcut: .close)
        let edit = group("Edit")
        add(edit, "Undo", Selector(("undo:")), "z")
        add(edit, "Redo", Selector(("redo:")), "z", modifiers: [.command, .shift])
        edit.addItem(.separator())
        add(edit, "Cut", #selector(NSText.cut(_:)), "x")
        add(edit, "Copy", #selector(NSText.copy(_:)), "c")
        add(edit, "Paste", #selector(NSText.paste(_:)), "v")
        add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        add(edit, "Find…", #selector(NSResponder.performTextFinderAction(_:)), tag: NSTextFinder.Action.showFindInterface.rawValue, shortcut: .find)
        add(edit, "Find Next", #selector(NSResponder.performTextFinderAction(_:)), tag: NSTextFinder.Action.nextMatch.rawValue, shortcut: .findNext)
        add(edit, "Find Previous", #selector(NSResponder.performTextFinderAction(_:)), tag: NSTextFinder.Action.previousMatch.rawValue, shortcut: .findPrevious)
        let terminal = group("Terminal")
        add(terminal, "Clear Screen and Scrollback", #selector(clearScreenAndScrollback), target: self, shortcut: .clearScrollback)
        terminal.addItem(.separator())
        add(terminal, "Larger Text", #selector(largerFont), target: self, shortcut: .largerText)
        add(terminal, "Smaller Text", #selector(smallerFont), target: self, shortcut: .smallerText)
        add(terminal, "Default Text Size", #selector(resetFont), target: self, shortcut: .defaultText)
        let windows = group("Window")
        add(windows, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(windows, "Zoom", #selector(NSWindow.performZoom(_:)))
        windows.addItem(.separator())
        add(windows, "Next Tab", #selector(nextTab), target: self, shortcut: .nextTab)
        add(windows, "Previous Tab", #selector(previousTab), target: self, shortcut: .previousTab)
        add(windows, "Rename Tab…", #selector(renameTab), target: self, shortcut: .renameTab)
        windows.addItem(.separator())
        let numbered: [ShortcutAction] = [.tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8, .lastTab]
        for (index, action) in numbered.enumerated() {
            add(windows, action.title, #selector(selectTab(_:)), target: self, tag: index + 1, shortcut: action)
        }
        windows.addItem(.separator())
        for (action, selector) in [(ShortcutAction.previousTab, #selector(previousTab)), (.nextTab, #selector(nextTab))] {
            for binding in action.aliases {
                let item = NSMenuItem(title: action.title, action: selector, keyEquivalent: binding.key)
                item.target = self; item.keyEquivalentModifierMask = binding.modifiers.eventFlags
                item.isHidden = true; item.allowsKeyEquivalentWhenHidden = true
                item.representedObject = "shortcut:" + action.rawValue
                windows.addItem(item)
            }
        }
        add(windows, "Show All Tabs", #selector(NSWindow.toggleTabOverview(_:)))
        NSApp.windowsMenu = windows
        let help = group("Help")
        add(help, "Keyboard Shortcuts…", #selector(showShortcuts), target: self, shortcut: .shortcuts)
        NSApp.helpMenu = help
        NSApp.mainMenu = menu
    }
    private func argument(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: name), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }
}
