import AppKit
import LeanTermCore
import Darwin
import SwiftTerm
import Synchronization

/// Cross-thread output signal for the PTY parse thread. It only touches atomics.
final class SessionActivityCounter: Sendable {
    private let output = Atomic<UInt64>(0)
    private let armed = Atomic<Bool>(false)

    var outputCount: UInt64 { output.load(ordering: .relaxed) }

    /// Counts one output batch. Returns true when the sampler should be woken, at most once per sample.
    func noteOutput() -> Bool {
        output.add(1, ordering: .relaxed)
        return armed.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged
    }

    func disarm() { armed.store(false, ordering: .relaxed) }
}

@MainActor
final class TerminalWindow: NSWindowController, NSWindowDelegate, LocalProcessTerminalViewDelegate, NSToolbarDelegate {
    enum State { case starting, running, closing, exited, failed }
    let id = UUID()
    let terminal: LocalProcessTerminalView
    private let surface = TerminalSurface()
    private let status = NSTextField(labelWithString: "")
    private let dimensions = NSTextField(labelWithString: "")
    let resourceStatus = ResourceStatusView()
    private let scanner = ActivityScannerView()
    private let tabMark = TabActivityView()
    private let activityCounter = SessionActivityCounter()
    private var activityModel = SessionActivityModel()
    private var finishedUnseen = false
    weak var activityMonitor: SessionActivityMonitor?
    private let restart = NSButton(title: "New Session", target: nil, action: nil)
    private var fallback: DispatchWorkItem?
    private(set) var state: State = .starting
    private(set) var currentDirectory: String
    private var preferences: Preferences
    private let launch: ShellLaunch
    private var fullscreenTransition = false
    private var didStart = false
    weak var app: AppDelegate?
    var terminationCount = 0

    var live: Bool { state == .running || state == .starting || state == .closing }
    var isResourceDisplayVisible: Bool {
        guard let window, window.isVisible, !window.isMiniaturized, window.occlusionState.contains(.visible) else { return false }
        return window.tabGroup?.selectedWindow == nil || window.tabGroup?.selectedWindow === window
    }

