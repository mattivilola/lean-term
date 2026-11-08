import AppKit
import LeanTermCore

/// The find bar of one pane: debounced incremental search over the whole buffer, match highlights and the
/// current match. The search itself is `TerminalSearch` (Core); this class owns timing and presentation.
///
/// Cost model: nothing runs while the bar is closed. Typing waits 120 ms and then copies the buffer text
/// once (`LeanTerminalView.bufferRows`, under the terminal lock, off the main thread), searches it off the
/// main thread and returns to the main thread with the match list. New output re-runs the same search, at
/// most four times a second and never more often than ten times the last search took.
@MainActor
final class FindController {
    private enum Reason { case opened, typed, options, refresh }

    let bar = FindBarView()
    /// The bar appeared or disappeared; the pane moves the terminal accordingly.
    var onVisibilityChanged: (() -> Void)?
    /// The user flipped "Aa" or ".*".
    var onOptionsChanged: ((_ matchCase: Bool, _ regex: Bool) -> Void)?
    /// Whether the pane is on screen (a hidden tab does not search).
    var isPaneVisible: () -> Bool = { true }

    private unowned let terminal: LeanTerminalView
    /// Created with the first visible match and reused.
    private var highlightView: FindHighlightView?
    private var phosphor = NSColor.systemGreen
    private(set) var isOpen = false

    /// Matches in the row numbers of the searched snapshot; `origin` is the absolute row of its first row, so
    /// they stay correct while the scrollback is trimmed: buffer row = row + origin - geometry.base.
    private var matches: [TerminalSearchMatch] = []
    private var origin = 0
    private var truncated = false
    private var invalid = false
    private var current: Int?
    private var generation = 0
    private var searching = false
    private var refreshWanted = false
    private var debounce: DispatchWorkItem?
    private var refresh: DispatchWorkItem?
    private var lastSearchStart: TimeInterval = 0
    private var lastSearchDuration: TimeInterval = 0
    private static let debounceInterval: TimeInterval = 0.12
    private static let minimumRefreshInterval: TimeInterval = 0.25

    init(terminal: LeanTerminalView) {
        self.terminal = terminal
        bar.onQueryChanged = { [weak self] in self?.queryChanged() }
        bar.onOptionsChanged = { [weak self] in
            guard let self else { return }
            onOptionsChanged?(bar.matchesCase, bar.usesRegex)
            search(.options)
        }
        bar.onCommand = { [weak self] in self?.handle($0) }
        terminal.onFind = { [weak self] in self?.handle($0) }
        terminal.onLayout = { [weak self] in self?.updateHighlights() }
    }

    func applyTheme(_ theme: TerminalTheme) {
        phosphor = theme.phosphor
        bar.applyTheme(theme)
        highlightView?.applyColor(theme.phosphor)
    }

    /// The persisted toggles changed (from another pane, or Settings reset).
    func setOptions(matchCase: Bool, regex: Bool) {
        guard matchCase != bar.matchesCase || regex != bar.usesRegex else { return }
        bar.setOptions(matchCase: matchCase, regex: regex)
        if isOpen { search(.options) }
    }

    // MARK: Commands

    func handle(_ command: LeanTerminalView.FindCommand) {
        switch command {
        case .show, .useSelection: open(prefillSelection: true)
        case .hide: close()
        case .next, .previous:
            guard isOpen else { return open(prefillSelection: false) }
            step(forward: command == .next)
        }
    }

    private func open(prefillSelection: Bool) {
        let wasOpen = isOpen
        isOpen = true
        bar.isHidden = false
        if !wasOpen { onVisibilityChanged?() }
        if prefillSelection, let selected = terminal.getSelection(), !selected.isEmpty, !selected.contains(where: \.isNewline), selected.count <= 200 {
            bar.query = selected
        } else if bar.query.isEmpty, let pasted = NSPasteboard(name: .find).string(forType: .string), !pasted.contains(where: \.isNewline) {
            bar.query = pasted
        }
        bar.focusField()
        search(.opened)
    }

    private func close() {
        guard isOpen else { return }
        isOpen = false
        generation += 1
        debounce?.cancel(); debounce = nil
        refresh?.cancel(); refresh = nil
        refreshWanted = false
        searching = false
        matches = []; current = nil; truncated = false; invalid = false
        highlightView?.clear()
        bar.isHidden = true
        onVisibilityChanged?()
        terminal.window?.makeFirstResponder(terminal)
    }

