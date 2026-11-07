import AppKit
import LeanTermCore

extension ShortcutModifiers {
    var eventFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.command) { flags.insert(.command) }
        if contains(.shift) { flags.insert(.shift) }
        if contains(.option) { flags.insert(.option) }
        if contains(.control) { flags.insert(.control) }
        return flags
    }
    init(eventFlags: NSEvent.ModifierFlags) {
        var value: Self = []
        if eventFlags.contains(.command) { value.insert(.command) }
        if eventFlags.contains(.shift) { value.insert(.shift) }
        if eventFlags.contains(.option) { value.insert(.option) }
        if eventFlags.contains(.control) { value.insert(.control) }
        self = value
    }
}

/// Ask AppKit to match the real event against inert copies of menu bindings.
/// This detects layout-dependent punctuation aliases without executing commands.
@MainActor
final class ShortcutProbe: NSObject {
    private var match: String?
    static func conflict(event: NSEvent, excluding action: ShortcutAction) -> String? {
        let probe = ShortcutProbe()
        let menu = NSMenu(); menu.autoenablesItems = false
        func copyBindings(_ original: NSMenu) {
            for item in original.items {
                if let submenu = item.submenu { copyBindings(submenu) }
                guard !item.keyEquivalent.isEmpty,
                      item.representedObject as? String != "shortcut:" + action.rawValue else { continue }
                let copy = NSMenuItem(title: item.title, action: #selector(hit(_:)), keyEquivalent: item.keyEquivalent)
                copy.keyEquivalentModifierMask = item.keyEquivalentModifierMask
                copy.target = probe
                menu.addItem(copy)
            }
        }
        if let main = NSApp.mainMenu { copyBindings(main) }
        _ = menu.performKeyEquivalent(with: event)
        return probe.match
    }
    @objc private func hit(_ sender: NSMenuItem) { match = sender.title.replacingOccurrences(of: "…", with: "") }
}

@MainActor
final class ShortcutsWindow: NSWindowController, NSWindowDelegate {
    private weak var app: AppDelegate?
    private let actions = ShortcutAction.allCases
    private var labels: [ShortcutAction: NSTextField] = [:]
    private var buttons: [ShortcutAction: KeyRecorderButton] = [:]
    private let status = NSTextField(wrappingLabelWithString: "Click Change, then press a shortcut containing ⌘. Escape cancels.")

    private final class Document: NSView {
        override var isFlipped: Bool { true }
    }

    init(app: AppDelegate) {
        self.app = app
        let height = min(640, (NSScreen.main?.visibleFrame.height ?? 800) - 80)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: height),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Keyboard Shortcuts"; window.delegate = self
        window.isReleasedWhenClosed = false
        let title = NSTextField(labelWithString: "A shortcut to your flow.")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let document = Document(frame: NSRect(x: 0, y: 0, width: 544, height: actions.count * 36))
        for (index, action) in actions.enumerated() {
            let row = NSView(frame: NSRect(x: 0, y: index * 36, width: 544, height: 36))
            let name = NSTextField(labelWithString: action.title)
            name.frame = NSRect(x: 0, y: 8, width: 220, height: 20)
            let shortcut = NSTextField(labelWithString: "")
            shortcut.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
            shortcut.alignment = .right
            shortcut.frame = NSRect(x: 220, y: 8, width: 100, height: 20)
            let change = KeyRecorderButton(idleTitle: "Change…")
            change.onBegin = { [weak self] in
                self?.stopRecording()
                self?.status.stringValue = "Recording \(action.title). Include ⌘; Escape cancels."
            }
            change.commit = { [weak self] capture in self?.commit(capture, for: action) }
            change.onReject = { [weak self] message in self?.status.stringValue = message }
            change.onCancel = { [weak self] in self?.status.stringValue = "Shortcut recording cancelled." }
            change.frame = NSRect(x: 335, y: 5, width: 100, height: 26)
            change.setAccessibilityLabel("Change \(action.title) shortcut")
            let reset = NSButton(image: NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "Reset \(action.title)")!,
                                 target: self, action: #selector(resetShortcut(_:)))
            reset.bezelStyle = .inline; reset.controlSize = .small; reset.tag = index
            reset.toolTip = "Restore default for \(action.title)"
            reset.frame = NSRect(x: 449, y: 6, width: 28, height: 24)
            for view in [name, shortcut, change, reset] { row.addSubview(view) }
            document.addSubview(row)
            labels[action] = shortcut; buttons[action] = change
        }
        scroll.documentView = document
        let reference = NSTextField(wrappingLabelWithString: "Standard editing: ⌘C Copy · ⌘V Paste · ⌘A Select All\nFixed tab alternatives: ⇧⌘[ Previous · ⇧⌘] Next")
        reference.font = .systemFont(ofSize: 11); reference.textColor = .secondaryLabelColor
        let resetAll = NSButton(title: "Restore Default Shortcuts", target: self, action: #selector(resetAll))
        resetAll.bezelStyle = .rounded; resetAll.controlSize = .small
        let stack = NSStackView(views: [title, status, scroll, reference, resetAll])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -24),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            reference.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        window.center(); refresh()
    }
    required init?(coder: NSCoder) { fatalError("Programmatic windows only") }
    func refresh() {
        guard let app else { return }
        for action in actions { labels[action]?.stringValue = app.shortcuts.binding(for: action)?.display ?? "—" }
    }
    /// Applies a pressed combination to `action`; returns the reason to reject it, or nil once saved.
    private func commit(_ capture: KeyCapture, for action: ShortcutAction) -> String? {
        guard let app else { return nil }
        let binding = ShortcutBinding(capture.key, capture.modifiers)
        do {
            var value = app.shortcuts
            try value.set(binding, for: action)
            if let other = ShortcutProbe.conflict(event: capture.event, excluding: action) {
                return "That shortcut is already used by \(other). Try another combination."
            }
            app.updateShortcuts(value)
            status.stringValue = "Saved \(binding.display) for \(action.title)."
            return nil
        } catch { return error.localizedDescription }
    }
    private func stopRecording() {
        for button in buttons.values { button.stopRecording() }
    }
    func windowWillClose(_ notification: Notification) { stopRecording() }
    func windowDidResignKey(_ notification: Notification) { stopRecording() }
    @objc private func resetShortcut(_ sender: NSButton) {
        stopRecording()
        guard let app, actions.indices.contains(sender.tag) else { return }
        do {
            var value = app.shortcuts
            try value.reset(actions[sender.tag])
            app.updateShortcuts(value)
            status.stringValue = "Default shortcut restored."
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func resetAll() {
        stopRecording(); app?.updateShortcuts(ShortcutConfiguration())
        status.stringValue = "Default shortcuts restored."
    }
}
