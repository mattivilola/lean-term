import AppKit
import LeanTermCore
import SwiftTerm

/// One native tab: the window, footer, toolbar and tab mark around one or more terminal panes.
/// Pane state is aggregated here; the focused pane supplies title, subtitle, label and session mark.
@MainActor
final class TerminalWindow: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    typealias State = TerminalPane.State
    let id = UUID()
    private(set) var panes: [TerminalPane]
    private(set) var focusedPane: TerminalPane
    private let surface = TerminalSurface()
    private let status = NSTextField(labelWithString: "")
    private var statusBeforeCopyNotice: String?
    private var activeCopyNotice: String?
    private var copyNotice: Task<Void, Never>?
    private let dimensions = NSTextField(labelWithString: "")
    let resourceStatus = ResourceStatusView()
    private let tabMark = TabActivityView()
    var hasUnseenActivity: Bool { panes.contains(where: \.hasUnseenActivity) }
    weak var activityMonitor: SessionActivityMonitor?
    private let restart = NSButton(title: "New Session", target: nil, action: nil)
    private(set) var customName: String?
    private var preferences: Preferences
    private var fullscreenTransition = false
    weak var app: AppDelegate?

    /// The focused pane's terminal, for menus and first-responder handling.
    var terminal: LeanTerminalView { focusedPane.terminal }
    /// Focused-pane conveniences.
    var state: State { focusedPane.state }
    var terminationCount: Int { focusedPane.terminationCount }
    var currentDirectory: String { focusedPane.currentDirectory }
    var folderName: String { focusedPane.folderName }
    var directoryForNewSession: String { focusedPane.directoryForNewSession }

    var live: Bool { panes.contains(where: \.live) }
    var isResourceDisplayVisible: Bool {
        guard let window, window.isVisible, !window.isMiniaturized, window.occlusionState.contains(.visible) else { return false }
        return window.tabGroup?.selectedWindow == nil || window.tabGroup?.selectedWindow === window
    }

    init(preferences: Preferences, directory: String? = nil) {
        self.preferences = preferences
        let pane = TerminalPane(preferences: preferences, directory: directory)
        panes = [pane]
        focusedPane = pane
        let rect = pane.terminal.getOptimalFrameSize()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: rect.width + 28, height: rect.height + 46),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        pane.host = self
        window.delegate = self
        window.title = "Lean Term"
        window.tabbingIdentifier = "LeanTerm.Terminal"
        window.tabbingMode = .automatic
        window.minSize = NSSize(width: 480, height: 300)
        window.isReleasedWhenClosed = false
        window.contentView = surface
        surface.addSubview(pane.view)
        let footer = NSStackView(views: [status, NSView(), restart, resourceStatus, dimensions])
        footer.orientation = .horizontal; footer.spacing = 12
        footer.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(footer)
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
            pane.view.topAnchor.constraint(equalTo: surface.topAnchor),
            pane.view.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            pane.view.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            pane.view.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -6),
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
        updateSubtitle()
        surface.layoutSubtreeIfNeeded()
        status.stringValue = pane.initialStatusText
        window.center()
    }

    /// Register the controller with the app before a shell can synchronously exit.
    func start(smoke: Bool = false) {
        for pane in panes { pane.start(smoke: smoke) }
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
        for pane in panes { pane.refreshDirectory() }
        app?.recordActiveSession(self)
        savePlacement()
        for pane in panes {
            pane.markSeen()
            app?.notifier.clear(sessionID: pane.id)
        }
        visibilityChanged()
    }
    func windowDidChangeOcclusionState(_ notification: Notification) { visibilityChanged() }
    func windowDidMiniaturize(_ notification: Notification) { visibilityChanged() }
    func windowDidDeminiaturize(_ notification: Notification) { visibilityChanged() }

    private func visibilityChanged() {
        app?.refreshResourceMonitoring()
        for pane in panes { pane.renderScanner() }
        renderActivity()
    }

    /// The key window of an active app with its terminal on screen.
    private var isBeingViewed: Bool {
        window?.isKeyWindow == true && isResourceDisplayVisible && NSApp.isActive
    }

    private var theme: TerminalTheme {
        TerminalTheme(palette: preferences.palette, dark: surface.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }

    private func updateSubtitle() {
        updateTabLabel()
        let subtitle = focusedPane.locationSubtitle
        if window?.subtitle != subtitle { window?.subtitle = subtitle }
    }

    /// Tab mark: running when any pane is busy, done or attention when any pane has unseen activity,
    /// session mark of the focused pane.
    private func renderActivity() {
        if !preferences.showTabActivity {
            tabMark.setMark(.hidden)
        } else if panes.contains(where: { $0.activityIndicator != .idle }) {
            tabMark.setMark(.running)
        } else {
            tabMark.setMark(panes.contains(where: \.finishedUnseen) ? .done : .hidden)
        }
        tabMark.setAttention(panes.contains(where: \.bellUnseen))
        tabMark.setSession(focusedPane.sessionMark)
    }
    func windowDidResignKey(_ notification: Notification) { savePlacement(); visibilityChanged() }
    func windowDidEndLiveResize(_ notification: Notification) { savePlacement() }
    func windowWillEnterFullScreen(_ notification: Notification) { savePlacement(); fullscreenTransition = true }
    func windowDidExitFullScreen(_ notification: Notification) { fullscreenTransition = false; savePlacement() }

    func apply(_ value: Preferences) {
        preferences = value
        resourceStatus.isHidden = !value.showResourceUsage
        for pane in panes { pane.apply(value) }
        updateSubtitle()
        applyTheme()
    }

    private func applyTheme() {
        let theme = theme
        window?.backgroundColor = theme.background
        surface.layer?.backgroundColor = theme.background.cgColor
        status.textColor = .secondaryLabelColor
        dimensions.textColor = .tertiaryLabelColor
        restart.contentTintColor = theme.accent
        resourceStatus.applyAccent(theme.accent)
        tabMark.applyColors(phosphor: theme.phosphor, amber: theme.amber)
        for pane in panes { pane.applyTheme(theme) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard live else { return true }
        guard !panes.contains(where: { $0.state == .closing }) else { return false }
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

    /// Shuts every live pane down; see `TerminalPane.beginShutdown`.
    func beginShutdown() {
        for pane in panes where pane.live { pane.beginShutdown() }
    }

    func windowWillClose(_ notification: Notification) {
        savePlacement()
        for pane in panes { pane.cancelShutdownFallback() }
        app?.remove(self)
    }

    func setCustomName(_ name: String?) {
        customName = SessionTab.cleanedName(name)
        window?.title = customName ?? folderName
        updateTabLabel()
    }

    private func updateTabLabel() {
        let label = customName ?? focusedPane.automaticTabLabel
        if window?.tab.title != label { window?.tab.title = label }
        let tooltip = focusedPane.locationToolTip
        if window?.tab.toolTip != tooltip { window?.tab.toolTip = tooltip }
    }

    /// Shows the redaction result in the footer for 3 s, then restores the previous text unless it changed meanwhile.
    private func showCopyNotice(removed: Int) {
        let message = "Copied · \(removed) sensitive item\(removed == 1 ? "" : "s") removed"
        // A notice still showing keeps the text it replaced; any other current text is the one to restore.
        if status.stringValue != activeCopyNotice { statusBeforeCopyNotice = status.stringValue }
        activeCopyNotice = message
        status.stringValue = message
        copyNotice?.cancel()
        copyNotice = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            if status.stringValue == message, let previous = statusBeforeCopyNotice { status.stringValue = previous }
            activeCopyNotice = nil; statusBeforeCopyNotice = nil
        }
    }

    @objc private func restartSession() {
        app?.newTerminal(directory: directoryForNewSession)
        window?.close()
    }
    @objc private func newTab() { app?.newTab(nil) }
    @objc private func settings() { app?.showSettings(nil) }
    @objc private func renameTab() { app?.renameTab(nil) }
    @objc private func find() {
        let item = NSMenuItem(); item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        terminal.performFindPanelAction(item)
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.init("new"), .flexibleSpace, .init("rename"), .init("find"), .init("settings")]
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarAllowedItemIdentifiers(toolbar) }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        let config: (String, String, Selector)
        switch identifier.rawValue {
        case "new": config = ("New Tab", "plus", #selector(newTab))
        case "rename": config = ("Rename Tab", "pencil", #selector(renameTab))
        case "find": config = ("Find", "magnifyingglass", #selector(find))
        case "settings": config = ("Settings", "slider.horizontal.3", #selector(settings))
        default: return nil
        }
        item.label = config.0; item.toolTip = config.0
        item.image = NSImage(systemSymbolName: config.1, accessibilityDescription: config.0)
        item.target = self; item.action = config.2
        return item
    }
}

extension TerminalWindow: TerminalPaneHost {
    func isPaneVisible(_ pane: TerminalPane) -> Bool { isResourceDisplayVisible }
    func isPaneBeingViewed(_ pane: TerminalPane) -> Bool { pane === focusedPane && isBeingViewed }
    func permitsAutomaticClose(for pane: TerminalPane) -> Bool {
        app?.permitsAutomaticSessionClose == true && window?.attachedSheet == nil
    }

    func paneDidChangeLocation(_ pane: TerminalPane) {
        if pane === focusedPane { updateSubtitle() }
    }
    func paneDidChangeDirectory(_ pane: TerminalPane) {
        if pane === focusedPane { window?.representedURL = URL(fileURLWithPath: pane.currentDirectory) }
    }
    func pane(_ pane: TerminalPane, didSetTitle title: String) {
        guard pane === focusedPane else { return }
        window?.title = customName ?? title
        updateTabLabel()
    }
    func paneDidChangeActivity(_ pane: TerminalPane) { renderActivity() }
    func paneDidChangeUnseenActivity(_ pane: TerminalPane) { app?.unseenActivityChanged() }
    func paneDidReceiveOutput(_ pane: TerminalPane) { activityMonitor?.wake() }
    func pane(_ pane: TerminalPane, finishedLongCommandAfter duration: TimeInterval) {
        app?.notifier.postFinished(sessionID: pane.id, title: window?.title ?? "Lean Term", duration: duration)
    }

    func pane(_ pane: TerminalPane, didSetStatus text: String) { status.stringValue = text }
    func pane(_ pane: TerminalPane, setRestartHidden hidden: Bool) { restart.isHidden = hidden }
    func pane(_ pane: TerminalPane, didChangeDimensions text: String) { dimensions.stringValue = text }
    func pane(_ pane: TerminalPane, didCopyRedacted removed: Int) { showCopyNotice(removed: removed) }
    func paneDidDisableMultilinePasteConfirmation(_ pane: TerminalPane) {
        guard var value = app?.preferences else { return }
        value.confirmMultilinePaste = false
        app?.updatePreferences(value)
    }

    func paneWantsClose(_ pane: TerminalPane) { window?.close() }
    func paneDidTerminate(_ pane: TerminalPane) { app?.sessionDidFinish() }
    func pane(_ pane: TerminalPane, opensTerminalIn folder: URL) { app?.openTerminal(in: folder) }
}
