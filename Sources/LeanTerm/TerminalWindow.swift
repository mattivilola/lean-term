import AppKit
import LeanTermCore
import SwiftTerm

/// One native tab: the window, footer, toolbar and tab mark around one or more terminal panes.
/// Pane state is aggregated here; the focused pane supplies title, subtitle, label and session mark.
@MainActor
final class TerminalWindow: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    typealias State = TerminalPane.State
    enum Style { case standard, quickTerminal }
    let id = UUID()
    /// The dedicated dropdown window: a borderless floating panel outside tabs, workspace restore and window placement.
    let isQuickTerminal: Bool
    /// Bumped by every quick-terminal show or hide so a superseded animation's completion does nothing.
    var quickTerminalGeneration = 0
    var quickTerminalHiding = false
    private var quickBorder: NSView?
    private(set) var panes: [TerminalPane]
    private(set) var focusedPane: TerminalPane
    /// The split arrangement of `panes`; while zoomed the focused pane alone fills `paneArea`.
    private(set) var layout: PaneLayout
    private(set) var isZoomed = false
    private let paneArea = NSView()
    private lazy var paneDrag = PaneDragController(area: paneArea)
    private var splitViews: [PaneSplitView] = []
    private var applyingRatios = false
    private var smokeMode = false
    private var firstResponderObservation: NSKeyValueObservation?
    private let surface = TerminalSurface()
    private let status = NSTextField(labelWithString: "")
    private var statusBeforeCopyNotice: String?
    private var activeCopyNotice: String?
    private var copyNotice: Task<Void, Never>?
    private let dimensions = NSTextField(labelWithString: "")
    let commandResultStatus = NSTextField(labelWithString: "")
    let jumpToLiveButton = NSButton(title: "↓ Live", target: nil, action: nil)
    let scrollbackStatus = NSTextField(labelWithString: "")
    private var lastScrollbackUsage: (used: Int, capacity: Int)?
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

    init(preferences: Preferences, directory: String? = nil, style: Style = .standard) {
        self.preferences = preferences
        isQuickTerminal = style == .quickTerminal
        let pane = TerminalPane(preferences: preferences, directory: directory)
        panes = [pane]
        focusedPane = pane
        layout = .pane(pane.id)
        let rect = pane.terminal.getOptimalFrameSize()
        let contentRect = NSRect(x: 0, y: 0, width: rect.width + 28, height: rect.height + 46)
        let window: NSWindow = style == .quickTerminal
            ? QuickTerminalPanel(contentRect: contentRect, styleMask: [.borderless, .closable], backing: .buffered, defer: false)
            : NSWindow(contentRect: contentRect, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        pane.host = self
        window.delegate = self
        // A click or focus command that makes a terminal first responder focuses its pane.
        firstResponderObservation = window.observe(\.firstResponder, options: [.new]) { [weak self] _, change in
            MainActor.assumeIsolated {
                guard let self, let responder = change.newValue ?? nil,
                      let pane = self.panes.first(where: { $0.terminal === responder }) else { return }
                self.focus(pane)
            }
        }
        window.title = "Lean Term"
        window.tabbingIdentifier = "LeanTerm.Terminal"
        window.tabbingMode = style == .quickTerminal ? .disallowed : .automatic
        window.minSize = style == .quickTerminal ? NSSize(width: 320, height: 160) : NSSize(width: 480, height: 300)
        window.isReleasedWhenClosed = false
        window.contentView = surface
        paneArea.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(paneArea)
        let footer = NSStackView(views: [status, commandResultStatus, NSView(), restart, jumpToLiveButton, scrollbackStatus, resourceStatus, dimensions])
        footer.orientation = .horizontal; footer.spacing = 12
        footer.setClippingResistancePriority(.defaultLow, for: .horizontal)
        footer.setVisibilityPriority(.detachOnlyIfNecessary, for: commandResultStatus)
        footer.setVisibilityPriority(.init(rawValue: 950), for: scrollbackStatus)
        footer.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(footer)
        resourceStatus.focusedProcesses = { [weak self] in
            guard let self, self.focusedPane.runningShellPID != nil else { return [] }
            return self.app?.metricsMonitor.paneProcesses[self.focusedPane.id] ?? []
        }
        window.tab.accessoryView = tabMark
        status.font = .systemFont(ofSize: 11)
        status.lineBreakMode = .byTruncatingMiddle
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        commandResultStatus.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        commandResultStatus.setContentHuggingPriority(.required, for: .horizontal)
        commandResultStatus.isHidden = true
        jumpToLiveButton.bezelStyle = .inline
        jumpToLiveButton.controlSize = .small
        jumpToLiveButton.target = self
        jumpToLiveButton.action = #selector(jumpToLive)
        jumpToLiveButton.toolTip = "Jump to live output"
        jumpToLiveButton.setAccessibilityLabel("Jump to live output")
        jumpToLiveButton.isHidden = true
        scrollbackStatus.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        scrollbackStatus.lineBreakMode = .byTruncatingTail
        scrollbackStatus.setContentHuggingPriority(.required, for: .horizontal)
        dimensions.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        dimensions.setContentHuggingPriority(.required, for: .horizontal)
        restart.bezelStyle = .inline
        restart.controlSize = .small
        restart.target = self; restart.action = #selector(restartSession)
        restart.isHidden = true
        NSLayoutConstraint.activate([
            paneArea.topAnchor.constraint(equalTo: surface.topAnchor),
            paneArea.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            paneArea.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            paneArea.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -6),
            footer.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -7),
            footer.heightAnchor.constraint(equalToConstant: 18)
        ])
        if style == .quickTerminal {
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.hasShadow = true
            window.isMovable = false
            let border = NSView()
            border.wantsLayer = true
            border.translatesAutoresizingMaskIntoConstraints = false
            surface.addSubview(border)
            NSLayoutConstraint.activate([
                border.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
                border.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
                border.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
                border.heightAnchor.constraint(equalToConstant: 1)
            ])
            quickBorder = border
        } else {
            let toolbar = NSToolbar(identifier: "TerminalToolbar")
            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            window.toolbar = toolbar
            window.toolbarStyle = .unifiedCompact
        }
        surface.wantsLayer = true
        surface.appearanceChanged = { [weak self] in self?.applyTheme() }
        rebuildLayout()
        apply(preferences)
        updateSubtitle()
        surface.layoutSubtreeIfNeeded()
        status.stringValue = pane.statusText
        if style == .standard { window.center() }
    }

    /// Register the controller with the app before a shell can synchronously exit.
    func start(smoke: Bool = false) {
        smokeMode = smoke
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
        if isResourceDisplayVisible { updateScrollbackStatus() }
        else { resourceStatus.closeProcessBreakdown() }
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
            tabMark.setMark(panes.contains(where: \.finishedFailedUnseen) ? .failed : (panes.contains(where: \.finishedUnseen) ? .done : .hidden))
        }
        tabMark.setAttention(panes.contains(where: \.bellUnseen))
        tabMark.setSession(focusedPane.sessionMark)
    }
    func windowDidResignKey(_ notification: Notification) { savePlacement(); visibilityChanged() }
    func windowDidResize(_ notification: Notification) { updateResourceLayout() }
    func windowDidEndLiveResize(_ notification: Notification) { savePlacement() }
    func windowWillEnterFullScreen(_ notification: Notification) { savePlacement(); fullscreenTransition = true }
    func windowDidExitFullScreen(_ notification: Notification) { fullscreenTransition = false; savePlacement() }

    func apply(_ value: Preferences) {
        preferences = value
        resourceStatus.isHidden = !value.showResourceUsage
        if !value.showResourceUsage { resourceStatus.closeProcessBreakdown() }
        updateResourceLayout()
        for pane in panes { pane.apply(value) }
        updateScrollbackStatus()
        updateCommandResult()
        updateSubtitle()
        applyTheme()
        updateDimming()
    }

    private func updateResourceLayout() {
        resourceStatus.showsSparklines = (window?.contentView?.bounds.width ?? 0) >= 600
    }

    func updateResourceUsage() {
        guard preferences.showResourceUsage, let monitor = app?.metricsMonitor else { return }
        let pane = focusedPane.runningShellPID == nil ? nil : monitor.paneUsage[focusedPane.id]
        resourceStatus.update(total: monitor.snapshot, pane: pane)
    }

    private func applyTheme() {
        let theme = theme
        window?.backgroundColor = theme.background
        surface.layer?.backgroundColor = theme.background.cgColor
        status.textColor = .secondaryLabelColor
        commandResultStatus.textColor = .secondaryLabelColor
        jumpToLiveButton.contentTintColor = theme.accent
        scrollbackStatus.textColor = .secondaryLabelColor
        dimensions.textColor = .tertiaryLabelColor
        restart.contentTintColor = theme.accent
        resourceStatus.applyAccent(theme.accent)
        quickBorder?.layer?.backgroundColor = theme.phosphor.withAlphaComponent(0.35).cgColor
        tabMark.applyColors(phosphor: theme.phosphor, amber: theme.amber, failure: theme.failure)
        for pane in panes { pane.applyTheme(theme) }
        for splitView in splitViews { splitView.dividerTint = theme.foreground.withAlphaComponent(0.18) }
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

    var tabLabel: String { customName ?? focusedPane.automaticTabLabel }

    private func updateTabLabel() {
        let label = tabLabel
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
        guard panes.count > 1 || isQuickTerminal else {
            app?.newTerminal(directory: directoryForNewSession)
            window?.close()
            return
        }
        // A new shell takes the finished pane's place in the arrangement.
        let old = focusedPane
        let new = makePane(directory: old.directoryForNewSession)
        layout = layout.splitting(old.id, with: new.id, axis: .horizontal).removing(old.id) ?? layout
        removeFromWindow(old)
        panes.append(new)
        syncPanes()
        rebuildLayout()
        new.start(smoke: smokeMode)
        window?.makeFirstResponder(new.terminal)
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

// MARK: Split panes

extension TerminalWindow {
    private func makePane(directory: String?) -> TerminalPane {
        let pane = TerminalPane(preferences: preferences, directory: directory)
        pane.host = self
        pane.apply(preferences)
        pane.applyTheme(theme)
        return pane
    }

    /// Keeps `panes` in reading order of the layout.
    private func syncPanes() {
        let byID = Dictionary(uniqueKeysWithValues: panes.map { ($0.id, $0) })
        panes = layout.paneIDs.compactMap { byID[$0] }
    }

    private func removeFromWindow(_ pane: TerminalPane) {
        pane.cancelShutdownFallback()
        app?.notifier.clear(sessionID: pane.id)
        panes.removeAll { $0 === pane }
        pane.view.removeFromSuperview()
        // The shell callback that led here may still be on the stack.
        DispatchQueue.main.async { withExtendedLifetime(pane) {} }
    }

    /// Splits the focused pane; the new pane starts in its folder and takes focus.
    func split(_ axis: PaneLayout.Axis) {
        endZoom()
        let new = makePane(directory: focusedPane.directoryForNewSession)
        layout = layout.splitting(focusedPane.id, with: new.id, axis: axis)
        panes.append(new)
        syncPanes()
        rebuildLayout()
        new.start(smoke: smokeMode)
        window?.makeFirstResponder(new.terminal)
    }

    /// The tab as saved in a workspace: its split layout (nil for one pane) and the focused pane's index.
    /// Zoom is not saved.
    var workspaceTab: SessionTab {
        let focused = panes.firstIndex { $0 === focusedPane } ?? 0
        guard panes.count > 1 else { return SessionTab(directory: directoryForNewSession, customName: customName) }
        let directories = Dictionary(uniqueKeysWithValues: panes.map { ($0.id, $0.directoryForNewSession) })
        return SessionTab(directory: directoryForNewSession, customName: customName,
                          layout: SavedPaneLayout(layout, directories: directories, fallback: directoryForNewSession),
                          focusedPane: focused)
    }

    /// Rebuilds a saved arrangement in a freshly created single-pane tab: the first pane stays, one
    /// new pane starts per further leaf, and the saved pane gets first responder (which does not make
    /// the window key). Dividers are placed now and again once the window has settled.
    func restore(layout saved: SavedPaneLayout, focused: Int) {
        let directories = saved.directories
        guard panes.count == 1, directories.count > 1 else { return }
        let added = directories.dropFirst().map { makePane(directory: $0) }
        let restored = saved.paneLayout(ids: [focusedPane.id] + added.map(\.id))
        layout = restored
        panes += added
        syncPanes()
        rebuildLayout()
        for pane in added { pane.start(smoke: smokeMode) }
        if panes.indices.contains(focused) { window?.makeFirstResponder(panes[focused].terminal) }
        DispatchQueue.main.async { [weak self] in
            guard let self, !isZoomed, layout.paneIDs == restored.paneIDs else { return }
            layout = restored
            applyRatios()
        }
    }

    /// Takes a pane out of the arrangement once its shell is gone. Its sibling inherits focus.
    private func removePane(_ pane: TerminalPane) {
        guard panes.count > 1, let remaining = layout.removing(pane.id) else { return }
        let successor = pane === focusedPane ? layout.sibling(of: pane.id).flatMap { id in panes.first { $0.id == id } } : nil
        endZoom(rebuild: false)
        layout = remaining
        removeFromWindow(pane)
        syncPanes()
        rebuildLayout()
        if let successor { window?.makeFirstResponder(successor.terminal) }
    }

    /// File › Close with several panes: the focused pane only, after confirmation when its shell is live.
    func closeFocusedPane() {
        guard panes.count > 1 else { return }
        let pane = focusedPane
        guard pane.state != .closing else { return }
        guard pane.live, let window else { removePane(pane); return }
        let alert = NSAlert()
        alert.messageText = "Close this pane?"
        alert.informativeText = "The shell and programs running in this pane will be stopped."
        alert.addButton(withTitle: "Close Pane")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.last?.keyEquivalent = "\r"
        alert.beginSheetModal(for: window) { [weak self, weak pane] result in
            guard result == .alertFirstButtonReturn, let self, let pane, self.panes.contains(where: { $0 === pane }) else { return }
            if pane.live { pane.beginShutdown() } else { self.removePane(pane) }
        }
    }

    func selectPane(_ direction: PaneLayout.Direction) {
        guard let id = layout.neighbour(of: focusedPane.id, direction), let pane = panes.first(where: { $0.id == id }) else { return }
        endZoom()
        window?.makeFirstResponder(pane.terminal)
    }

    /// Swaps the focused pane with its neighbour in a direction.
    func movePane(_ direction: PaneLayout.Direction) {
        guard !isZoomed, let id = layout.neighbour(of: focusedPane.id, direction) else { return }
        reorder(focusedPane, layout.swapping(focusedPane.id, id))
    }

    /// Applies a drag-and-drop result: the pane lands beside the target or swaps with it.
    private func drop(_ pane: TerminalPane, _ drop: PaneDrop) {
        reorder(pane, drop.edge.map { layout.moving(pane.id, to: drop.target, edge: $0) } ?? layout.swapping(pane.id, drop.target))
    }

    /// Adopts a rearranged layout by reparenting the existing pane views; the pane keeps focus.
    private func reorder(_ pane: TerminalPane, _ arranged: PaneLayout) {
        guard arranged != layout, panes.contains(where: { $0 === pane }) else { return }
        layout = arranged
        syncPanes()
        rebuildLayout()
        window?.makeFirstResponder(pane.terminal)
    }

    func toggleZoom() {
        guard panes.count > 1 || isZoomed else { return }
        isZoomed.toggle()
        rebuildLayout()
        window?.makeFirstResponder(focusedPane.terminal)
        updateDimming()
    }

    private func endZoom(rebuild: Bool = true) {
        guard isZoomed else { return }
        isZoomed = false
        if rebuild { rebuildLayout() }
    }

    func equalizePanes() {
        endZoom()
        layout = layout.equalized()
        applyRatios()
    }

    private func focus(_ pane: TerminalPane) {
        guard pane !== focusedPane, panes.contains(where: { $0 === pane }) else { return }
        resourceStatus.closeProcessBreakdown()
        focusedPane = pane
        window?.title = customName ?? pane.terminalTitle ?? pane.folderName
        updateSubtitle()
        status.stringValue = pane.statusText
        dimensions.stringValue = pane.dimensionsText
        updateScrollbackStatus()
        updateCommandResult()
        updateResourceUsage()
        restart.isHidden = pane.restartHidden
        renderActivity()
        updateDimming()
    }

    private func updateDimming() {
        let dim = preferences.dimInactivePanes && panes.count > 1 && !isZoomed
        for pane in panes { pane.setDimmed(dim && pane !== focusedPane) }
    }

    private func updateScrollbackStatus() {
        let usage = terminal.scrollbackUsage
        if jumpToLiveButton.isHidden == usage.isBrowsing { jumpToLiveButton.isHidden = !usage.isBrowsing }
        let counts = (usage.used, usage.capacity)
        if let lastScrollbackUsage, lastScrollbackUsage == counts { return }
        lastScrollbackUsage = counts
        let percent = usage.capacity > 0 ? usage.used * 100 / usage.capacity : 0
        let capacity = usage.capacity >= 1_000 && usage.capacity.isMultiple(of: 1_000)
            ? "\(usage.capacity / 1_000)k" : usage.capacity.formatted()
        scrollbackStatus.stringValue = "Scrollback \(usage.used.formatted()) / \(capacity) (\(percent)%)"
        let detail = "This pane retains \(usage.used.formatted()) of \(usage.capacity.formatted()) scrollback lines."
        scrollbackStatus.toolTip = detail
        scrollbackStatus.setAccessibilityHelp(detail)
    }

    @objc private func jumpToLive() {
        terminal.scrollTo(row: .max)
        window?.makeFirstResponder(terminal)
    }

    private func updateCommandResult() {
        guard preferences.showCommandStatus, let result = focusedPane.lastCommandResult else {
            commandResultStatus.isHidden = true
            commandResultStatus.stringValue = ""
            return
        }
        let elapsed = Duration.seconds(result.duration).formatted(.units(
            allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2,
            fractionalPart: .show(length: 1)
        ))
        let outcome = result.exitCode.map { "Exit \($0)" } ?? "Finished"
        commandResultStatus.stringValue = "\(outcome) · \(elapsed)"
        commandResultStatus.toolTip = "Last command · \(outcome) · \(elapsed)"
        commandResultStatus.isHidden = false
    }

    // MARK: View tree

    /// Rebuilds the split views around the existing pane views. Panes are never recreated.
    private func rebuildLayout() {
        paneDrag.cancel()
        applyingRatios = true
        defer { applyingRatios = false }
        splitViews = []
        paneArea.subviews.forEach { $0.removeFromSuperview() }
        let root = isZoomed ? focusedPane.view : makeView(for: layout)
        root.translatesAutoresizingMaskIntoConstraints = false
        paneArea.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: paneArea.topAnchor),
            root.leadingAnchor.constraint(equalTo: paneArea.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: paneArea.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: paneArea.bottomAnchor)
        ])
        if !isZoomed { applyRatiosNow() }
        let tint = theme.foreground.withAlphaComponent(0.18)
        for splitView in splitViews { splitView.dividerTint = tint }
        updateDimming()
    }

    private func makeView(for node: PaneLayout) -> NSView {
        switch node {
        case .pane(let id):
            let view = panes.first { $0.id == id }?.view ?? NSView()
            view.removeFromSuperview()
            return view
        case .split(let axis, _, let first, let second):
            let splitView = PaneSplitView()
            splitView.isVertical = axis == .horizontal
            splitView.dividerStyle = .thin
            splitView.delegate = self
            splitView.axis = axis
            splitView.first = first
            splitView.second = second
            splitView.secondStart = second.paneIDs.first
            splitView.addArrangedSubview(makeView(for: first))
            splitView.addArrangedSubview(makeView(for: second))
            splitViews.append(splitView)
            return splitView
        }
    }

    private func applyRatios() {
        applyingRatios = true
        defer { applyingRatios = false }
        applyRatiosNow()
    }

    /// Moves every divider to its stored ratio, outermost first so inner splits see their final size.
    private func applyRatiosNow() {
        surface.layoutSubtreeIfNeeded()
        var ratios: [UUID: Double] = [:]
        collectRatios(layout, into: &ratios)
        for splitView in splitViews {
            guard let start = splitView.secondStart, let ratio = ratios[start] else { continue }
            let length = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
            splitView.setPosition(ratio * (length - splitView.dividerThickness), ofDividerAt: 0)
            splitView.layoutSubtreeIfNeeded()
        }
    }

    private func collectRatios(_ node: PaneLayout, into ratios: inout [UUID: Double]) {
        guard case .split(_, let ratio, let first, let second) = node else { return }
        if let start = second.paneIDs.first { ratios[start] = ratio }
        collectRatios(first, into: &ratios)
        collectRatios(second, into: &ratios)
    }

    private func minimumLength(of node: PaneLayout, along axis: PaneLayout.Axis) -> CGFloat {
        switch node {
        case .pane(let id):
            let size = panes.first { $0.id == id }?.minimumSize ?? .zero
            return axis == .horizontal ? size.width : size.height
        case .split(let splitAxis, _, let first, let second):
            let a = minimumLength(of: first, along: axis), b = minimumLength(of: second, along: axis)
            return splitAxis == axis ? a + b + PaneSplitView.thickness : max(a, b)
        }
    }
}

