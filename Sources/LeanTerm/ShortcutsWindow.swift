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
    private var buttons: [ShortcutAction: NSButton] = [:]
    private let status = NSTextField(wrappingLabelWithString: "Click Change, then press a shortcut containing ⌘. Escape cancels.")
    private var recording: ShortcutAction?
    private var releaseKey: UInt16?
    private var monitor: Any?
    private var deactivation: NSObjectProtocol?

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
            let change = NSButton(title: "Change…", target: self, action: #selector(recordShortcut(_:)))
            change.bezelStyle = .rounded; change.controlSize = .small; change.tag = index
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
    @objc private func recordShortcut(_ sender: NSButton) {
        stopRecording()
        guard actions.indices.contains(sender.tag) else { return }
        let action = actions[sender.tag]
        recording = action
        buttons[action]?.title = "Press keys…"
        status.stringValue = "Recording \(action.title). Include ⌘; Escape cancels."
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, self.recording != nil, self.window?.isKeyWindow == true else { return event }
            if let eventWindow = event.window, eventWindow !== self.window { return event }
            return self.capture(event)
        }
        deactivation = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                             object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopRecording() }
        }
    }
    private func capture(_ event: NSEvent) -> NSEvent? {
        if event.type == .keyUp {
            if releaseKey == event.keyCode { stopRecording() }
            return nil
        }
        if event.isARepeat || releaseKey != nil { return nil }
        if event.keyCode == 53 {
            stopRecording()
            status.stringValue = "Shortcut recording cancelled."
            return nil
        }
        guard let app, let action = recording,
              let key = event.characters(byApplyingModifiers: []), !key.isEmpty else { return nil }
        let binding = ShortcutBinding(key, .init(eventFlags: event.modifierFlags))
        do {
            var value = app.shortcuts
            try value.set(binding, for: action)
            if let other = ShortcutProbe.conflict(event: event, excluding: action) {
                status.stringValue = "That shortcut is already used by \(other). Try another combination."
                return nil
            }
            // Keep consuming until key-up, so recording Quit/Close cannot invoke it.
            releaseKey = event.keyCode
            app.updateShortcuts(value)
            buttons[action]?.title = "Release key…"
            status.stringValue = "Saved \(binding.display) for \(action.title)."
        } catch { status.stringValue = error.localizedDescription }
        return nil
    }
    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if let deactivation { NotificationCenter.default.removeObserver(deactivation); self.deactivation = nil }
        if let recording { buttons[recording]?.title = "Change…" }
        recording = nil; releaseKey = nil
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
