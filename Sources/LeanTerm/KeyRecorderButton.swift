import AppKit
import LeanTermCore

/// One key combination pressed while recording.
struct KeyCapture {
    let key: String
    let modifiers: ShortcutModifiers
    let keyCode: UInt16
    let event: NSEvent
}

/// A button that records a key combination: click, press the keys, Escape cancels. Shared by the Keyboard
/// Shortcuts window (menu shortcuts) and Settings (global hot key); each supplies its own `commit` rules.
/// The recorded key is consumed until it is released, so recording Quit or Close cannot invoke it.
@MainActor
final class KeyRecorderButton: NSButton {
    /// Called when recording is about to start, so an owner can stop other recorders.
    var onBegin: (() -> Void)?
    /// Validates and applies a pressed combination. Returns a message to reject it (recording continues), or nil once accepted.
    var commit: ((KeyCapture) -> String?)?
    /// Called with the rejection message returned by `commit`.
    var onReject: ((String) -> Void)?
    /// Called when Escape ends recording.
    var onCancel: (() -> Void)?
    /// Called with true when recording starts and false when it ends.
    var onRecordingChanged: ((Bool) -> Void)?
    /// The title shown when not recording.
    var idleTitle: String { didSet { if !isRecording { title = idleTitle } } }
    var isRecording: Bool { monitor != nil }
    private var releaseKey: UInt16?
    private var monitor: Any?
    private var deactivation: NSObjectProtocol?
    private var resignation: NSObjectProtocol?

    init(idleTitle: String) {
        self.idleTitle = idleTitle
        super.init(frame: .zero)
        title = idleTitle
        bezelStyle = .rounded; controlSize = .small
        target = self; action = #selector(begin)
    }
    required init?(coder: NSCoder) { fatalError("Programmatic views only") }

    @objc private func begin() {
        onBegin?()
        stopRecording()
        title = "Press keys…"
        onRecordingChanged?(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            if let eventWindow = event.window, eventWindow !== self.window { return event }
            return self.capture(event)
        }
        deactivation = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                             object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopRecording() }
        }
        resignation = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                            object: window, queue: .main) { [weak self] _ in
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
            onCancel?()
            return nil
        }
        guard let key = event.characters(byApplyingModifiers: []), !key.isEmpty else { return nil }
        let capture = KeyCapture(key: key, modifiers: .init(eventFlags: event.modifierFlags), keyCode: event.keyCode, event: event)
        if let message = commit?(capture) {
            onReject?(message)
            return nil
        }
        releaseKey = event.keyCode
        title = "Release key…"
        return nil
    }

    func stopRecording() {
        guard isRecording else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let deactivation { NotificationCenter.default.removeObserver(deactivation) }
        deactivation = nil
        if let resignation { NotificationCenter.default.removeObserver(resignation) }
        resignation = nil
        releaseKey = nil
        title = idleTitle
        onRecordingChanged?(false)
    }
}
