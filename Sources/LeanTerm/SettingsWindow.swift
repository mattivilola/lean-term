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
    private let preview = NSTextView()
    private let automaticChecks = NSButton(checkboxWithTitle: "Check for updates automatically", target: nil, action: nil)
    private let automaticDownloads = NSButton(checkboxWithTitle: "Download updates in the background", target: nil, action: nil)

    init(app: AppDelegate) {
        self.app = app
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: app.updates.available ? 595 : 510),
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
        let heading = NSStackView(views: [icon, NSStackView(views: [title, subtitle])])
        (heading.arrangedSubviews[1] as? NSStackView)?.orientation = .vertical
        (heading.arrangedSubviews[1] as? NSStackView)?.alignment = .leading
        heading.spacing = 14
        for control in [appearance, palette] { control.target = self; control.action = #selector(changed) }
        font.addItems(withTitles: ["Menlo", "SF Mono", "Monaco", "Courier"])
        font.target = self; font.action = #selector(changed)
        cursor.addItems(withTitles: Preferences.Cursor.allCases.map(\.title))
        cursor.target = self; cursor.action = #selector(changed)
        size.target = self; size.action = #selector(changed)
        size.isContinuous = true
        size.setAccessibilityLabel("Font size")
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        sizeLabel.widthAnchor.constraint(equalToConstant: 42).isActive = true
        let sizeRow = NSStackView(views: [size, sizeLabel]); sizeRow.spacing = 10
        size.widthAnchor.constraint(equalToConstant: 210).isActive = true
        option.target = self; option.action = #selector(changed)
        let shortcuts = NSButton(title: "Keyboard Shortcuts…", target: app, action: #selector(AppDelegate.showShortcuts(_:)))
        shortcuts.bezelStyle = .inline; shortcuts.controlSize = .small
        let keyboard = NSStackView(views: [option, shortcuts])
        keyboard.orientation = .vertical; keyboard.alignment = .leading; keyboard.spacing = 6
        var rows: [[NSView]] = [
            [NSTextField(labelWithString: "Appearance"), appearance],
            [NSTextField(labelWithString: "Palette"), palette],
            [NSTextField(labelWithString: "Font"), font],
            [NSTextField(labelWithString: "Text size"), sizeRow],
            [NSTextField(labelWithString: "Cursor"), cursor],
            [NSTextField(labelWithString: "Keyboard"), keyboard]
        ]
        if app.updates.available {
            automaticChecks.target = self; automaticChecks.action = #selector(updateSettingsChanged)
            automaticDownloads.target = self; automaticDownloads.action = #selector(updateSettingsChanged)
            let note = NSTextField(labelWithString: "Checks on launch and hourly. Installs when you quit.")
            note.font = .systemFont(ofSize: 10); note.textColor = .secondaryLabelColor
            let controls = NSStackView(views: [automaticChecks, automaticDownloads, note])
            controls.orientation = .vertical; controls.alignment = .leading; controls.spacing = 6
            rows.append([NSTextField(labelWithString: "Updates"), controls])
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 15; grid.columnSpacing = 22
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.yPlacement = .center
        preview.isEditable = false
        preview.isSelectable = false
        preview.textContainerInset = NSSize(width: 14, height: 12)
        preview.wantsLayer = true; preview.layer?.cornerRadius = 10
        preview.heightAnchor.constraint(equalToConstant: 82).isActive = true
        preview.widthAnchor.constraint(equalToConstant: 448).isActive = true
        let reset = NSButton(title: "Restore Defaults", target: self, action: #selector(resetDefaults))
        reset.bezelStyle = .inline
        let note = NSTextField(labelWithString: "Changes apply to all sessions and save automatically.")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        let bottom = NSStackView(views: [note, NSView(), reset]); bottom.spacing = 8
        let stack = NSStackView(views: [heading, grid, preview, bottom])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 22
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 30),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -30),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 26),
            bottom.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        window.center()
        surface.appearanceChanged = { [weak self] in self?.refresh() }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("Programmatic windows only") }

    func refresh() {
        guard let app else { return }
        let value = app.preferences
        appearance.selectedSegment = Preferences.Appearance.allCases.firstIndex(of: value.appearance) ?? 0
        palette.selectedSegment = Preferences.Palette.allCases.firstIndex(of: value.palette) ?? 0
        font.selectItem(withTitle: value.fontName)
        size.doubleValue = value.fontSize; sizeLabel.stringValue = "\(Int(value.fontSize)) pt"
        cursor.selectItem(withTitle: value.cursor.title)
        option.state = value.optionAsMeta ? .on : .off
        automaticChecks.state = app.updates.automaticallyChecks ? .on : .off
        automaticDownloads.state = app.updates.automaticallyDownloads ? .on : .off
        let dark = window?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let theme = TerminalTheme(palette: value.palette, dark: dark)
        preview.backgroundColor = theme.background
        preview.string = "❯ echo 'Less noise. More flow.'\nLess noise. More flow."
        preview.font = NSFont(name: value.fontName, size: min(value.fontSize, 16)) ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        preview.textColor = theme.foreground
        preview.textStorage?.addAttribute(.foregroundColor, value: theme.accent, range: NSRange(location: 0, length: 1))
    }
    @objc private func changed() {
        guard let app else { return }
        var value = app.preferences
        value.appearance = Preferences.Appearance.allCases[max(0, appearance.selectedSegment)]
        value.palette = Preferences.Palette.allCases[max(0, palette.selectedSegment)]
        value.fontName = font.titleOfSelectedItem ?? "Menlo"
        value.fontSize = size.doubleValue.rounded()
        value.cursor = Preferences.Cursor.allCases[max(0, cursor.indexOfSelectedItem)]
        value.optionAsMeta = option.state == .on
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
