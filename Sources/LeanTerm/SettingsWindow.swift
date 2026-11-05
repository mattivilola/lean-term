import AppKit
import LeanTermCore

@MainActor
final class SettingsWindow: NSWindowController {
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
    private let resources = NSButton(checkboxWithTitle: "Show CPU and memory graphs", target: nil, action: nil)
    private let activityScanner = NSButton(checkboxWithTitle: "Show running-command scanner", target: nil, action: nil)
    private let tabActivity = NSButton(checkboxWithTitle: "Mark busy and finished tabs", target: nil, action: nil)
    private let preview = NSTextView()
    private let automaticChecks = NSButton(checkboxWithTitle: "Check for updates automatically", target: nil, action: nil)
    private let automaticDownloads = NSButton(checkboxWithTitle: "Download updates in the background", target: nil, action: nil)
    private let sections = NSSegmentedControl(labels: ["Appearance", "Behavior", "Updates"], trackingMode: .selectOne, target: nil, action: nil)
    private var pages: [NSView] = []

    init(app: AppDelegate) {
        self.app = app
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 590),
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

        for button in [option, closeOnExit, quitAfterLast, resources, activityScanner, tabActivity] { button.target = self; button.action = #selector(changed) }
        let shortcuts = NSButton(title: "Keyboard Shortcuts…", target: app, action: #selector(AppDelegate.showShortcuts(_:)))
        shortcuts.bezelStyle = .inline; shortcuts.controlSize = .small
        let keyboard = Self.vertical([option, shortcuts], spacing: 6)
        let sessions = Self.vertical([closeOnExit, quitAfterLast,
            Self.note("Turn off automatic closing to review final output. Applies to future shell exits.")], spacing: 7)
        let monitoring = Self.vertical([resources,
            Self.note("Lean Term only, excluding child processes. Sampling pauses when terminal windows are hidden.")], spacing: 7)
        let activity = Self.vertical([activityScanner, tabActivity,
            Self.note("Shown while a command runs. Animation pauses for hidden windows, Reduce Motion and Low Power Mode.")], spacing: 7)
        let behaviorPage = Self.grid([
            [NSTextField(labelWithString: "Keyboard"), keyboard],
            [NSTextField(labelWithString: "Sessions"), sessions],
            [NSTextField(labelWithString: "Status bar"), monitoring],
            [NSTextField(labelWithString: "Activity"), activity]
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

        pages = [appearancePage, behaviorPage, updatesPage]
        let pageContainer = NSView()
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
        pageContainer.heightAnchor.constraint(equalToConstant: 350).isActive = true
        sections.selectedSegment = 0; sections.target = self; sections.action = #selector(sectionChanged)
        let reset = NSButton(title: "Restore Defaults", target: self, action: #selector(resetDefaults))
        reset.bezelStyle = .inline
        let note = NSTextField(labelWithString: "Changes save automatically.")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        let bottom = NSStackView(views: [note, NSView(), reset]); bottom.spacing = 8
        let stack = Self.vertical([heading, sections, pageContainer, bottom], spacing: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 30),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -30),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 26),
            pageContainer.widthAnchor.constraint(equalTo: stack.widthAnchor),
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
        closeOnExit.state = value.closeTabOnShellExit ? .on : .off
        quitAfterLast.state = value.quitAfterLastSession ? .on : .off
        resources.state = value.showResourceUsage ? .on : .off
        activityScanner.state = value.showActivityScanner ? .on : .off
        tabActivity.state = value.showTabActivity ? .on : .off
        automaticChecks.state = app.updates.automaticallyChecks ? .on : .off
        automaticDownloads.state = app.updates.automaticallyDownloads ? .on : .off
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
        value.closeTabOnShellExit = closeOnExit.state == .on
        value.quitAfterLastSession = quitAfterLast.state == .on
        value.showResourceUsage = resources.state == .on
        value.showActivityScanner = activityScanner.state == .on
        value.showTabActivity = tabActivity.state == .on
        app.updatePreferences(value)
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