    private func queryChanged() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.debounce = nil
                self?.search(.typed)
            }
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceInterval, execute: work)
    }

    private func step(forward: Bool) {
        // A pending debounce means the list belongs to an older query: search first, then it picks a match.
        if debounce != nil {
            debounce?.cancel(); debounce = nil
            search(.typed)
            return
        }
        guard !matches.isEmpty else { return }
        let count = matches.count
        let index = current.map { (($0 + (forward ? 1 : -1)) % count + count) % count } ?? (forward ? 0 : count - 1)
        select(index)
        updateCount()
    }

    /// New PTY output arrived (called once per burst on the main thread).
    func contentMayHaveChanged() {
        guard isOpen, !bar.query.isEmpty, isPaneVisible() else { return }
        guard refresh == nil, debounce == nil else { return }
        if searching { refreshWanted = true; return }
        let wait = max(Self.minimumRefreshInterval, lastSearchDuration * 10)
        let delay = max(0, lastSearchStart + wait - ProcessInfo.processInfo.systemUptime)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refresh = nil
                if self.isOpen, self.debounce == nil { self.search(.refresh) }
            }
        }
        refresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0.05), execute: work)
    }

    // MARK: Searching

    private func search(_ reason: Reason) {
        debounce?.cancel(); debounce = nil
        refresh?.cancel(); refresh = nil
        let query = bar.query
        generation += 1
        let generation = generation
        guard !query.isEmpty else {
            searching = false
            matches = []; current = nil; truncated = false; invalid = false
            updateCount()
            updateHighlights()
            return
        }
        if reason != .refresh { NSPasteboard(name: .find).clearContents(); NSPasteboard(name: .find).setString(query, forType: .string) }
        let matchCase = bar.matchesCase, regex = bar.usesRegex
        guard let geometry = terminal.bufferGeometry() else { return }
        let anchor = (reason == .typed ? current.map { matches[$0].shifted(byRows: origin) } : nil)
            ?? TerminalSearchMatch(row: geometry.base + geometry.viewportTop, startColumn: 0, endColumn: 0)
        let first = geometry.base
        let view = terminal
        searching = true
        lastSearchStart = ProcessInfo.processInfo.systemUptime
        Task { @MainActor [weak self] in
            let started = ProcessInfo.processInfo.systemUptime
            let outcome = await Task.detached(priority: .userInitiated) {
                let text = view.bufferText(absoluteRows: first..<(first + geometry.total))
                return TerminalSearch.search(rows: text.rows, wrapped: text.wrapped, columns: geometry.cols, query: query,
                                             matchCase: matchCase, useRegex: regex)
            }.value
            self?.finish(outcome, origin: first, generation: generation, reason: reason, anchor: anchor,
                         duration: ProcessInfo.processInfo.systemUptime - started)
        }
    }

    private func finish(_ outcome: TerminalSearchOutcome, origin newOrigin: Int, generation: Int, reason: Reason,
                        anchor: TerminalSearchMatch, duration: TimeInterval) {
        if generation == self.generation {
            searching = false
            lastSearchDuration = duration
        }
        guard generation == self.generation, isOpen else { return }
        let previous = current.map { matches[$0].shifted(byRows: origin - newOrigin) }
        origin = newOrigin
        switch outcome {
        case .invalidPattern:
            matches = []; truncated = false; invalid = true; current = nil
        case .matches(let found, let isTruncated):
            matches = found; truncated = isTruncated; invalid = false
            if reason == .refresh {
                current = previous.flatMap { found.firstIndex(of: $0) }
            } else if found.isEmpty {
                current = nil
            } else {
                current = found.firstIndex { ($0.row + newOrigin, $0.startColumn) >= (anchor.row, anchor.startColumn) } ?? 0
            }
        }
        if reason != .refresh, let current { select(current) }
        updateCount()
        updateHighlights()
        if refreshWanted {
            refreshWanted = false
            contentMayHaveChanged()
        }
    }

    // MARK: Presentation

    /// Selects the match (so Copy takes it) and centres it unless it is already on screen.
    private func select(_ index: Int) {
        current = index
        guard let geometry = terminal.bufferGeometry() else { return }
        let match = matches[index].shifted(byRows: origin - geometry.base)
        guard match.row >= 0 else { return }
        terminal.selectBufferCells(from: (match.row, match.startColumn), to: (match.endRow, match.endColumn))
        if !geometry.isAlternate, !(geometry.viewportTop..<(geometry.viewportTop + geometry.rows)).contains(match.row) {
            terminal.scrollTo(row: match.row - geometry.rows / 2)
        }
        updateHighlights()
    }

    private func updateCount() {
        let total = (matches.count.formatted()) + (truncated ? "+" : "")
        if invalid { bar.setCount("Invalid pattern", invalid: true) }
        else if bar.query.isEmpty { bar.setCount("", invalid: false) }
        else if matches.isEmpty { bar.setCount("No matches", invalid: false) }
        else if let current { bar.setCount("\((current + 1).formatted()) of \(total)", invalid: false) }
        else { bar.setCount("\(total) matches", invalid: false) }
    }

    /// Rectangles for the matches on screen, from the cached list (a binary search plus the visible rows).
    func updateHighlights() {
        guard isOpen, !matches.isEmpty, let metrics = terminal.cellMetrics(), let geometry = terminal.bufferGeometry() else {
            highlightView?.clear()
            return
        }
        let shift = origin - geometry.base
        let top = geometry.viewportTop
        let bottom = top + geometry.rows
        // Matches are ordered and never overlap, so their last rows are ordered too.
        var low = 0, high = matches.count
        while low < high {
            let middle = (low + high) / 2
            if matches[middle].endRow + shift < top { low = middle + 1 } else { high = middle }
        }
        let height = terminal.frame.height
        var others: [CGRect] = []
        var currentRects: [CGRect] = []
        var index = low
        while index < matches.count, matches[index].row + shift < bottom {
            let match = matches[index].shifted(byRows: shift)
            for row in max(match.row, top)...min(match.endRow, bottom - 1) {
                let start = row == match.row ? match.startColumn : 0
                let end = min(row == match.endRow ? match.endColumn : geometry.cols, geometry.cols)
                guard start < end else { continue }
                let rect = CGRect(x: CGFloat(start) * metrics.width, y: height - CGFloat(row - top + 1) * metrics.height,
                                  width: CGFloat(end - start) * metrics.width, height: metrics.height)
                if index == current { currentRects.append(rect) } else { others.append(rect) }
            }
            index += 1
        }
        let overlay: FindHighlightView
        if let highlightView {
            overlay = highlightView
        } else {
            overlay = FindHighlightView()
            overlay.frame = terminal.bounds
            overlay.applyColor(phosphor)
            terminal.addSubview(overlay)
            highlightView = overlay
        }
        overlay.show(others: others, current: currentRects)
    }
}
