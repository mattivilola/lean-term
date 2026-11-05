import AppKit
import LeanTermCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private(set) var sessions: [UUID: TerminalWindow] = [:]
    private(set) var preferences: Preferences
    let defaults: UserDefaults
    private let smokeDefaultsDomain: String?
    private var settingsWindow: SettingsWindow?
    private var terminationPending = false
    private var quitApproved = false
    private var lastActiveSessionID: UUID?
    private var smokeCheck: SmokeCheck?
    var activeSession: TerminalWindow? { sessions.values.first { $0.window === NSApp.keyWindow } }

    override init() {
        if CommandLine.arguments.contains("--smoke-test") {
            let name = "LeanTerm.Smoke." + UUID().uuidString
            smokeDefaultsDomain = name
            defaults = UserDefaults(suiteName: name)!
        } else { defaults = .standard; smokeDefaultsDomain = nil }
        if CommandLine.arguments.contains("--reset-settings") {
            Preferences.reset(in: defaults)
            WindowPlacement.reset(in: defaults)
        } else if CommandLine.arguments.contains("--reset-window") {
            WindowPlacement.reset(in: defaults)
        }
        preferences = Preferences(defaults: defaults)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSWindow.allowsAutomaticWindowTabbing = true
        buildMenus()
        applyPreferences()
        if let report = argument("--smoke-test") {
            smokeCheck = SmokeCheck(app: self, report: report)
            smokeCheck?.start()
        } else {
            let directory = argument("--working-directory")
            if let directory, ShellLaunch.localDirectory(from: URL(fileURLWithPath: directory).absoluteString) == nil {
                let alert = NSAlert()
                alert.messageText = "That folder isn’t available"
                alert.informativeText = "Lean Term will open your home folder instead."
                alert.runModal()
                newTerminal()
            } else { newTerminal(directory: directory) }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @discardableResult
    func newTerminal(directory: String? = nil, tabOf: TerminalWindow? = nil, smoke: Bool = false) -> TerminalWindow? {
        guard !terminationPending else { return nil }
        let session = TerminalWindow(preferences: preferences, directory: directory, smoke: smoke)
        session.app = self
        let placement = WindowPlacement(defaults: defaults)
        session.restorePlacement(placement, tabOf: tabOf)
        sessions[session.id] = session
        if let parent = tabOf?.window, let window = session.window {
            parent.addTabbedWindow(window, ordered: .above)
        }
        session.present()
        return session
    }
    @objc func newWindow(_ sender: Any?) { newTerminal(directory: activeSession?.currentDirectory) }
    @objc func newTab(_ sender: Any?) {
        let parent = activeSession
        newTerminal(directory: parent?.currentDirectory, tabOf: parent)
    }
    func remove(_ session: TerminalWindow) {
        sessions.removeValue(forKey: session.id)
        sessionDidFinish()
    }
    func sessionDidFinish() {
        if quitApproved && !sessions.values.contains(where: \.live) {
            quitApproved = false
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }
    func savePlacement(of session: TerminalWindow) {
        guard !terminationPending, (activeSession?.id ?? lastActiveSessionID) == session.id, let window = session.window,
              !window.styleMask.contains(.fullScreen), let placement = WindowPlacement(frame: window.frame) else { return }
        placement.save(to: defaults)
    }
    func recordActiveSession(_ session: TerminalWindow) {
        if session.window?.isKeyWindow == true { lastActiveSessionID = session.id }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newTerminal() }
        return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let smokeDefaultsDomain { defaults.removePersistentDomain(forName: smokeDefaultsDomain) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationPending { return .terminateLater }
        let live = sessions.values.filter(\.live)
        (activeSession ?? lastActiveSessionID.flatMap { sessions[$0] })?.savePlacement()
        guard !live.isEmpty else { return .terminateNow }
        terminationPending = true
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
            NSApp.reply(toApplicationShouldTerminate: false)
            return
        }
        quitApproved = true
        for session in Array(sessions.values) where session.live { session.beginShutdown() }
        sessionDidFinish()
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil { settingsWindow = SettingsWindow(app: self) }
        settingsWindow?.refresh()
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }
    func updatePreferences(_ value: Preferences) {
        var value = value
        value.fontSize = Preferences.validFontSize(value.fontSize)
        guard value != preferences else { return }
        preferences = value
        preferences.save(to: defaults)
        applyPreferences()
        settingsWindow?.refresh()
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
    }
    @objc private func largerFont(_ sender: Any?) { changeFont(by: 1) }
    @objc private func smallerFont(_ sender: Any?) { changeFont(by: -1) }
    @objc private func resetFont(_ sender: Any?) {
        var value = preferences; value.fontSize = 13; updatePreferences(value)
    }
    private func changeFont(by delta: Double) {
        var value = preferences; value.fontSize += delta; updatePreferences(value)
    }
    @objc private func clearScrollback(_ sender: Any?) { activeSession?.terminal.clearScrollback() }
    @objc private func about(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Lean Term", .applicationVersion: "0.1.0 · Development",
            .credits: NSAttributedString(string: "A little less terminal. A lot more focus.\nNative macOS · Free and open source\nleanterm.com")
        ])
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if [#selector(clearScrollback), #selector(largerFont), #selector(smallerFont), #selector(resetFont)].contains(menuItem.action) {
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
                 modifiers: NSEvent.ModifierFlags = [.command], tag: Int = 0) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.target = target; item.keyEquivalentModifierMask = modifiers; item.tag = tag; menu.addItem(item)
        }
        let application = group("Lean Term")
        add(application, "About Lean Term", #selector(about), target: self)
        application.addItem(.separator())
        add(application, "Settings…", #selector(showSettings), ",", target: self)
        application.addItem(.separator())
        add(application, "Hide Lean Term", #selector(NSApplication.hide(_:)), "h")
        add(application, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", modifiers: [.command, .option])
        add(application, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        application.addItem(.separator())
        add(application, "Quit Lean Term", #selector(NSApplication.terminate(_:)), "q")
        let file = group("File")
        add(file, "New Window", #selector(newWindow), "n", target: self)
        add(file, "New Tab", #selector(newTab), "t", target: self)
        file.addItem(.separator())
        add(file, "Close", #selector(NSWindow.performClose(_:)), "w")
        let edit = group("Edit")
        add(edit, "Undo", Selector(("undo:")), "z")
        add(edit, "Redo", Selector(("redo:")), "z", modifiers: [.command, .shift])
        edit.addItem(.separator())
        add(edit, "Cut", #selector(NSText.cut(_:)), "x")
        add(edit, "Copy", #selector(NSText.copy(_:)), "c")
        add(edit, "Paste", #selector(NSText.paste(_:)), "v")
        add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        add(edit, "Find…", #selector(NSResponder.performTextFinderAction(_:)), "f", tag: NSTextFinder.Action.showFindInterface.rawValue)
        add(edit, "Find Next", #selector(NSResponder.performTextFinderAction(_:)), "g", tag: NSTextFinder.Action.nextMatch.rawValue)
        add(edit, "Find Previous", #selector(NSResponder.performTextFinderAction(_:)), "g", modifiers: [.command, .shift], tag: NSTextFinder.Action.previousMatch.rawValue)
        let terminal = group("Terminal")
        add(terminal, "Clear Scrollback", #selector(clearScrollback), "k", target: self)
        terminal.addItem(.separator())
        add(terminal, "Larger Text", #selector(largerFont), "+", target: self)
        add(terminal, "Smaller Text", #selector(smallerFont), "-", target: self)
        add(terminal, "Default Text Size", #selector(resetFont), "0", target: self)
        let windows = group("Window")
        add(windows, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(windows, "Zoom", #selector(NSWindow.performZoom(_:)))
        windows.addItem(.separator())
        add(windows, "Show Next Tab", #selector(NSWindow.selectNextTab(_:)), "]", modifiers: [.command, .shift])
        add(windows, "Show Previous Tab", #selector(NSWindow.selectPreviousTab(_:)), "[", modifiers: [.command, .shift])
        add(windows, "Show All Tabs", #selector(NSWindow.toggleTabOverview(_:)))
        NSApp.windowsMenu = windows
        NSApp.mainMenu = menu
    }
    private func argument(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: name), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }
}