/// A thin split view whose divider colour follows the theme.
@MainActor
final class PaneSplitView: NSSplitView {
    static let thickness: CGFloat = 1
    var axis = PaneLayout.Axis.horizontal
    var first = PaneLayout.pane(UUID())
    var second = PaneLayout.pane(UUID())
    /// The first pane of the second child: names this split in `PaneLayout.settingRatio`.
    var secondStart: UUID?
    var dividerTint = NSColor.separatorColor { didSet { needsDisplay = true } }
    override var dividerColor: NSColor { dividerTint }
    override var dividerThickness: CGFloat { Self.thickness }
}

extension TerminalWindow: NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        guard let splitView = splitView as? PaneSplitView else { return proposed }
        return max(proposed, minimumLength(of: splitView.first, along: splitView.axis))
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        guard let splitView = splitView as? PaneSplitView else { return proposed }
        let length = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        return min(proposed, length - PaneSplitView.thickness - minimumLength(of: splitView.second, along: splitView.axis))
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !applyingRatios, let splitView = notification.object as? PaneSplitView, let start = splitView.secondStart,
              let firstView = splitView.arrangedSubviews.first else { return }
        let length = (splitView.isVertical ? splitView.bounds.width : splitView.bounds.height) - PaneSplitView.thickness
        guard length > 0 else { return }
        let size = splitView.isVertical ? firstView.frame.width : firstView.frame.height
        layout = layout.settingRatio(size / length, forSplitStartingWith: start)
    }
}

