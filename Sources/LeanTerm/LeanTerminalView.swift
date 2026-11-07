import AppKit
import LeanTermCore
import SwiftTerm
import Synchronization

/// Resolves and opens paths that the user ⌘-clicks in terminal output.
@MainActor
protocol TerminalPathDelegate: AnyObject {
    /// Paths in a remote session live on the other machine.
    var pathsAreRemote: Bool { get }
    func resolvePath(_ detected: DetectedPath) -> ResolvedPath?
    func openPath(_ path: ResolvedPath, inNewTab: Bool)
}

/// Terminal view that reports the bell to the app without making any sound,
/// accepts dropped files and text, and confirms multi-line pastes.
final class LeanTerminalView: LocalProcessTerminalView {
    private let bellPending = Atomic<Bool>(false)
    /// Called on the main thread, at most once per burst of bells.
    var onBell: (@MainActor () -> Void)?
    /// Whether a multi-line paste into a program without bracketed paste needs confirmation.
    var confirmsMultilinePaste = true
    /// Turns the confirmation preference off after the user ticks "Don't ask again".
    var onDisableMultilinePasteConfirmation: (@MainActor () -> Void)?
    private var pasteConfirmationShowing = false
    /// Whether every copy masks sensitive data (the opt-in preference); the explicit command always does.
    var redactsCopies = false
    /// Called on the main thread with the number of masked items, only when it is above zero.
    var onCopyRedacted: (@MainActor (Int) -> Void)?
    private var redactionRunning = false
    weak var pathDelegate: TerminalPathDelegate?
    private var pressPoint: NSPoint?
    /// The hovered token whose existence was already checked, so each token costs one file-system check.
    private var hoverCheck: (path: DetectedPath, row: Int, exists: Bool)?
    private var handCursorShown = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { removeHoverMonitors() } else { installHoverMonitor() }
        registerForDraggedTypes([.fileURL, .string])
    }

    /// Runs on the parse thread: only touches the atomic, then hops to the main thread once per burst.
    nonisolated override func bell(source: Terminal) {
        super.bell(source: source)
        guard bellPending.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.bellPending.store(false, ordering: .relaxed)
                self.onBell?()
            }
        }
    }

    // MARK: Drag and drop

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropContent(from: sender.draggingPasteboard) == nil ? [] : .copy
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropContent(from: sender.draggingPasteboard) == nil ? [] : .copy
    }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dropContent(from: sender.draggingPasteboard) != nil
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let content = dropContent(from: sender.draggingPasteboard) else { return false }
        // SwiftTerm's paste path honours bracketed paste mode; no newline is ever appended.
        // Escaped file paths are single-line; dropped text gets the same confirmation as a paste.
        if content.isFiles { pasteText(content.text) }
        else { confirmIfNeeded(text: content.text) { [weak self] in self?.pasteText(content.text) } }
        return true
    }

    private func dropContent(from pasteboard: NSPasteboard) -> (text: String, isFiles: Bool)? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return (urls.map { ShellEscape.path($0.path) }.joined(separator: " ") + " ", true)
        }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return nil }
        return (text, false)
    }

    // MARK: Paste confirmation

    /// Every paste (⌘V, Edit › Paste) arrives here, so one check covers menus and shortcuts.
    override func paste(_ sender: Any) {
        confirmIfNeeded(text: NSPasteboard.general.string(forType: .string)) { [weak self] in self?.performPaste(sender) }
    }

    private func performPaste(_ sender: Any) { super.paste(sender) }

    /// Runs `proceed` now, or after the user accepts a sheet when `text` has several lines and the
    /// program is not using bracketed paste.
    private func confirmIfNeeded(text: String?, then proceed: @escaping @MainActor () -> Void) {
        guard confirmsMultilinePaste, !pasteConfirmationShowing, let window, let text,
              terminalInputStateSnapshot()?.bracketedPasteMode != true else {
            proceed()
            return
        }
        var body = Substring(text)
        if body.last?.isNewline == true { body = body.dropLast() }
        let lines = body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard lines.count > 1 else {
            proceed()
            return
        }
        var preview = lines.prefix(3).map { line in
            line.count > 80 ? String(line.prefix(80)) + "…" : String(line)
        }.joined(separator: "\n")
        if lines.count > 3 { preview += "\n…" }
        let alert = NSAlert()
        alert.messageText = "Paste \(lines.count) lines?"
        alert.informativeText = "This program isn't using bracketed paste, so each line may run as a command.\n\n" + preview
        alert.addButton(withTitle: "Paste")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        pasteConfirmationShowing = true
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                self?.pasteConfirmationShowing = false
                if alert.suppressionButton?.state == .on { self?.onDisableMultilinePasteConfirmation?() }
                if response == .alertFirstButtonReturn { proceed() }
            }
        }
    }

    // MARK: Redacted copy

    override func copy(_ sender: Any) {
        if redactsCopies { copyRedacted() } else { super.copy(sender) }
    }

    @objc func copyWithoutSensitiveData(_ sender: Any?) { copyRedacted() }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copyWithoutSensitiveData(_:)) { return selectionActive }
        if [#selector(previousPrompt(_:)), #selector(nextPrompt(_:)), #selector(selectCommandOutput(_:))].contains(item.action) {
            return hasSemanticPrompts
        }
        return super.validateUserInterfaceItem(item)
    }

    /// Redaction runs off the main thread; a copy requested while one is still running is ignored.
    private func copyRedacted() {
        guard !redactionRunning, let text = getSelection(), !text.isEmpty else { return }
        redactionRunning = true
        Task { @MainActor [weak self] in
            let result = await Task.detached { SensitiveDataRedactor.redact(text) }.value
            guard let self else { return }
            redactionRunning = false
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result.text, forType: .string)
            if result.removed > 0 { onCopyRedacted?(result.removed) }
        }
    }

    // MARK: Prompt navigation (needs the shell to emit OSC 133)

    @objc func previousPrompt(_ sender: Any?) {
        if let row = previousSemanticPromptRow() { scrollTo(row: row) }
    }

    /// Past the last prompt the view returns to the live bottom (scrolling clamps to it).
    @objc func nextPrompt(_ sender: Any?) {
        if let row = nextSemanticPromptRow() { scrollTo(row: row) } else { scrollTo(row: .max) }
    }

    /// Selects the output of the command at the top of the viewport, or of the latest command at the live
    /// bottom, so Copy and Copy Without Sensitive Data can take it. Scans the rows once per invocation.
    @objc func selectCommandOutput(_ sender: Any?) {
        guard let map = semanticRowRoles(),
              let rows = CommandOutputLocator.outputRows(roles: map.roles, viewportTop: map.viewportTop, visibleRows: map.visibleRows)
        else { return }
        if !(map.viewportTop..<(map.viewportTop + map.visibleRows)).contains(rows.lowerBound) { scrollTo(row: rows.lowerBound) }
        selectBufferRows(rows)
    }

    // MARK: Clickable paths

    override func mouseDown(with event: NSEvent) {
        pressPoint = event.locationInWindow
        super.mouseDown(with: event)
    }

    /// ⌘-click on an existing path opens it. URLs and OSC 8 links stay with SwiftTerm. SwiftTerm still gets the
    /// release (selection and press bookkeeping), but without ⌘ so its own cwd-relative path opening stays out.
    override func mouseUp(with event: NSEvent) {
        defer { pressPoint = nil }
        guard event.modifierFlags.contains(.command), let pathDelegate, event.clickCount == 1,
              let press = pressPoint, hypot(event.locationInWindow.x - press.x, event.locationInWindow.y - press.y) < 4,
              let detected = detectedPath(atWindowPoint: event.locationInWindow) else {
            super.mouseUp(with: event)
            return
        }
        if pathDelegate.pathsAreRemote {
            // Remote paths live on the other machine: keep SwiftTerm from opening a local file of the same
            // relative name, but leave link-like tokens (OSC 8 text such as "example.com") to SwiftTerm.
            super.mouseUp(with: detected.path.contains("/") ? Self.withoutCommand(event) : event)
        } else if let resolved = pathDelegate.resolvePath(detected) {
            super.mouseUp(with: Self.withoutCommand(event))
            pathDelegate.openPath(resolved, inNewTab: event.modifierFlags.contains(.shift))
        } else {
            super.mouseUp(with: event)
        }
    }

    // SwiftTerm's mouseMoved and flagsChanged are not open, so hover feedback listens through local monitors.
    // The flags monitor is a closure that returns at once without ⌘; the mouse monitor exists only while ⌘ is down.
    private var flagsMonitor: Any?
    private var moveMonitor: Any?

    private func installHoverMonitor() {
        guard flagsMonitor == nil else { return }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.commandChanged(event.modifierFlags.contains(.command)) }
            return event
        }
    }

    private func removeHoverMonitors() {
        for monitor in [flagsMonitor, moveMonitor] { if let monitor { NSEvent.removeMonitor(monitor) } }
        flagsMonitor = nil; moveMonitor = nil
        hoverCheck = nil
    }

    private func commandChanged(_ command: Bool) {
        guard let window, window.isKeyWindow else { return }
        if command, moveMonitor == nil {
            moveMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
                MainActor.assumeIsolated {
                    if let self, event.window === self.window {
                        self.updateHoverCursor(command: true, windowPoint: event.locationInWindow)
                    }
                }
                return event
            }
        } else if !command {
            if let moveMonitor { NSEvent.removeMonitor(moveMonitor) }
            moveMonitor = nil
            hoverCheck = nil
        }
        updateHoverCursor(command: command, windowPoint: window.mouseLocationOutsideOfEventStream)
    }

    /// Pointing hand over an existing path while ⌘ is held. Does nothing without ⌘.
    private func updateHoverCursor(command: Bool, windowPoint: NSPoint) {
        guard command, let pathDelegate, !pathDelegate.pathsAreRemote,
              let (detected, row) = detectedPathAndRow(atWindowPoint: windowPoint) else {
            if handCursorShown { handCursorShown = false; NSCursor.iBeam.set() }
            return
        }
        if hoverCheck?.path != detected || hoverCheck?.row != row {
            hoverCheck = (detected, row, pathDelegate.resolvePath(detected) != nil)
        }
        if hoverCheck?.exists == true {
            handCursorShown = true
            NSCursor.pointingHand.set()
        } else if handCursorShown {
            handCursorShown = false
            NSCursor.iBeam.set()
        }
    }

    private func detectedPath(atWindowPoint point: NSPoint) -> DetectedPath? {
        detectedPathAndRow(atWindowPoint: point)?.0
    }

    private func detectedPathAndRow(atWindowPoint windowPoint: NSPoint) -> (DetectedPath, Int)? {
        guard let cell = gridCell(atWindowPoint: windowPoint),
              let text = visibleRowsText(cell.row..<(cell.row + 1)).first else { return nil }
        let offset = PathDetection.characterOffset(ofColumn: cell.col, in: text)
        guard let detected = PathDetection.path(in: text, at: offset) else { return nil }
        return (detected, cell.row)
    }

    /// The screen cell under a window point, using the same cell metrics SwiftTerm lays out with.
    private func gridCell(atWindowPoint windowPoint: NSPoint) -> (col: Int, row: Int)? {
        let point = convert(windowPoint, from: nil)
        guard bounds.contains(point), let dimensions = terminalInputStateSnapshot()?.dimensions,
              dimensions.cols > 0, dimensions.rows > 0 else { return nil }
        var character: UniChar = 0x57
        var glyph: CGGlyph = 0
        guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1) else { return nil }
        let scale = window?.backingScaleFactor ?? 1
        let cellWidth = max(1, (font.advancement(forGlyph: NSGlyph(glyph)).width * scale).rounded() / scale)
        let cellHeight = getOptimalFrameSize().height / CGFloat(dimensions.rows)
        guard cellHeight > 0 else { return nil }
        let col = min(max(0, Int(point.x / cellWidth)), dimensions.cols - 1)
        let row = min(max(0, Int((frame.height - point.y) / cellHeight)), dimensions.rows - 1)
        return (col, row)
    }

    private static func withoutCommand(_ event: NSEvent) -> NSEvent {
        NSEvent.mouseEvent(with: event.type, location: event.locationInWindow,
                           modifierFlags: event.modifierFlags.subtracting(.command), timestamp: event.timestamp,
                           windowNumber: event.windowNumber, context: nil, eventNumber: event.eventNumber,
                           clickCount: event.clickCount, pressure: event.pressure) ?? event
    }
}
