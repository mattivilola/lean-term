import AppKit
import UniformTypeIdentifiers
import LeanTermCore

@MainActor
final class SettingsWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private weak var app: AppDelegate?
    private let appearance = NSSegmentedControl(labels: ["System", "Light", "Dark"], trackingMode: .selectOne, target: nil, action: nil)
    private let palette = NSSegmentedControl(labels: ["Forest", "Graphite"], trackingMode: .selectOne, target: nil, action: nil)
    private let font = NSPopUpButton()
    private let size = NSSlider(value: 13, minValue: 10, maxValue: 32, target: nil, action: nil)
    private let sizeLabel = NSTextField(labelWithString: "13 pt")
    private let cursor = NSPopUpButton()
    private let option = NSButton(checkboxWithTitle: "Use Option as Meta", target: nil, action: nil)
    private let closeOnExit = NSButton(checkboxWithTitle: "Close tab when shell exits", target: nil, action: nil)
    private let quitAfterLast = NSButton(checkboxWithTitle: "Quit when last tab/window closes", target: nil, action: nil)
    private let redactCopies = NSButton(checkboxWithTitle: "Remove sensitive data when copying", target: nil, action: nil)
    private let confirmPaste = NSButton(checkboxWithTitle: "Confirm multi-line paste without bracketed paste", target: nil, action: nil)
    private let fileOpener = NSPopUpButton()
    private let getLeanVSCode = NSButton(title: "Get Lean VS Code…", target: nil, action: nil)
    private let makeDefault = NSButton(title: "Make Lean Term the Default Terminal", target: nil, action: nil)
    private let defaultStatus = NSTextField(labelWithString: "")
    private let restore = NSButton(checkboxWithTitle: "Reopen windows and tabs on launch", target: nil, action: nil)
    private let resources = NSButton(checkboxWithTitle: "Show CPU and memory graphs", target: nil, action: nil)
    private let activityScanner = NSButton(checkboxWithTitle: "Show running-command scanner", target: nil, action: nil)
    private let tabActivity = NSButton(checkboxWithTitle: "Mark busy and finished tabs", target: nil, action: nil)
    private let notifications = NSButton(checkboxWithTitle: "Show notifications and Dock badge", target: nil, action: nil)
    private let sessionMarks = NSButton(checkboxWithTitle: "Mark remote and root sessions", target: nil, action: nil)
    private let preview = NSTextView()
    private let automaticChecks = NSButton(checkboxWithTitle: "Check for updates automatically", target: nil, action: nil)
    private let automaticDownloads = NSButton(checkboxWithTitle: "Download updates in the background", target: nil, action: nil)
    private let sections = NSSegmentedControl(labels: ["Appearance", "Behavior", "Updates", "Hosts"], trackingMode: .selectOne, target: nil, action: nil)
    private let hosts = NSTableView()
    private let hostEdit = NSSegmentedControl(images: [NSImage(named: NSImage.addTemplateName) ?? NSImage(),
                                                         NSImage(named: NSImage.removeTemplateName) ?? NSImage()],
                                              trackingMode: .momentary, target: nil, action: nil)
    /// The rules the table currently shows, so refresh() only reloads for outside changes.
    private var shownRules: [HostColorRule] = []
    private var pages: [NSView] = []

    init(app: AppDelegate) {
        self.app = app
        let height = min(780, (NSScreen.main?.visibleFrame.height ?? 860) - 80)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: height),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        let surface = TerminalSurface()
        window.contentView = surface
        let icon = NSImageView(image: NSImage(named: NSImage.applicationIconName) ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 48).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 48).isActive = true
        let title = NSTextField(labelWithString: "Your terminal, your way.")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "A few good defaults. Make them yours.")
        subtitle.textColor = .secondaryLabelColor
        let names = Self.vertical([title, subtitle], spacing: 4)
        let heading = NSStackView(views: [icon, names]); heading.spacing = 14

        for control in [appearance, palette] { control.target = self; control.action = #selector(changed) }
        font.addItems(withTitles: ["SF Mono", "Menlo", "Monaco", "Courier"])
        font.target = self; font.action = #selector(changed)
        cursor.addItems(withTitles: Preferences.Cursor.allCases.map(\.title))
        cursor.target = self; cursor.action = #selector(changed)
        size.target = self; size.action = #selector(changed); size.isContinuous = true
        size.setAccessibilityLabel("Font size")
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        sizeLabel.widthAnchor.constraint(equalToConstant: 42).isActive = true
        let sizeRow = NSStackView(views: [size, sizeLabel]); sizeRow.spacing = 10
        size.widthAnchor.constraint(equalToConstant: 210).isActive = true
        let appearanceGrid = Self.grid([
            [NSTextField(labelWithString: "Appearance"), appearance],
            [NSTextField(labelWithString: "Palette"), palette],
            [NSTextField(labelWithString: "Font"), font],
            [NSTextField(labelWithString: "Text size"), sizeRow],
            [NSTextField(labelWithString: "Cursor"), cursor]
        ])
        preview.isEditable = false; preview.isSelectable = false
        preview.textContainerInset = NSSize(width: 14, height: 12)
        preview.wantsLayer = true; preview.layer?.cornerRadius = 10
        preview.heightAnchor.constraint(equalToConstant: 82).isActive = true
        preview.widthAnchor.constraint(equalToConstant: 448).isActive = true
        let appearancePage = Self.vertical([appearanceGrid, preview], spacing: 22)

        for button in [option, confirmPaste, redactCopies, closeOnExit, quitAfterLast, restore, resources, activityScanner, tabActivity, sessionMarks, notifications] { button.target = self; button.action = #selector(changed) }
        let shortcuts = NSButton(title: "Keyboard Shortcuts…", target: app, action: #selector(AppDelegate.showShortcuts(_:)))
        shortcuts.bezelStyle = .inline; shortcuts.controlSize = .small
        let keyboard = Self.vertical([option, shortcuts], spacing: 6)
        let sessions = Self.vertical([closeOnExit, quitAfterLast, restore,
            Self.note("Reopens fresh shells in saved folders, including tab names. Running commands are not restored.")], spacing: 7)
        let monitoring = Self.vertical([resources,
            Self.note("Lean Term only, excluding child processes. Sampling pauses when terminal windows are hidden.")], spacing: 7)
        let activity = Self.vertical([activityScanner, tabActivity, sessionMarks,
            Self.note("Shown while a command runs or a session is remote or root. Animation pauses for hidden windows, Reduce Motion and Low Power Mode.")], spacing: 7)
        let notifying = Self.vertical([notifications,
            Self.note("Notifies when a command of 10 s or more finishes. Badges missed completions and bells while you are elsewhere.")], spacing: 7)
        makeDefault.target = self; makeDefault.action = #selector(makeDefaultTerminal)
        makeDefault.bezelStyle = .rounded; makeDefault.controlSize = .small
        defaultStatus.font = .systemFont(ofSize: 11); defaultStatus.textColor = .secondaryLabelColor
        let defaultTerminal = Self.vertical([makeDefault, defaultStatus,
            Self.note("Finder: right-click a folder › Services › New Lean Term Tab Here (enable it in System Settings › Keyboard › Keyboard Shortcuts › Services if missing). Lean VS Code: set \"terminal.external.osxExec\" to \"Lean Term.app\".")], spacing: 7)
        fileOpener.target = self; fileOpener.action = #selector(fileOpenerChosen)
        fileOpener.setAccessibilityLabel("Open files with")
        getLeanVSCode.target = self; getLeanVSCode.action = #selector(openLeanVSCodeSite)
        getLeanVSCode.bezelStyle = .inline; getLeanVSCode.controlSize = .small
        let openFiles = Self.vertical([NSStackView(views: [fileOpener, getLeanVSCode]),
            Self.note("⌘-click a path in the terminal to open it; ⌘-click a folder to cd there, ⌘⇧-click for a new tab.")], spacing: 7)
        let behaviorPage = Self.grid([
            [NSTextField(labelWithString: "Keyboard"), keyboard],
            [NSTextField(labelWithString: "Pasting"), confirmPaste],
            [NSTextField(labelWithString: "Copying"), Self.vertical([redactCopies,
                Self.note("Masks passwords, API keys, tokens, private keys, card numbers, IBANs, personal identity numbers and email addresses as [REMOVED:…]. ⌥⌘C always copies without them.")], spacing: 7)],
            [NSTextField(labelWithString: "Open files with"), openFiles],
            [NSTextField(labelWithString: "Sessions"), sessions],
            [NSTextField(labelWithString: "Status bar"), monitoring],
            [NSTextField(labelWithString: "Activity"), activity],
            [NSTextField(labelWithString: "Notifications"), notifying],
            [NSTextField(labelWithString: "Default terminal"), defaultTerminal]
        ])
        let updatesPage: NSView
        if app.updates.available {
            for control in [automaticChecks, automaticDownloads] { control.target = self; control.action = #selector(updateSettingsChanged) }
            let checkNow = NSButton(title: "Check for Updates…", target: app.updates, action: #selector(Updates.checkForUpdates(_:)))
            checkNow.bezelStyle = .rounded; checkNow.controlSize = .small
            updatesPage = Self.vertical([automaticChecks, automaticDownloads,
                Self.note("Checks on launch and about hourly. Installation respects your session-close confirmation."), checkNow], spacing: 14)
        } else {
            updatesPage = Self.vertical([NSTextField(labelWithString: "Updates are available in installed release builds.")], spacing: 14)
        }

        let hostsPage = makeHostsPage()
        pages = [appearancePage, behaviorPage, updatesPage, hostsPage]
        let pageContainer = SettingsDocument()
        pageContainer.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = pageContainer
        for (index, page) in pages.enumerated() {
            page.translatesAutoresizingMaskIntoConstraints = false
            page.isHidden = index != 0
            pageContainer.addSubview(page)
            NSLayoutConstraint.activate([
                page.leadingAnchor.constraint(equalTo: pageContainer.leadingAnchor),
                page.topAnchor.constraint(equalTo: pageContainer.topAnchor),
                page.trailingAnchor.constraint(lessThanOrEqualTo: pageContainer.trailingAnchor)
            ])
        }
        NSLayoutConstraint.activate([
            pageContainer.heightAnchor.constraint(equalToConstant: 700),
            pageContainer.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: height - 222)
        ])
        sections.selectedSegment = 0; sections.target = self; sections.action = #selector(sectionChanged)
        let reset = NSButton(title: "Restore Defaults", target: self, action: #selector(resetDefaults))
        reset.bezelStyle = .inline
        let note = NSTextField(labelWithString: "Changes save automatically.")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        let bottom = NSStackView(views: [note, NSView(), reset]); bottom.spacing = 8
        let stack = Self.vertical([heading, sections, scroll, bottom], spacing: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 30),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -30),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 26),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bottom.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        window.center()
        surface.appearanceChanged = { [weak self] in self?.refresh() }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("Programmatic windows only") }

    private static func vertical(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing
        return stack
    }
    private static func grid(_ rows: [[NSView]]) -> NSGridView {
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 15; grid.columnSpacing = 22
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.yPlacement = .center
        return grid
    }
    private static func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: 290).isActive = true
        return label
    }
    private func makeHostsPage() -> NSView {
        for (identifier, title, width) in [("pattern", "Host pattern", 290.0), ("color", "Colour", 140.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title; column.width = width; column.minWidth = width; column.maxWidth = width
            hosts.addTableColumn(column)
        }
        hosts.dataSource = self; hosts.delegate = self
        hosts.rowHeight = 24
        hosts.usesAlternatingRowBackgroundColors = true
        hosts.allowsMultipleSelection = false
        hosts.setAccessibilityLabel("Host colour rules")
        let scroll = NSScrollView()
        scroll.documentView = hosts
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 448).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 6 * 24 + 28).isActive = true
        hostEdit.target = self; hostEdit.action = #selector(hostRulesEdited)
        hostEdit.segmentStyle = .smallSquare
        hostEdit.setWidth(28, forSegment: 0); hostEdit.setWidth(28, forSegment: 1)
        hostEdit.setEnabled(false, forSegment: 1)
        hostEdit.setToolTip("Add rule", forSegment: 0); hostEdit.setToolTip("Remove rule", forSegment: 1)
        let note = Self.note("Remote tabs whose host matches show its colour in the tab and as a line above the terminal. Use * as a wildcard, e.g. prod-*. The first match wins.")
        note.widthAnchor.constraint(equalToConstant: 448).isActive = true
        return Self.vertical([scroll, hostEdit, note], spacing: 10)
    }

    private func reloadHosts(_ rules: [HostColorRule]) {
        shownRules = rules
        hosts.reloadData()
        hostEdit.setEnabled(hosts.selectedRow >= 0, forSegment: 1)
    }

    private func saveHostRules(_ rules: [HostColorRule]) {
        guard let app else { return }
        shownRules = rules
        var value = app.preferences
        value.hostColorRules = rules
        app.updatePreferences(value)
    }

    @objc private func hostRulesEdited() {
        var rules = shownRules
        if hostEdit.selectedSegment == 0 {
            rules.append(HostColorRule(pattern: "", color: .red))
            saveHostRules(rules)
            reloadHosts(rules)
            hosts.selectRowIndexes(IndexSet(integer: rules.count - 1), byExtendingSelection: false)
            hosts.scrollRowToVisible(rules.count - 1)
            hosts.editColumn(0, row: rules.count - 1, with: nil, select: true)
        } else if hosts.selectedRow >= 0 {
            let row = hosts.selectedRow
            rules.remove(at: row)
            saveHostRules(rules)
            reloadHosts(rules)
            if !rules.isEmpty { hosts.selectRowIndexes(IndexSet(integer: min(row, rules.count - 1)), byExtendingSelection: false) }
            hostEdit.setEnabled(hosts.selectedRow >= 0, forSegment: 1)
        }
    }

    @objc private func hostColorChosen(_ sender: NSPopUpButton) {
        let row = hosts.row(for: sender)
        guard shownRules.indices.contains(row), HostColor.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        var rules = shownRules
        rules[row].color = HostColor.allCases[sender.indexOfSelectedItem]
        saveHostRules(rules)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        let row = hosts.row(for: field)
        guard shownRules.indices.contains(row), shownRules[row].pattern != field.stringValue else { return }
        var rules = shownRules
        rules[row].pattern = field.stringValue
        saveHostRules(rules)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shownRules.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard shownRules.indices.contains(row) else { return nil }
        if tableColumn?.identifier.rawValue == "color" {
            let popUp = NSPopUpButton()
            popUp.controlSize = .small
            popUp.addItems(withTitles: HostColor.allCases.map(\.title))
            popUp.selectItem(at: HostColor.allCases.firstIndex(of: shownRules[row].color) ?? 0)
            popUp.target = self; popUp.action = #selector(hostColorChosen(_:))
            return popUp
        }
        let field = NSTextField(string: shownRules[row].pattern)
        field.isBordered = false; field.drawsBackground = false
        field.isEditable = true
        field.placeholderString = "prod-*"
        field.delegate = self
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        hostEdit.setEnabled(hosts.selectedRow >= 0, forSegment: 1)
    }

    @objc private func sectionChanged() {
        for (index, page) in pages.enumerated() { page.isHidden = index != sections.selectedSegment }
    }
    func refresh() {
        guard let app else { return }
        let value = app.preferences
        appearance.selectedSegment = Preferences.Appearance.allCases.firstIndex(of: value.appearance) ?? 0
        palette.selectedSegment = Preferences.Palette.allCases.firstIndex(of: value.palette) ?? 0
        font.selectItem(withTitle: value.fontName)
        size.doubleValue = value.fontSize; sizeLabel.stringValue = "\(Int(value.fontSize)) pt"
        cursor.selectItem(withTitle: value.cursor.title)
        option.state = value.optionAsMeta ? .on : .off
        confirmPaste.state = value.confirmMultilinePaste ? .on : .off
        redactCopies.state = value.redactCopies ? .on : .off
        closeOnExit.state = value.closeTabOnShellExit ? .on : .off
        quitAfterLast.state = value.quitAfterLastSession ? .on : .off
        restore.state = value.restoreSessions ? .on : .off
        resources.state = value.showResourceUsage ? .on : .off
        activityScanner.state = value.showActivityScanner ? .on : .off
        tabActivity.state = value.showTabActivity ? .on : .off
        sessionMarks.state = value.showSessionMarks ? .on : .off
        notifications.state = value.notifyInBackground ? .on : .off
        if value.hostColorRules != shownRules, hosts.editedRow < 0 { reloadHosts(value.hostColorRules) }
        automaticChecks.state = app.updates.automaticallyChecks ? .on : .off
        automaticDownloads.state = app.updates.automaticallyDownloads ? .on : .off
        refreshFileOpener(value.fileOpener)
        refreshDefaultTerminal()
        let dark = window?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let theme = TerminalTheme(palette: value.palette, dark: dark)
        preview.backgroundColor = theme.background
        preview.string = "❯ echo 'Less noise. More flow.'\nLess noise. More flow."
        preview.font = TerminalFont.make(name: value.fontName, size: min(value.fontSize, 16))
        preview.textColor = theme.foreground
        preview.textStorage?.addAttribute(.foregroundColor, value: theme.accent, range: NSRange(location: 0, length: 1))
    }
    @objc private func changed() {
        guard let app else { return }
        var value = app.preferences
        value.appearance = Preferences.Appearance.allCases[max(0, appearance.selectedSegment)]
        value.palette = Preferences.Palette.allCases[max(0, palette.selectedSegment)]
        value.fontName = font.titleOfSelectedItem ?? "SF Mono"
        value.fontSize = size.doubleValue.rounded()
        value.cursor = Preferences.Cursor.allCases[max(0, cursor.indexOfSelectedItem)]
        value.optionAsMeta = option.state == .on
        value.confirmMultilinePaste = confirmPaste.state == .on
        value.redactCopies = redactCopies.state == .on
        value.closeTabOnShellExit = closeOnExit.state == .on
        value.quitAfterLastSession = quitAfterLast.state == .on
        value.restoreSessions = restore.state == .on
        value.showResourceUsage = resources.state == .on
        value.showActivityScanner = activityScanner.state == .on
        value.showTabActivity = tabActivity.state == .on
        value.showSessionMarks = sessionMarks.state == .on
        value.notifyInBackground = notifications.state == .on
        app.updatePreferences(value)
    }
    private static let leanVSCodeTag = 0, systemTag = 1, appTag = 2, otherTag = 3

    /// Rebuilds the popup from the saved choice, since the installed state and the chosen app's name can change.
    private func refreshFileOpener(_ choice: Preferences.FileOpenerChoice) {
        let installed = FileOpener.leanVSCodeURL != nil
        fileOpener.removeAllItems()
        for (title, tag) in [(installed ? "Lean VS Code (recommended)" : "Lean VS Code (not installed)", Self.leanVSCodeTag),
                             ("Default app for the file type", Self.systemTag)] {
            fileOpener.addItem(withTitle: title); fileOpener.lastItem?.tag = tag
        }
        if case .app(let identifier) = choice {
            let name = FileOpener.applicationURL(for: identifier).map(FileOpener.displayName(ofApplicationAt:)) ?? identifier
            fileOpener.addItem(withTitle: name); fileOpener.lastItem?.tag = Self.appTag
        }
        fileOpener.addItem(withTitle: "Other app…"); fileOpener.lastItem?.tag = Self.otherTag
        switch choice {
        case .leanVSCode: fileOpener.selectItem(withTag: Self.leanVSCodeTag)
        case .system: fileOpener.selectItem(withTag: Self.systemTag)
        case .app: fileOpener.selectItem(withTag: Self.appTag)
        }
        getLeanVSCode.isHidden = installed
    }
    @objc private func fileOpenerChosen() {
        guard let app else { return }
        var value = app.preferences
        switch fileOpener.selectedItem?.tag {
        case Self.leanVSCodeTag: value.fileOpener = .leanVSCode
        case Self.systemTag: value.fileOpener = .system
        case Self.otherTag:
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.application]
            panel.allowsMultipleSelection = false
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.prompt = "Choose"
            if panel.runModal() == .OK, let url = panel.url { value.fileOpener = .app(FileOpener.identifier(forApplicationAt: url)) }
        default: return
        }
        app.updatePreferences(value)
        refreshFileOpener(app.preferences.fileOpener)
    }
    @objc private func openLeanVSCodeSite() { NSWorkspace.shared.open(FileOpener.leanVSCodeSite) }
    private static let scriptType = UTType("com.apple.terminal.shell-script")
    private static let sshProbe = URL(string: "ssh://example.com")!

    private func refreshDefaultTerminal() {
        let own = Bundle.main.bundleURL.standardizedFileURL
        let workspace = NSWorkspace.shared
        let scripts = Self.scriptType.flatMap { workspace.urlForApplication(toOpen: $0) }?.standardizedFileURL == own
        let ssh = workspace.urlForApplication(toOpen: Self.sshProbe)?.standardizedFileURL == own
        defaultStatus.stringValue = scripts && ssh ? "Lean Term opens shell scripts and ssh links"
            : (scripts ? "Another app opens ssh links" : "Another app opens shell scripts")
        makeDefault.isEnabled = !(scripts && ssh)
    }
    /// The only place a default-app change is requested; macOS may ask the user to confirm.
    @objc private func makeDefaultTerminal() {
        let appURL = Bundle.main.bundleURL
        makeDefault.isEnabled = false
        Task { @MainActor in
            do {
                if let type = Self.scriptType { try await NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type) }
                try await NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: "ssh")
            } catch {
                let alert = NSAlert(error: error)
                if let window { alert.beginSheetModal(for: window, completionHandler: nil) } else { alert.runModal() }
            }
            refreshDefaultTerminal()
        }
    }
    @objc private func updateSettingsChanged() {
        app?.updates.automaticallyChecks = automaticChecks.state == .on
        app?.updates.automaticallyDownloads = automaticDownloads.state == .on
    }
    @objc private func resetDefaults() {
        app?.updates.restoreDefaults()
        app?.updatePreferences(Preferences())
        refresh()
    }
}

private final class SettingsDocument: NSView {
    override var isFlipped: Bool { true }
}