extension TerminalWindow: TerminalPaneHost {
    func paneAllowsReordering(_ pane: TerminalPane) -> Bool { panes.count > 1 && !isZoomed }
    func pane(_ pane: TerminalPane, gripDragged phase: PaneGripPhase, at windowPoint: NSPoint) {
        switch phase {
        case .began:
            guard paneAllowsReordering(pane) else { return }
            paneDrag.begin(pane, theme: theme)
        case .moved:
            paneDrag.move(to: windowPoint, panes: panes)
        case .ended:
            guard let result = paneDrag.finish(at: windowPoint, panes: panes) else { return }
            drop(result.pane, result.drop)
        }
    }
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
    func pane(_ pane: TerminalPane, finishedLongCommandAfter duration: TimeInterval, exitCode: Int?) {
        app?.notifier.postFinished(sessionID: pane.id, title: window?.title ?? "Lean Term", duration: duration, exitCode: exitCode)
    }

    func pane(_ pane: TerminalPane, didSetStatus text: String) {
        guard pane === focusedPane else { return }
        status.stringValue = text
        updateResourceUsage()
    }
    func pane(_ pane: TerminalPane, setRestartHidden hidden: Bool) { if pane === focusedPane { restart.isHidden = hidden } }
    func pane(_ pane: TerminalPane, didChangeDimensions text: String) {
        guard pane === focusedPane else { return }
        dimensions.stringValue = text
        updateScrollbackStatus()
    }
    func paneDidChangeScrollback(_ pane: TerminalPane) { if pane === focusedPane { updateScrollbackStatus() } }
    func paneDidFinishCommand(_ pane: TerminalPane) { if pane === focusedPane { updateCommandResult() } }
    func pane(_ pane: TerminalPane, didCopyRedacted removed: Int) { showCopyNotice(removed: removed) }
    func pane(_ pane: TerminalPane, didChangeFindMatchCase matchCase: Bool, regex: Bool) {
        guard var value = app?.preferences else { return }
        value.findMatchCase = matchCase
        value.findUseRegex = regex
        app?.updatePreferences(value)
    }
    func paneDidDisableMultilinePasteConfirmation(_ pane: TerminalPane) {
        guard var value = app?.preferences else { return }
        value.confirmMultilinePaste = false
        app?.updatePreferences(value)
    }

