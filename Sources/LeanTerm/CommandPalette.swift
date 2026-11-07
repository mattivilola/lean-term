import AppKit
import LeanTermCore

struct CommandPaletteEntry {
    let title: String
    let secondary: String
    let shortcut: String
    let run: @MainActor () -> Void
}

/// Quick-open panel over a terminal window: filters menu commands and tabs, runs the chosen one.
/// Built when opened and released when closed, so it costs nothing while closed.
@MainActor
final class CommandPalette: NSObject, NSWindowDelegate, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private static let width: CGFloat = 520
    private static let rowHeight: CGFloat = 30
    private static let visibleRows = 10
    private static let listInset: CGFloat = 4
    private static let fieldHeight: CGFloat = 52

    var didRun: ((String) -> Void)?
    var didClose: (() -> Void)?

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    private final class RowView: NSTableRowView {
        override var isEmphasized: Bool { get { true } set {} }
        override func drawSelection(in dirtyRect: NSRect) {
            guard isSelected else { return }
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
    }

    private final class Cell: NSTableCellView {
        let title = NSTextField(labelWithString: "")
        let secondary = NSTextField(labelWithString: "")
        let shortcut = NSTextField(labelWithString: "")
        override init(frame: NSRect) {
            super.init(frame: frame)
            title.font = .systemFont(ofSize: 13)
            secondary.font = .systemFont(ofSize: 11)
            shortcut.font = .systemFont(ofSize: 12)
            for label in [title, secondary, shortcut] { label.lineBreakMode = .byTruncatingTail }
            title.setContentCompressionResistancePriority(.init(751), for: .horizontal)
            title.setContentHuggingPriority(.init(750), for: .horizontal)
            secondary.setContentHuggingPriority(.init(1), for: .horizontal)
            secondary.setContentCompressionResistancePriority(.init(250), for: .horizontal)
            shortcut.setContentHuggingPriority(.init(900), for: .horizontal)
            shortcut.setContentCompressionResistancePriority(.required, for: .horizontal)
            let stack = NSStackView(views: [title, secondary, shortcut])
            stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = 8
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                stack.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
            applyColors()
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override var backgroundStyle: NSView.BackgroundStyle { didSet { applyColors() } }
        private func applyColors() {
            let selected = backgroundStyle == .emphasized
            title.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
            secondary.textColor = selected ? .alternateSelectedControlTextColor.withAlphaComponent(0.75) : .secondaryLabelColor
            shortcut.textColor = secondary.textColor
        }
    }

    private let entries: [CommandPaletteEntry]
    private let recents: [String]
    private weak var parent: NSWindow?
    private var panel: Panel?
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let separator = NSBox()
    private let empty = NSTextField(labelWithString: "No matching commands")
    private var results: [CommandPaletteEntry] = []
    private var top: CGFloat = 0

    init(entries: [CommandPaletteEntry], recents: [String], parent: NSWindow) {
        self.entries = entries; self.recents = recents; self.parent = parent
        super.init()
    }

    /// Enabled, actionable menu items below `menu`, validated now, with their menu path as secondary text.
    static func menuEntries(from menu: NSMenu?, skipping: Set<Selector>, excludedMenus: [NSMenu?]) -> [CommandPaletteEntry] {
        var result: [CommandPaletteEntry] = []
        func visit(_ menu: NSMenu, path: [String]) {
            menu.update()
            for item in menu.items where !item.isSeparatorItem && !item.isHidden {
                if let submenu = item.submenu {
                    if excludedMenus.contains(where: { $0 === submenu }) || submenu.title == "Open Recent" { continue }
                    visit(submenu, path: path + [submenu.title.isEmpty ? item.title : submenu.title])
                    continue
                }
                guard let action = item.action, item.isEnabled, !item.title.isEmpty, !skipping.contains(action),
                      action != Selector(("_activateWindow:")), !(item.representedObject is NSWindow) else { continue }
                var shortcut = ""
                if !item.keyEquivalent.isEmpty {
                    shortcut = ShortcutBinding(item.keyEquivalent, ShortcutModifiers(eventFlags: item.keyEquivalentModifierMask)).display
                }
                result.append(CommandPaletteEntry(title: item.title, secondary: path.joined(separator: " › "), shortcut: shortcut) {
                    NSApp.sendAction(action, to: item.target, from: item)
                })
            }
        }
        if let menu { visit(menu, path: []) }
        return result
    }

    var isOpen: Bool { panel != nil }

    func show() {
        guard let parent, panel == nil else { return }
        let panel = Panel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 100),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.setAccessibilityLabel("Command Palette")
        self.panel = panel

        let effect = NSVisualEffectView()
        effect.material = .menu; effect.blendingMode = .behindWindow; effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12; effect.layer?.cornerCurve = .continuous; effect.layer?.masksToBounds = true
        panel.contentView = effect

        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.font = .systemFont(ofSize: 18)
        field.placeholderString = "Type a command or tab name"
        field.setAccessibilityLabel("Search commands")
        field.delegate = self
        field.cell?.sendsActionOnEndEditing = false

        let column = NSTableColumn(identifier: .init("command"))
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.refusesFirstResponder = true
        table.dataSource = self; table.delegate = self
        table.target = self; table.action = #selector(rowClicked)
        scroll.documentView = table
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: Self.listInset, left: 0, bottom: Self.listInset, right: 0)

        separator.boxType = .separator
        empty.font = .systemFont(ofSize: 13); empty.textColor = .secondaryLabelColor; empty.alignment = .center
        for view in [field, separator, scroll, empty] { effect.addSubview(view) }

        let size = min(Self.width, max(parent.frame.width - 40, 280))
        let frame = parent.frame
        top = frame.maxY - 80
        results = ordered(for: "")
        table.reloadData()
        if !results.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        resize(width: size, x: frame.midX - size / 2)
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    /// Closes the palette. `restoreFocus` returns key status to the terminal window.
    func close(restoreFocus: Bool) {
        guard let panel else { return }
        self.panel = nil
        panel.delegate = nil
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        if restoreFocus { parent?.makeKeyAndOrderFront(nil) }
        didClose?()
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking outside: close without stealing focus from wherever the user went.
        close(restoreFocus: false)
    }

    private func run(_ entry: CommandPaletteEntry) {
        let title = entry.title
        close(restoreFocus: true)
        didRun?(title)
        DispatchQueue.main.async { entry.run() }
    }

    private func ordered(for query: String) -> [CommandPaletteEntry] {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            let recent = recents.compactMap { title in entries.first { $0.title == title } }
            let recentTitles = Set(recent.map(\.title))
            return recent + entries.filter { !recentTitles.contains($0.title) }
        }
        return entries.enumerated().compactMap { index, entry in
            CommandMatcher.score(query: query, candidate: entry.title).map { (index, entry, $0) }
        }.sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.0 < $1.0 }.map(\.1)
    }

    private func resize(width: CGFloat? = nil, x: CGFloat? = nil) {
        guard let panel else { return }
        let rows = min(results.count, Self.visibleRows)
        let list = results.isEmpty ? 44 : CGFloat(rows) * Self.rowHeight + 2 * Self.listInset
        let height = Self.fieldHeight + 1 + list
        let w = width ?? panel.frame.width
        panel.setFrame(NSRect(x: x ?? panel.frame.minX, y: top - height, width: w, height: height), display: true)
        scroll.frame = NSRect(x: 0, y: 0, width: w, height: list)
        scroll.isHidden = results.isEmpty
        empty.isHidden = !results.isEmpty
        empty.frame = NSRect(x: 0, y: (list - 18) / 2, width: w, height: 18)
        separator.frame = NSRect(x: 0, y: list, width: w, height: 1)
        field.frame = NSRect(x: 18, y: list + 1 + (Self.fieldHeight - 24) / 2, width: w - 36, height: 24)
        table.tableColumns.first?.width = w
    }

    func controlTextDidChange(_ obj: Notification) {
        results = ordered(for: field.stringValue)
        table.reloadData()
        if !results.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false); table.scrollRowToVisible(0) }
        resize()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): moveSelection(by: -1)
        case #selector(NSResponder.moveDown(_:)): moveSelection(by: 1)
        case #selector(NSResponder.insertNewline(_:)):
            if results.indices.contains(table.selectedRow) { run(results[table.selectedRow]) }
        case #selector(NSResponder.cancelOperation(_:)): close(restoreFocus: true)
        default: return false
        }
        return true
    }

    private func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        let next = min(max(table.selectedRow + delta, 0), results.count - 1)
        table.selectRowIndexes([next], byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    @objc private func rowClicked() {
        guard results.indices.contains(table.clickedRow) else { return }
        run(results[table.clickedRow])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("commandCell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? Cell ?? Cell(frame: .zero)
        cell.identifier = id
        let entry = results[row]
        cell.title.stringValue = entry.title
        cell.secondary.stringValue = entry.secondary
        cell.shortcut.stringValue = entry.shortcut
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { RowView() }
}
