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
    /// What a click on `path` will do, for the hover hint.
    func hoverHint(for path: ResolvedPath) -> String
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
    private var explicitLinkOpensInNewTab: Bool?
    private typealias ListingRows = (rows: [String], index: Int, reachesCursor: Bool)
    private var hoverListing: (row: Int, text: String, context: ListingRows?)?
    /// The hovered token whose existence was already checked, so each token costs one file-system check.
    private var hoverCheck: (path: DetectedPath, row: Int, resolved: ResolvedPath?, hint: String?)?
    private var handCursorShown = false
    /// Created on the first ⌘-hover over an existing path.
    private var pathHighlight: PathHighlightView?
    var pathHighlightColors: PathHighlightColors? {
        didSet { if let pathHighlightColors { pathHighlight?.applyColors(pathHighlightColors) } }
    }
    private var resignObserver: NSObjectProtocol?

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

    // MARK: Find

    /// What the Find menu items, shortcuts and toolbar button ask for; `TerminalPane` answers them with its find bar.
    enum FindCommand {
        case show, next, previous, useSelection, hide

        /// The tags shared by `NSFindPanelAction` and `NSTextFinder.Action` (11 is only the latter's hide).
        init?(tag: Int) {
            switch tag {
            case Int(NSFindPanelAction.showFindPanel.rawValue): self = .show
            case Int(NSFindPanelAction.next.rawValue): self = .next
            case Int(NSFindPanelAction.previous.rawValue): self = .previous
            case Int(NSFindPanelAction.setFindString.rawValue): self = .useSelection
            case NSTextFinder.Action.hideFindInterface.rawValue: self = .hide
            default: return nil
            }
        }
    }

    var onFind: (@MainActor (FindCommand) -> Void)?

    override func performFindPanelAction(_ sender: Any?) {
        guard let onFind, let item = sender as? NSMenuItem, let command = FindCommand(tag: item.tag) else { return super.performFindPanelAction(sender) }
        onFind(command)
    }

    override func performTextFinderAction(_ sender: Any?) {
        guard let onFind, let item = sender as? NSMenuItem, let command = FindCommand(tag: item.tag) else { return super.performTextFinderAction(sender) }
        onFind(command)
    }

    /// Where the displayed buffer sits in SwiftTerm's scroll-invariant row numbers, which stay valid while old
    /// rows are trimmed from the scrollback. A buffer row is `absolute row - base`.
    struct BufferGeometry {
        /// The absolute row number of buffer row 0.
        var base: Int
        /// The buffer row at the top of the viewport (0 in the alternate buffer, which has no scrollback).
        var viewportTop: Int
        /// The number of rows in the buffer, scrollback included.
        var total: Int
        var rows: Int
        var cols: Int
        var isAlternate: Bool
    }

    /// Reads the geometry in two short lock acquisitions. Nil without a session.
    func bufferGeometry() -> BufferGeometry? {
        guard let viewport = terminalContentSnapshot(region: .viewport) else { return nil }
        let dimensions = viewport.inputState.dimensions
        let semantic = semanticViewport
        let top = semantic?.top ?? 0
        return BufferGeometry(base: viewport.capturedRange.lowerBound - top, viewportTop: top,
                              total: semantic?.total ?? dimensions.rows, rows: dimensions.rows, cols: dimensions.cols,
                              isAlternate: viewport.inputState.isAlternateBuffer)
    }

    /// The text and soft-wrap flag of the buffer rows with these absolute numbers (rows trimmed meanwhile read
    /// as empty), copied in chunks. Each chunk holds the terminal lock for a few milliseconds, so a 100,000-line
    /// scrollback is copied in about half a second without ever stalling output or drawing; any thread may call it.
    nonisolated func bufferText(absoluteRows range: Range<Int>) -> (rows: [String], wrapped: [Bool]) {
        var rows: [String] = []
        var wrapped: [Bool] = []
        rows.reserveCapacity(range.count)
        wrapped.reserveCapacity(range.count)
        var next = range.lowerBound
        while next < range.upperBound {
            let chunk = next..<min(range.upperBound, next + 1_000)
            guard let snapshot = terminalContentSnapshot(region: .rows(chunk)) else { break }
            for row in snapshot.rows {
                while next < row.absoluteRow { rows.append(""); wrapped.append(false); next += 1 }
                rows.append(row.text)
                wrapped.append(row.isWrapped)
                next += 1
            }
            if next < chunk.upperBound {
                // Rows the terminal no longer retains.
                rows.append(contentsOf: repeatElement("", count: chunk.upperBound - next))
                wrapped.append(contentsOf: repeatElement(false, count: chunk.upperBound - next))
                next = chunk.upperBound
            }
        }
        return (rows, wrapped)
    }

    /// Called on the main thread whenever the view is laid out (a resize may move the rows).
    var onLayout: (@MainActor () -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
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
        guard let viewport = semanticViewport else { return }
        let atLiveBottom = viewport.top + viewport.rows >= viewport.total
        let window = atLiveBottom ? max(0, viewport.top - Self.semanticScanLimit)..<viewport.total : viewport.top..<(viewport.top + 1)
        let candidates = CommandOutputLocator.candidates(spans: commandSpans(in: window), viewportTop: viewport.top, atLiveBottom: atLiveBottom)
        for span in candidates {
            if select(outputOf: span, viewportTop: viewport.top, visibleRows: viewport.rows) { return }
        }
    }

    /// The commands that intersect the buffer rows, from the OSC 133 marks (empty without shell integration).
    func commandSpans(in rows: Range<Int>) -> [CommandSpan] {
        semanticCommandSpans(rows: rows).map { CommandSpan(promptRow: $0.promptRow, lastRow: $0.lastRow, exitCode: $0.exitCode, hasOutput: $0.hasOutput) }
    }

    /// Selects the output rows of the command that opens at `promptRow`. Does nothing when it has none.
    func selectCommandOutput(promptRow: Int) {
        guard let viewport = semanticViewport,
              let span = commandSpans(in: promptRow..<(promptRow + 1)).first(where: { $0.promptRow == promptRow }) else { return }
        _ = select(outputOf: span, viewportTop: viewport.top, visibleRows: viewport.rows)
    }

    private func select(outputOf span: CommandSpan, viewportTop: Int, visibleRows: Int) -> Bool {
        guard let rows = semanticOutputRows(promptRow: span.promptRow, lastRow: span.lastRow) else { return false }
        if !(viewportTop..<(viewportTop + visibleRows)).contains(rows.lowerBound) { scrollTo(row: rows.lowerBound) }
        selectBufferRows(rows)
        return true
    }

    /// Called on the main thread when the viewport's scroll position changed (user scrolling or output).
    var onScrolled: (@MainActor () -> Void)?

    override func scrolled(source: TerminalView, position: Double) {
        super.scrolled(source: source, position: position)
        onScrolled?()
    }

    // MARK: Clickable paths

    override func mouseDown(with event: NSEvent) {
        pressPoint = event.locationInWindow
        hideHighlight()
        super.mouseDown(with: event)
    }

    /// SwiftTerm checks OSC 8 links first. For a path we handle ourselves, hand over the release without ⌘
    /// so SwiftTerm can finish mouse bookkeeping without also following an implicit link.
    override func mouseUp(with event: NSEvent) {
        defer { pressPoint = nil }
        guard event.modifierFlags.contains(.command), let pathDelegate, event.clickCount == 1,
              let press = pressPoint, hypot(event.locationInWindow.x - press.x, event.locationInWindow.y - press.y) < 4,
              let hit = pathHit(at: convert(event.locationInWindow, from: nil)) else {
            super.mouseUp(with: event)
            return
        }
        if hit.isExplicit {
            explicitLinkOpensInNewTab = event.modifierFlags.contains(.shift)
            defer { explicitLinkOpensInNewTab = nil }
            super.mouseUp(with: event)
            return
        }
        let entry = ListingPathDetection.longEntry(in: hit.text)
        let detected = pathMatch(for: hit, longEntry: entry, hovering: false)?.path
        if pathDelegate.pathsAreRemote {
            super.mouseUp(with: entry != nil || detected?.path.contains("/") == true ? Self.withoutCommand(event) : event)
        } else if let detected, let resolved = pathDelegate.resolvePath(detected) {
            super.mouseUp(with: Self.withoutCommand(event))
            pathDelegate.openPath(resolved, inNewTab: event.modifierFlags.contains(.shift))
        } else {
            super.mouseUp(with: entry == nil ? event : Self.withoutCommand(event))
        }
    }

    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let inNewTab = explicitLinkOpensInNewTab, let pathDelegate,
              let url = URL(string: link), url.isFileURL else {
            super.requestOpenLink(source: source, link: link, params: params)
            return
        }
        // SwiftTerm calls the delegate only after validating the explicit target.
        guard !pathDelegate.pathsAreRemote,
              let resolved = pathDelegate.resolvePath(DetectedPath(path: url.path, line: nil, column: nil)) else { return }
        pathDelegate.openPath(resolved, inNewTab: inNewTab)
    }

    // SwiftTerm's mouseMoved and flagsChanged are not open, so hover feedback listens through local monitors.
    // The flags monitor is a closure that returns at once without ⌘; the mouse monitor exists only while ⌘ is down.
    private var flagsMonitor: Any?
    private var moveMonitor: Any?

    private func installHoverMonitor() {
        guard flagsMonitor == nil else { return }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideHighlight() }
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.commandChanged(event.modifierFlags.contains(.command)) }
            return event
        }
    }

    private func removeHoverMonitors() {
        for monitor in [flagsMonitor, moveMonitor] { if let monitor { NSEvent.removeMonitor(monitor) } }
        flagsMonitor = nil; moveMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        hoverCheck = nil
        hoverListing = nil
        hideHighlight()
    }

    /// Fades the highlight out. Does nothing when none is showing.
    private func hideHighlight() { pathHighlight?.hide() }

    /// New output arrived in this pane (called once per burst on the main thread): the highlighted row may have changed.
    func outputArrived() {
        hoverListing = nil
        hoverCheck = nil
        guard let pathHighlight, !pathHighlight.isHidden else { return }
        pathHighlight.hide()
    }

    private func commandChanged(_ command: Bool) {
        guard let window, window.isKeyWindow else { return }
        if command, moveMonitor == nil {
            moveMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .scrollWheel]) { [weak self] event in
                MainActor.assumeIsolated {
                    if let self, event.window === self.window, self.window?.isKeyWindow == true {
                        // Scrolling moves the text under the pointer; the next move shows the highlight again.
                        if event.type == .scrollWheel {
                            self.hoverListing = nil
                            self.hoverCheck = nil
                            self.hideHighlight()
                        } else {
                            self.updateHoverCursor(command: true, windowPoint: event.locationInWindow)
                        }
                    }
                }
                return event
            }
        } else if !command {
            if let moveMonitor { NSEvent.removeMonitor(moveMonitor) }
            moveMonitor = nil
            hoverCheck = nil
            hoverListing = nil
            hideHighlight()
        }
        updateHoverCursor(command: command, windowPoint: window.mouseLocationOutsideOfEventStream)
    }

    /// Pointing hand and phosphor highlight over an existing path while ⌘ is held. Does nothing without ⌘.
    private func updateHoverCursor(command: Bool, windowPoint: NSPoint) {
        guard command, let pathDelegate, !pathDelegate.pathsAreRemote,
              let hit = pathHit(at: convert(windowPoint, from: nil)), !hit.isExplicit,
              let match = pathMatch(for: hit, longEntry: ListingPathDetection.longEntry(in: hit.text), hovering: true) else {
            clearHover()
            return
        }
        let detected = match.path
        if hoverCheck?.path != detected || hoverCheck?.row != hit.row {
            let resolved = pathDelegate.resolvePath(detected)
            hoverCheck = (detected, hit.row, resolved, resolved.map { pathDelegate.hoverHint(for: $0) })
        }
        guard let hint = hoverCheck?.hint else {
            clearHover()
            return
        }
        handCursorShown = true
        NSCursor.pointingHand.set()
        showHighlight(for: (match, hit.row, hit.text), hint: hint)
    }

    private func clearHover() {
        if handCursorShown { handCursorShown = false; NSCursor.iBeam.set() }
        hideHighlight()
    }

    private func showHighlight(for hovered: (match: PathMatch, row: Int, text: String), hint: String) {
        guard let metrics = cellMetrics() else { return }
        let columns = PathDetection.column(ofCharacterOffset: hovered.match.characters.lowerBound, in: hovered.text)
            ..< PathDetection.column(ofCharacterOffset: hovered.match.characters.upperBound, in: hovered.text)
        let end = min(columns.upperBound, metrics.cols)
        guard columns.lowerBound < end else { return }
        let rect = CGRect(x: CGFloat(columns.lowerBound) * metrics.width,
                          y: frame.height - CGFloat(hovered.row + 1) * metrics.height,
                          width: CGFloat(end - columns.lowerBound) * metrics.width, height: metrics.height)
        let highlight: PathHighlightView
        if let existing = pathHighlight {
            highlight = existing
        } else {
            guard let colors = pathHighlightColors else { return }
            highlight = PathHighlightView(colors: colors)
            highlight.frame = bounds
            addSubview(highlight)
            pathHighlight = highlight
        }
        highlight.show(rect: rect, hint: hint)
    }

    private func pathMatch(for hit: PathHit, longEntry: PathMatch?, hovering: Bool) -> PathMatch? {
        let offset = PathDetection.characterOffset(ofColumn: hit.column, in: hit.text)
        let entry = longEntry ?? ListingPathDetection.shortEntry(in: hit.text, at: offset)
        if let entry, !hit.isWrapped, entry.characters.contains(offset),
           let context = listingContext(for: hit, isLong: longEntry != nil, hovering: hovering),
           context.rows[context.index] == hit.text,
           let detected = ListingPathDetection.path(for: entry, in: context.rows, at: context.index,
                                                    reachesCursor: context.reachesCursor, isLong: longEntry != nil) {
            return PathMatch(path: detected, characters: entry.characters)
        }
        guard longEntry == nil else { return nil }
        return PathDetection.match(in: hit.text, at: offset)
    }

    private func listingContext(for hit: PathHit, isLong: Bool, hovering: Bool) -> ListingRows? {
        if hovering, let cached = hoverListing, cached.row == hit.row, cached.text == hit.text { return cached.context }
        let context = listingRows(around: hit.row, limit: isLong ? 256 : 64)
        if hovering { hoverListing = (hit.row, hit.text, context) }
        return context
    }

    /// The cell size and grid dimensions SwiftTerm lays out with, derived from its public API.
    func cellMetrics() -> (width: CGFloat, height: CGFloat, cols: Int, rows: Int)? {
        guard let dimensions = terminalInputStateSnapshot()?.dimensions, dimensions.cols > 0, dimensions.rows > 0 else { return nil }
        var character: UniChar = 0x57
        var glyph: CGGlyph = 0
        guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1) else { return nil }
        let scale = window?.backingScaleFactor ?? 1
        let cellWidth = max(1, (font.advancement(forGlyph: NSGlyph(glyph)).width * scale).rounded() / scale)
        let cellHeight = getOptimalFrameSize().height / CGFloat(dimensions.rows)
        guard cellHeight > 0 else { return nil }
        return (cellWidth, cellHeight, dimensions.cols, dimensions.rows)
    }

    private static func withoutCommand(_ event: NSEvent) -> NSEvent {
        NSEvent.mouseEvent(with: event.type, location: event.locationInWindow,
                           modifierFlags: event.modifierFlags.subtracting(.command), timestamp: event.timestamp,
                           windowNumber: event.windowNumber, context: nil, eventNumber: event.eventNumber,
                           clickCount: event.clickCount, pressure: event.pressure) ?? event
    }
}