    func paneWantsClose(_ pane: TerminalPane) {
        if panes.count > 1 { removePane(pane) } else { window?.close() }
    }
    func paneDidTerminate(_ pane: TerminalPane) { app?.sessionDidFinish() }
    func pane(_ pane: TerminalPane, opensTerminalIn folder: URL) { app?.openTerminal(in: folder) }
}

/// A borderless window that can take key status, so the Quick Terminal accepts typing without a title bar.
final class QuickTerminalPanel: NSPanel {
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        // NSPanel hides on deactivation by default; the app decides that itself (Settings).
        hidesOnDeactivate = false
        isFloatingPanel = true
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: Quick Terminal presentation

extension TerminalWindow {
    /// The frame the Quick Terminal occupies on `screen`: full width, 40% of the visible height, attached below the menu bar.
    static func quickTerminalFrame(on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let height = (visible.height * 0.4).rounded()
        return NSRect(x: visible.minX, y: visible.maxY - height, width: visible.width, height: height)
    }

    /// Slides the window down from above the screen edge (or fades in with Reduce Motion) and makes it key.
    func showQuickTerminal(on screen: NSScreen, completion: @escaping @MainActor () -> Void = {}) {
        guard let window else { return }
        quickTerminalGeneration += 1
        let generation = quickTerminalGeneration
        let target = Self.quickTerminalFrame(on: screen)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if window.isVisible && !quickTerminalHiding {
            window.setFrame(target, display: true)
        } else if reduceMotion {
            window.alphaValue = quickTerminalHiding ? window.alphaValue : 0
            window.setFrame(target, display: true)
        } else if !quickTerminalHiding {
            window.alphaValue = 1
            window.setFrame(target.offsetBy(dx: 0, dy: screen.frame.maxY - target.minY), display: true)
        }
        quickTerminalHiding = false
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(terminal)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            if reduceMotion { window.animator().alphaValue = 1 } else { window.animator().setFrame(target, display: true) }
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, generation == self.quickTerminalGeneration, let window = self.window else { return }
                window.alphaValue = 1
                completion()
            }
        })
    }

    /// Slides the window back up (or fades out) and orders it out. The shell keeps running.
    func hideQuickTerminal() {
        guard let window, window.isVisible, !quickTerminalHiding else { return }
        quickTerminalGeneration += 1
        let generation = quickTerminalGeneration
        quickTerminalHiding = true
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let screen = window.screen ?? NSScreen.main
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            if reduceMotion || screen == nil { window.animator().alphaValue = 0 }
            else if let screen { window.animator().setFrame(window.frame.offsetBy(dx: 0, dy: screen.frame.maxY - window.frame.minY), display: true) }
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, generation == self.quickTerminalGeneration, let window = self.window else { return }
                self.quickTerminalHiding = false
                window.orderOut(nil)
                window.alphaValue = 1
            }
        })
    }
}
