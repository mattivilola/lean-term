import AppKit

/// Field editor of the find field. The first responder while typing is this text view, which would
/// otherwise swallow Find Next / Find Previous / Done from the Edit menu instead of the pane.
@MainActor
private final class FindFieldEditor: NSTextView {
    var onFind: ((LeanTerminalView.FindCommand) -> Void)?

    private func forward(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let command = LeanTerminalView.FindCommand(tag: item.tag) else { return }
        onFind?(command)
    }
    override func performTextFinderAction(_ sender: Any?) { forward(sender) }
    override func performFindPanelAction(_ sender: Any?) { forward(sender) }
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(performTextFinderAction(_:)) || item.action == #selector(performFindPanelAction(_:)) {
            return LeanTerminalView.FindCommand(tag: item.tag) != nil
        }
        return super.validateUserInterfaceItem(item)
    }
}

@MainActor
private final class FindSearchFieldCell: NSSearchFieldCell {
    private lazy var editor: FindFieldEditor = {
        let editor = FindFieldEditor()
        editor.isFieldEditor = true
        editor.onFind = { [weak self] in self?.onFind?($0) }
        return editor
    }()
    var onFind: ((LeanTerminalView.FindCommand) -> Void)?

    override func fieldEditor(for controlView: NSView) -> NSTextView? { editor }
}

/// The compact find bar at the top of a pane: query field, "Aa" (match case) and ".*" (regular expression)
/// toggles, a match count, previous/next and Done. It only reports what the user did; `FindController` searches.
@MainActor
final class FindBarView: NSView, NSSearchFieldDelegate {
    static let height: CGFloat = 30

    var onQueryChanged: (() -> Void)?
    var onOptionsChanged: (() -> Void)?
    var onCommand: ((LeanTerminalView.FindCommand) -> Void)?

    private let field = NSSearchField()
    private let matchCase = NSButton(title: "Aa", target: nil, action: nil)
    private let regex = NSButton(title: ".*", target: nil, action: nil)
    private let count = NSTextField(labelWithString: "")
    private let previous = NSButton()
    private let next = NSButton()
    private let done = NSButton(title: "Done", target: nil, action: nil)
    private let separator = CALayer()

    var query: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }
    var matchesCase: Bool { matchCase.state == .on }
    var usesRegex: Bool { regex.state == .on }

    func setOptions(matchCase: Bool, regex: Bool) {
        self.matchCase.state = matchCase ? .on : .off
        self.regex.state = regex ? .on : .off
    }

    func setCount(_ text: String, invalid: Bool) {
        count.stringValue = text
        count.textColor = invalid ? .systemRed : .secondaryLabelColor
        count.setAccessibilityLabel(text.isEmpty ? "Matches" : text)
    }

    func applyTheme(_ theme: TerminalTheme) {
        layer?.backgroundColor = (theme.background.blended(withFraction: 0.07, of: theme.foreground) ?? theme.background).cgColor
        separator.backgroundColor = theme.foreground.withAlphaComponent(0.14).cgColor
    }

    /// Puts the caret in the field with the whole query selected, ready to type over.
    func focusField() {
        window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
        layer?.addSublayer(separator)
        translatesAutoresizingMaskIntoConstraints = false

        field.cell = FindSearchFieldCell(textCell: "")
        (field.cell as? FindSearchFieldCell)?.onFind = { [weak self] in self?.onCommand?($0) }
        field.cell?.isScrollable = true
        field.cell?.usesSingleLineMode = true
        field.placeholderString = "Find"
        field.controlSize = .small
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.setAccessibilityLabel("Find in terminal")
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for (button, tip) in [(matchCase, "Match case"), (regex, "Regular expression")] {
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .texturedRounded
            button.controlSize = .small
            button.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
            button.toolTip = tip
            button.setAccessibilityLabel(tip)
            button.target = self
            button.action = #selector(optionChanged)
        }
        count.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        count.alignment = .right
        count.lineBreakMode = .byTruncatingHead
        count.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        for (button, symbol, tip, action) in [(previous, "chevron.up", "Previous match", #selector(previousTapped)),
                                              (next, "chevron.down", "Next match", #selector(nextTapped))] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            button.bezelStyle = .texturedRounded
            button.controlSize = .small
            button.toolTip = tip
            button.target = self
            button.action = action
        }
        done.bezelStyle = .texturedRounded
        done.controlSize = .small
        done.target = self
        done.action = #selector(doneTapped)

        let stack = NSStackView(views: [field, matchCase, regex, count, previous, next, done])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            count.widthAnchor.constraint(equalToConstant: 84)
        ])
    }

    required init?(coder: NSCoder) { fatalError("Programmatic views only") }

    override func layout() {
        super.layout()
        separator.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1)
    }

    @objc private func optionChanged() { onOptionsChanged?() }
    @objc private func previousTapped() { onCommand?(.previous) }
    @objc private func nextTapped() { onCommand?(.next) }
    @objc private func doneTapped() { onCommand?(.hide) }

    func controlTextDidChange(_ notification: Notification) { onQueryChanged?() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            onCommand?(.hide)
        case #selector(NSResponder.insertNewline(_:)):
            onCommand?(NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? .previous : .next)
        default:
            return false
        }
        return true
    }
}