    init(preferences: Preferences, directory: String? = nil) {
        self.preferences = preferences
        launch = ShellLaunch(directory: directory)
        currentDirectory = launch.directory
        let font = TerminalFont.make(name: preferences.fontName, size: preferences.fontSize)
        let cursor: CursorStyle = preferences.cursor == .bar ? .steadyBar : (preferences.cursor == .block ? .steadyBlock : .steadyUnderline)
        terminal = LocalProcessTerminalView(frame: .zero, font: font,
            options: TerminalOptions(cols: 110, rows: 32, cursorStyle: cursor, scrollback: Preferences.scrollbackLines))
        let rect = terminal.getOptimalFrameSize()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: rect.width + 28, height: rect.height + 46),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.delegate = self
        window.title = "Lean Term"
        window.subtitle = Self.displayPath(currentDirectory)
        window.tabbingIdentifier = "LeanTerm.Terminal"
        window.tabbingMode = .automatic
        window.minSize = NSSize(width: 480, height: 300)
        window.isReleasedWhenClosed = false
        window.contentView = surface
        terminal.processDelegate = self
        installOutputHandler()
        terminal.bellStyle = .none
        // This remains the measured CoreGraphics/CoreText implementation.
        do { try terminal.setUseMetal(false) }
        catch { preconditionFailure("Cannot select CoreGraphics: \(error)") }
        terminal.translatesAutoresizingMaskIntoConstraints = false
        terminal.setAccessibilityLabel("Terminal session")
        surface.addSubview(terminal)
        let footer = NSStackView(views: [status, NSView(), restart, resourceStatus, dimensions])
        footer.orientation = .horizontal; footer.spacing = 12
        footer.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(footer)
        scanner.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(scanner)
        window.tab.accessoryView = tabMark
        status.font = .systemFont(ofSize: 11)
        status.lineBreakMode = .byTruncatingMiddle
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dimensions.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        dimensions.setContentHuggingPriority(.required, for: .horizontal)
        restart.bezelStyle = .inline
        restart.controlSize = .small
        restart.target = self; restart.action = #selector(restartSession)
        restart.isHidden = true
        NSLayoutConstraint.activate([
            scanner.topAnchor.constraint(equalTo: surface.topAnchor, constant: 5),
            scanner.heightAnchor.constraint(equalToConstant: 2),
            scanner.leadingAnchor.constraint(equalTo: terminal.leadingAnchor),
            scanner.trailingAnchor.constraint(equalTo: terminal.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: surface.topAnchor, constant: 12),
            terminal.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 14),
            terminal.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -14),
            terminal.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -6),
            footer.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -7),
            footer.heightAnchor.constraint(equalToConstant: 18)
        ])
        let toolbar = NSToolbar(identifier: "TerminalToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
        surface.wantsLayer = true
        surface.appearanceChanged = { [weak self] in self?.applyTheme() }
        apply(preferences)
        surface.layoutSubtreeIfNeeded()
        status.stringValue = launch.usedFallback ? "Login shell unavailable · using zsh" : URL(fileURLWithPath: launch.executable).lastPathComponent
        window.center()
    }

    /// Register the controller with the app before a shell can synchronously exit.
    func start(smoke: Bool = false) {
        guard !didStart, state == .starting else { return }
        didStart = true
        if smoke {
            terminal.startProcess(executable: "/bin/zsh", args: ["-f"], environment: launch.environment, currentDirectory: currentDirectory)
        } else {
            terminal.startProcess(executable: launch.executable, environment: launch.environment, execName: launch.execName, currentDirectory: currentDirectory)
        }
        if state == .starting { state = terminal.process.running ? .running : .failed }
    }

    required init?(coder: NSCoder) { fatalError("Programmatic windows only") }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(terminal)
    }

    func restorePlacement(_ placement: WindowPlacement?, tabOf parent: TerminalWindow?) {
        guard let window else { return }
        if let parent = parent?.window {
            window.setFrame(parent.frame, display: false)
        } else {
            let screens = NSScreen.screens.map(\.visibleFrame)
            if let saved = placement ?? WindowPlacement(frame: window.frame) {
                window.setFrame(saved.fitted(to: screens), display: false)
            }
        }
    }

    func savePlacement() {
        guard !fullscreenTransition else { return }
        app?.savePlacement(of: self)
    }
    func windowDidBecomeKey(_ notification: Notification) {
        app?.recordActiveSession(self)
        savePlacement()
        finishedUnseen = false
        visibilityChanged()
    }
    func windowDidChangeOcclusionState(_ notification: Notification) { visibilityChanged() }
    func windowDidMiniaturize(_ notification: Notification) { visibilityChanged() }
    func windowDidDeminiaturize(_ notification: Notification) { visibilityChanged() }

    private func visibilityChanged() {
        app?.refreshResourceMonitoring()
        renderActivity()
    }

    private func installOutputHandler() {
        let counter = activityCounter
        terminal.setProcessOutputHandler { [weak self] in
            guard counter.noteOutput() else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.activityMonitor?.wake() }
            }
        }
    }

    /// Samples the foreground job once. Returns whether another sample is needed.
    func sampleActivity(at time: TimeInterval) -> Bool {
        var foreground = false
        if let process = terminal.process, process.running {
            let group = tcgetpgrp(process.childfd)
            foreground = group > 0 && group != process.shellPid
        }
        let sample = SessionActivitySample(
            foregroundJobRunning: foreground,
            alternateScreen: terminal.terminalInputStateSnapshot()?.isAlternateBuffer == true,
            outputCount: activityCounter.outputCount, time: time)
        activityCounter.disarm()
        if activityModel.record(sample) == .finishedLongCommand, preferences.showTabActivity,
           !(window?.isKeyWindow == true && isResourceDisplayVisible && NSApp.isActive) {
            finishedUnseen = true
        }
        if activityModel.indicator != .idle { finishedUnseen = false }
        renderActivity()
        return activityModel.needsPolling
    }

    func motionOptionsChanged() { scanner.motionOptionsChanged() }

    func resetActivity() {
        activityModel.reset()
        finishedUnseen = false
        renderActivity()
    }

    private func renderActivity() {
        let indicator = activityModel.indicator
        scanner.setIndicator(preferences.showActivityScanner ? indicator : .idle, visible: isResourceDisplayVisible)
        if !preferences.showTabActivity {
            tabMark.setMark(.hidden)
        } else if indicator != .idle {
            tabMark.setMark(.running)
        } else {
            tabMark.setMark(finishedUnseen ? .done : .hidden)
        }
    }
    func windowDidResignKey(_ notification: Notification) { savePlacement(); visibilityChanged() }
    func windowDidEndLiveResize(_ notification: Notification) { savePlacement() }
    func windowWillEnterFullScreen(_ notification: Notification) { savePlacement(); fullscreenTransition = true }
    func windowDidExitFullScreen(_ notification: Notification) { fullscreenTransition = false; savePlacement() }

    func apply(_ value: Preferences) {
        preferences = value
        resourceStatus.isHidden = !value.showResourceUsage
        if !value.showTabActivity { finishedUnseen = false }
        let font = TerminalFont.make(name: value.fontName, size: value.fontSize)
        if terminal.font != font { terminal.font = font }
        terminal.optionAsMetaKey = value.optionAsMeta
        terminal.setCursorStyle(value.cursor == .bar ? .steadyBar : (value.cursor == .block ? .steadyBlock : .steadyUnderline))
        applyTheme()
        renderActivity()
    }

    private func applyTheme() {
        let dark = surface.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let theme = TerminalTheme(palette: preferences.palette, dark: dark)
        terminal.installColors(theme.ansi)
        terminal.nativeBackgroundColor = theme.background
        terminal.nativeForegroundColor = theme.foreground
        terminal.caretColor = theme.accent
        terminal.selectedTextBackgroundColor = theme.selection
        terminal.selectedTextForegroundColor = theme.foreground
        window?.backgroundColor = theme.background
        surface.layer?.backgroundColor = theme.background.cgColor
        status.textColor = .secondaryLabelColor
        dimensions.textColor = .tertiaryLabelColor
        restart.contentTintColor = theme.accent
        resourceStatus.applyAccent(theme.accent)
        scanner.applyAccent(theme.phosphor)
        tabMark.applyAccent(theme.phosphor)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard live else { return true }
        guard state != .closing else { return false }
        let alert = NSAlert()
        alert.messageText = "Close this session?"
        alert.informativeText = "The shell and programs running in this terminal will be stopped."
        alert.addButton(withTitle: "Close Session")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.last?.keyEquivalent = "\r"
        alert.beginSheetModal(for: sender) { [weak self] result in
            guard result == .alertFirstButtonReturn else { return }
            guard let self else { return }
            if self.live { self.beginShutdown() } else { self.window?.close() }
        }
        return false
    }

    /// Keep the PTY/view alive until SwiftTerm has reaped the child and drained output.
    /// Only called after synchronous launch returns. No PID is captured or signalled here.
    func beginShutdown() {
        guard live, state != .closing else { return }
        state = .closing
        status.stringValue = "Closing session…"
        terminal.isHidden = false
        terminal.process.terminate(signal: SIGHUP)
        let session = id
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.id == session, self.state == .closing else { return }
            self.terminal.process.terminate(signal: SIGKILL)
        }
        fallback = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: work)
    }

    func windowWillClose(_ notification: Notification) {
        savePlacement()
        fallback?.cancel(); fallback = nil
        app?.remove(self)
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        dimensions.stringValue = "\(newCols) × \(newRows)"
    }
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        let clean = String(title.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(120))
        if !clean.isEmpty { window?.title = clean }
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let path = ShellLaunch.localDirectory(from: directory) else { return }
        currentDirectory = path
        window?.subtitle = Self.displayPath(path)
        window?.representedURL = URL(fileURLWithPath: path)
    }
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        terminationCount += 1
        resetActivity()
        let wasClosing = state == .closing
        state = .exited
        fallback?.cancel(); fallback = nil
        status.stringValue = exitCode == 0 ? "Session ended" : "Session ended · \(exitCode.map(String.init) ?? "signal")"
        restart.isHidden = false
        // Preserve any outstanding close/quit sheet. Cancel must keep its window.
        if wasClosing || (preferences.closeTabOnShellExit && app?.permitsAutomaticSessionClose == true && window?.attachedSheet == nil) {
            window?.close()
        }
        app?.sessionDidFinish()
    }
    func processFailedToStart(source: TerminalView, error: LocalProcessError) {
        state = .failed
        resetActivity()
        status.stringValue = "Couldn’t start the shell"
        restart.isHidden = false
    }

    func clearScreenAndScrollback() {
        terminal.selectNone()
        // Local parser output only: never send a control key/command to the shell.
        // Keep terminal modes and the configured history capacity intact.
        terminal.feed(text: "\u{1B}[H\u{1B}[2J")
        terminal.clearScrollback()
    }

    @objc private func restartSession() {
        app?.newTerminal(directory: currentDirectory)
        window?.close()
    }
    @objc private func newTab() { app?.newTab(nil) }
    @objc private func settings() { app?.showSettings(nil) }
    @objc private func find() {
        let item = NSMenuItem(); item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        terminal.performFindPanelAction(item)
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.init("new"), .flexibleSpace, .init("find"), .init("settings")]
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarAllowedItemIdentifiers(toolbar) }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        let config: (String, String, Selector)
        switch identifier.rawValue {
        case "new": config = ("New Tab", "plus", #selector(newTab))
        case "find": config = ("Find", "magnifyingglass", #selector(find))
        case "settings": config = ("Settings", "slider.horizontal.3", #selector(settings))
        default: return nil
        }
        item.label = config.0; item.toolTip = config.0
        item.image = NSImage(systemSymbolName: config.1, accessibilityDescription: config.0)
        item.target = self; item.action = config.2
        return item
    }
    private static func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
