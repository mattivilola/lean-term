import AppKit
import LeanTermCore
import Darwin
import SwiftTerm
import Synchronization

/// Cross-thread output signal for the PTY parse thread. It only touches atomics.
final class SessionActivityCounter: Sendable {
    private let output = Atomic<UInt64>(0)
    private let armed = Atomic<Bool>(false)

    var outputCount: UInt64 { output.load(ordering: .relaxed) }

    /// Counts one output batch. Returns true when the sampler should be woken, at most once per sample.
    func noteOutput() -> Bool {
        output.add(1, ordering: .relaxed)
        return armed.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged
    }

    func disarm() { armed.store(false, ordering: .relaxed) }
}

/// Everything window-level that a pane reports or asks for. `TerminalWindow` implements it.
@MainActor
protocol TerminalPaneHost: AnyObject {
    /// The pane is on screen (its window is visible and its tab selected).
    func isPaneVisible(_ pane: TerminalPane) -> Bool
    /// The pane is the focused pane of the key window of an active app.
    func isPaneBeingViewed(_ pane: TerminalPane) -> Bool
    /// Whether a shell exit may close the pane automatically (no quit in progress, no sheet to preserve).
    func permitsAutomaticClose(for pane: TerminalPane) -> Bool

    /// The pane may be rearranged now: the tab has several panes and is not zoomed.
    func paneAllowsReordering(_ pane: TerminalPane) -> Bool
    /// A drag that started on the pane's grip began, moved or ended at a point in window coordinates.
    func pane(_ pane: TerminalPane, gripDragged phase: PaneGripPhase, at windowPoint: NSPoint)

    /// Directory, remote location or foreground session changed: subtitle, tab label and represented URL.
    func paneDidChangeLocation(_ pane: TerminalPane)
    /// The pane's working directory changed (the window's represented URL).
    func paneDidChangeDirectory(_ pane: TerminalPane)
    /// The shell set a non-empty terminal title.
    func pane(_ pane: TerminalPane, didSetTitle title: String)
    /// Indicator, unseen state or session mark changed: tab mark.
    func paneDidChangeActivity(_ pane: TerminalPane)
    func paneDidChangeUnseenActivity(_ pane: TerminalPane)
    /// PTY output arrived while the sampler may be asleep.
    func paneDidReceiveOutput(_ pane: TerminalPane)
    /// `exitCode` is the status the shell reported when the command ended, if it did so within a moment of it.
    func pane(_ pane: TerminalPane, finishedLongCommandAfter duration: TimeInterval, exitCode: Int?)

    func pane(_ pane: TerminalPane, didSetStatus text: String)
    func pane(_ pane: TerminalPane, setRestartHidden hidden: Bool)
    func pane(_ pane: TerminalPane, didChangeDimensions text: String)
    func pane(_ pane: TerminalPane, didCopyRedacted removed: Int)
    /// The user flipped the find bar's "Aa" or ".*" toggle.
    func pane(_ pane: TerminalPane, didChangeFindMatchCase matchCase: Bool, regex: Bool)
    func paneDidDisableMultilinePasteConfirmation(_ pane: TerminalPane)

    /// The shell ended and the pane should go away (the closing state, or close-on-exit).
    func paneWantsClose(_ pane: TerminalPane)
    /// The shell ended; the app may be waiting for it.
    func paneDidTerminate(_ pane: TerminalPane)
    func pane(_ pane: TerminalPane, opensTerminalIn folder: URL)
}

/// One shell session: its terminal view, process lifecycle, activity tracking and working directory.
/// A `TerminalWindow` hosts one or more panes and aggregates their state.
@MainActor
final class TerminalPane: NSObject, LocalProcessTerminalViewDelegate {
    enum State { case starting, running, closing, exited, failed }
    let id = UUID()
    let terminal: LeanTerminalView
    /// Scanner and terminal; the window's footer stays outside.
    let view = NSView()
    weak var host: TerminalPaneHost?
    private let scanner = ActivityScannerView()
    private let scannerPulse = ScannerPulseView()
    private let grip = PaneGripView()
    private let statusMargin = CommandStatusView()
    private let find: FindController
    /// The terminal's top edge: the pane's padding, or just below the find bar while it is open.
    private var terminalTopClosed: NSLayoutConstraint!
    private var terminalTopOpen: NSLayoutConstraint!
    private let activityCounter = SessionActivityCounter()
    private var activityModel = SessionActivityModel()
    private(set) var finishedUnseen = false {
        didSet {
            if !finishedUnseen { finishedFailed = false }
            if finishedUnseen != oldValue { host?.paneDidChangeUnseenActivity(self) }
        }
    }
    /// The unseen finished command reported a non-zero exit status. Set just before `finishedUnseen`.
    private var finishedFailed = false
    var finishedFailedUnseen: Bool { finishedUnseen && finishedFailed }
    private(set) var bellUnseen = false { didSet { if bellUnseen != oldValue { host?.paneDidChangeUnseenActivity(self) } } }
    var hasUnseenActivity: Bool { finishedUnseen || bellUnseen }
    var activityIndicator: ActivityIndicator { activityModel.indicator }
    private var foregroundGroup: pid_t = 0
    private var foregroundLeaderPendingExec = false
    private var session = ForegroundSession.local
    private var remoteLocation: (host: String, path: String)?
    /// The last non-empty title the shell set.
    private(set) var terminalTitle: String?
    /// Footer state, shown by the window while this pane is focused.
    private(set) var statusText = ""
    private(set) var dimensionsText = ""
    private(set) var restartHidden = true
    private var fallback: DispatchWorkItem?
    private(set) var state: State = .starting
    private(set) var currentDirectory: String
    private var preferences: Preferences
    // Command status (OSC 133). All of it stays idle until the shell sends its first mark.
    private var shellMarkObservation: TerminalOscObservation?
    private var shellMarksSeen = false
    private var commandStartTime: TimeInterval?
    private var lastCommandEnd: (exitCode: Int, time: TimeInterval)?
    private var statusRefresh: DispatchWorkItem?
    private var statusRefreshTime: TimeInterval = 0
    /// Set by a finished command; the next refresh that shows its new bar fades it in.
    private var fadeInDeadline: TimeInterval?
    private var wasVisible = false
    private static let statusRefreshInterval: TimeInterval = 0.125
    private var theme: TerminalTheme
    private let launch: ShellLaunch
    private var didStart = false
    private var shellHasExecuted = false
    private(set) var terminationCount = 0
    /// Typed into the shell right after it starts (opened scripts and ssh links), like Terminal.app.
    var initialCommand: String?

    var live: Bool { state == .running || state == .starting || state == .closing }
    var folderName: String {
        currentDirectory == NSHomeDirectory() ? "~" : (currentDirectory == "/" ? "/" : URL(fileURLWithPath: currentDirectory).lastPathComponent)
    }
    var directoryForNewSession: String {
        refreshDirectory()
        return ShellLaunch.localDirectory(from: URL(fileURLWithPath: currentDirectory).absoluteString) ?? NSHomeDirectory()
    }
    /// About 20 columns by 4 rows of text plus the insets inside the pane view.
    var minimumSize: NSSize {
        let dimensions = terminal.terminalDimensions
        guard dimensions.cols > 0, dimensions.rows > 0 else { return NSSize(width: 200, height: 80) }
        let optimal = terminal.getOptimalFrameSize()
        return NSSize(width: optimal.width / CGFloat(dimensions.cols) * 20 + 28,
                      height: optimal.height / CGFloat(dimensions.rows) * 4 + 12)
    }

    /// Inactive split panes are drawn slightly faded.
    func setDimmed(_ dimmed: Bool) {
        let alpha: CGFloat = dimmed ? 0.8 : 1
        if terminal.alphaValue != alpha { terminal.alphaValue = alpha }
    }

    private func setStatus(_ text: String) {
        statusText = text
        host?.pane(self, didSetStatus: text)
    }
    private func setRestartHidden(_ hidden: Bool) {
        restartHidden = hidden
        host?.pane(self, setRestartHidden: hidden)
    }

    init(preferences: Preferences, directory: String?) {
        self.preferences = preferences
        theme = TerminalTheme(palette: preferences.palette,
                              dark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        launch = ShellLaunch(directory: directory)
        currentDirectory = launch.directory
        statusText = launch.usedFallback ? "Login shell unavailable · using zsh" : URL(fileURLWithPath: launch.executable).lastPathComponent
        let font = TerminalFont.make(name: preferences.fontName, size: preferences.fontSize)
        let cursor = Self.cursorStyle(for: preferences)
        terminal = LeanTerminalView(frame: .zero, font: font,
            options: TerminalOptions(cols: 110, rows: 32, cursorStyle: cursor, scrollback: preferences.scrollbackLines))
        terminal.lineSpacing = CGFloat(preferences.lineSpacing)
        terminal.cursorBlinkResetsOnInput = true
        find = FindController(terminal: terminal)
        super.init()
        terminal.processDelegate = self
        installOutputHandler()
        installShellMarkObserver()
        terminal.onBell = { [weak self] in self?.bellRang() }
        terminal.confirmsMultilinePaste = preferences.confirmMultilinePaste
        terminal.redactsCopies = preferences.redactCopies
        terminal.onCopyRedacted = { [weak self] removed in
            guard let self else { return }
            host?.pane(self, didCopyRedacted: removed)
        }
        terminal.onDisableMultilinePasteConfirmation = { [weak self] in
            guard let self else { return }
            host?.paneDidDisableMultilinePasteConfirmation(self)
        }
        terminal.pathDelegate = self
        terminal.bellStyle = .none
        // This remains the measured CoreGraphics/CoreText implementation.
        do { try terminal.setUseMetal(false) }
        catch { preconditionFailure("Cannot select CoreGraphics: \(error)") }
        terminal.translatesAutoresizingMaskIntoConstraints = false
        terminal.setAccessibilityLabel("Terminal session")
        view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(terminal)
        scanner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scanner)
        scannerPulse.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scannerPulse)
        grip.translatesAutoresizingMaskIntoConstraints = false
        grip.isAvailable = { [weak self] in self.map { $0.host?.paneAllowsReordering($0) ?? false } ?? false }
        grip.onDrag = { [weak self] phase, point in self.map { $0.host?.pane($0, gripDragged: phase, at: point) } }
        view.addSubview(grip)
        statusMargin.translatesAutoresizingMaskIntoConstraints = false
        statusMargin.colorForOutcome = { [weak self] in self?.theme.commandColor($0) ?? .labelColor }
        statusMargin.onSelect = { [weak self] promptRow in
            guard let self else { return }
            terminal.window?.makeFirstResponder(terminal)
            terminal.selectCommandOutput(promptRow: promptRow)
        }
        terminal.onScrolled = { [weak self] in
            self?.scheduleStatusRefresh()
            self?.find.updateHighlights()
        }
        view.addSubview(statusMargin)
        find.bar.setOptions(matchCase: preferences.findMatchCase, regex: preferences.findUseRegex)
        find.isPaneVisible = { [weak self] in self.map { $0.host?.isPaneVisible($0) ?? false } ?? false }
        find.onOptionsChanged = { [weak self] matchCase, regex in
            guard let self else { return }
            host?.pane(self, didChangeFindMatchCase: matchCase, regex: regex)
        }
        find.onVisibilityChanged = { [weak self] in
            guard let self else { return }
            let open = find.isOpen
            terminalTopClosed.isActive = !open
            terminalTopOpen.isActive = open
            view.layoutSubtreeIfNeeded()
        }
        view.addSubview(find.bar)
        terminalTopClosed = terminal.topAnchor.constraint(equalTo: view.topAnchor, constant: 12)
        terminalTopOpen = terminal.topAnchor.constraint(equalTo: find.bar.bottomAnchor, constant: 4)
        NSLayoutConstraint.activate([
            scanner.topAnchor.constraint(equalTo: view.topAnchor, constant: 5),
            scanner.heightAnchor.constraint(equalToConstant: 2),
            scanner.leadingAnchor.constraint(equalTo: terminal.leadingAnchor),
            scanner.trailingAnchor.constraint(equalTo: terminal.trailingAnchor),
            scannerPulse.topAnchor.constraint(equalTo: scanner.topAnchor),
            scannerPulse.heightAnchor.constraint(equalTo: scanner.heightAnchor),
            scannerPulse.leadingAnchor.constraint(equalTo: scanner.leadingAnchor),
            scannerPulse.trailingAnchor.constraint(equalTo: scanner.trailingAnchor),
            grip.topAnchor.constraint(equalTo: view.topAnchor),
            grip.heightAnchor.constraint(equalToConstant: PaneGripView.stripHeight),
            grip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            grip.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusMargin.topAnchor.constraint(equalTo: view.topAnchor),
            statusMargin.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            statusMargin.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusMargin.trailingAnchor.constraint(equalTo: terminal.leadingAnchor),
            terminalTopClosed,
            find.bar.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            find.bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            find.bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            terminal.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            terminal.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            terminal.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    /// Register the pane with the app before a shell can synchronously exit.
    func start(smoke: Bool = false) {
        guard !didStart, state == .starting else { return }
        didStart = true
        if smoke {
            terminal.startProcess(executable: "/bin/zsh", args: ["-f"], environment: launch.environment, currentDirectory: currentDirectory)
        } else {
            terminal.startProcess(executable: launch.executable, environment: launch.environment, execName: launch.execName, currentDirectory: currentDirectory)
        }
        if state == .starting { state = terminal.process.running ? .running : .failed }
        if state == .running, let initialCommand { terminal.send(txt: initialCommand + "\r") }
        refreshDirectory()
    }

    // MARK: Activity

    /// The key window of an active app with this pane on screen.
    private var isBeingViewed: Bool { host?.isPaneBeingViewed(self) ?? false }

    private func bellRang() {
        guard preferences.showTabActivity, !isBeingViewed else { return }
        bellUnseen = true
        renderActivity()
    }

    private func installOutputHandler() {
        let counter = activityCounter
        terminal.setProcessOutputHandler { [weak self] in
            guard counter.noteOutput() else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.terminal.outputArrived()
                    self.find.contentMayHaveChanged()
                    self.host?.paneDidReceiveOutput(self)
                    self.scheduleStatusRefresh()
                }
            }
        }
    }

    /// Samples the foreground job once. Returns whether another sample is needed.
    func sampleActivity(at time: TimeInterval) -> Bool {
        var foreground = false
        var group: pid_t = 0
        if let process = terminal.process, process.running {
            let current = tcgetpgrp(process.childfd)
            foreground = current > 0 && current != process.shellPid
            if foreground { group = current }
        }
        updateSession(group: group)
        if !foreground { refreshDirectory() }
        let sample = SessionActivitySample(
            foregroundJobRunning: foreground,
            alternateScreen: terminal.terminalInputStateSnapshot()?.isAlternateBuffer == true,
            outputCount: activityCounter.outputCount, time: time,
            remoteSession: session.isRemote)
        activityCounter.disarm()
        if case .finishedLongCommand(let duration)? = activityModel.record(sample), !isBeingViewed {
            let exitCode = lastCommandEnd.flatMap { ProcessInfo.processInfo.systemUptime - $0.time <= 2 ? $0.exitCode : nil }
            if preferences.showTabActivity {
                finishedFailed = preferences.showCommandStatus && (exitCode ?? 0) != 0
                finishedUnseen = true
            }
            host?.pane(self, finishedLongCommandAfter: duration, exitCode: exitCode)
        }
        if activityModel.indicator != .idle { finishedUnseen = false }
        renderActivity()
        return activityModel.needsPolling
    }

    func motionOptionsChanged() {
        scanner.motionOptionsChanged()
        terminal.setCursorStyle(Self.cursorStyle(for: preferences))
    }

    /// The blinking variants only when asked for and Reduce Motion is off; typing pauses the blink.
    private static func cursorStyle(for preferences: Preferences) -> CursorStyle {
        let blink = preferences.cursorBlink && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        switch preferences.cursor {
        case .bar: return blink ? .blinkBar : .steadyBar
        case .block: return blink ? .blinkBlock : .steadyBlock
        case .underline: return blink ? .blinkUnderline : .steadyUnderline
        }
    }

    /// Looks the foreground leader up once per job start, never per tick. A leader still named like the
    /// shell has been forked but may not have exec'd its command yet, so it is read again next sample.
    private func updateSession(group: pid_t) {
        guard group != foregroundGroup || foregroundLeaderPendingExec else { return }
        foregroundGroup = group
        let previous = session
        let leader = group > 0 ? ForegroundProcessReader.read(groupLeader: group) : nil
        foregroundLeaderPendingExec = leader?.name == URL(fileURLWithPath: launch.executable).lastPathComponent
        session = ForegroundSession(leader)
        if !session.isRemote { remoteLocation = nil }
        if session != previous { host?.paneDidChangeLocation(self) }
    }

    /// The colour of the first host rule matching the remote host (OSC 7 host first, then the ssh destination).
    private var hostTint: NSColor? {
        guard preferences.showSessionMarks, case .remote(_, let parsed) = session,
              let host = remoteLocation?.host ?? parsed,
              let color = Preferences.hostColor(for: host, in: preferences.hostColorRules) else { return nil }
        return theme.hostColor(color)
    }

    /// The session mark for the window's tab.
    var sessionMark: SessionMark {
        preferences.showSessionMarks ? session.mark(tint: hostTint) : .none
    }

    /// Subtitle text: the local folder, or the remote location while connected.
    var locationSubtitle: String {
        let local = Self.displayPath(currentDirectory)
        if !preferences.showSessionMarks { return local }
        switch session {
        case .local: return local
        case .root: return "root · " + local
        case .remote(let tool, let host):
            return remoteLocation.map { "\($0.host):\($0.path)" } ?? host.map { "\(tool) \($0)" } ?? tool
        }
    }

    /// The tab label when no custom name is set.
    var automaticTabLabel: String {
        if case .remote(_, let host) = session { return remoteLocation?.host ?? host ?? folderName }
        return folderName
    }

    var locationToolTip: String { remoteLocation.map { "\($0.host):\($0.path)" } ?? currentDirectory }

    func resetActivity() {
        activityModel.reset()
        foregroundGroup = 0; foregroundLeaderPendingExec = false
        session = .local
        remoteLocation = nil
        host?.paneDidChangeLocation(self)
        finishedUnseen = false
        bellUnseen = false
        commandStartTime = nil
        lastCommandEnd = nil
        renderActivity()
    }

    /// The window was focused or the shell was reset: nothing is unseen any more.
    func markSeen() {
        finishedUnseen = false
        bellUnseen = false
    }

    /// Updates the scanner only; the window re-renders its own marks.
    func renderScanner() {
        let visible = host?.isPaneVisible(self) ?? false
        scanner.setIndicator(preferences.showActivityScanner ? activityModel.indicator : .idle, visible: visible)
        scanner.setHostTint(hostTint)
        if visible != wasVisible {
            wasVisible = visible
            scheduleStatusRefresh()
            if visible { find.contentMayHaveChanged() }
        }
    }

    func renderActivity() {
        renderScanner()
        host?.paneDidChangeActivity(self)
    }

    // MARK: Preferences and theme

    func apply(_ value: Preferences) {
        let scrollbackChanged = value.scrollbackLines != preferences.scrollbackLines
        preferences = value
        if scrollbackChanged { terminal.changeScrollback(value.scrollbackLines) }
        if !value.showTabActivity { markSeen() }
        if !value.showCommandStatus {
            statusRefresh?.cancel(); statusRefresh = nil
            statusMargin.clear()
        }
        let font = TerminalFont.make(name: value.fontName, size: value.fontSize)
        if terminal.font != font { terminal.font = font }
        let spacing = CGFloat(value.lineSpacing)
        if terminal.lineSpacing != spacing { terminal.lineSpacing = spacing }
        terminal.optionAsMetaKey = value.optionAsMeta
        find.setOptions(matchCase: value.findMatchCase, regex: value.findUseRegex)
        terminal.confirmsMultilinePaste = value.confirmMultilinePaste
        terminal.redactsCopies = value.redactCopies
        terminal.setCursorStyle(Self.cursorStyle(for: value))
        scheduleStatusRefresh()
    }

    func applyTheme(_ theme: TerminalTheme) {
        self.theme = theme
        terminal.installColors(theme.ansi)
        terminal.nativeBackgroundColor = theme.background
        terminal.nativeForegroundColor = theme.foreground
        terminal.caretColor = theme.accent
        terminal.selectedTextBackgroundColor = theme.selection
        terminal.selectedTextForegroundColor = theme.foreground
        scanner.applyAccent(theme.phosphor)
        grip.applyTheme(theme)
        find.applyTheme(theme)
        statusMargin.colorForOutcome = { [weak self] in self?.theme.commandColor($0) ?? .labelColor }
        scheduleStatusRefresh()
        terminal.progressBarColor = theme.phosphor
        terminal.pathHighlightColors = PathHighlightColors(phosphor: theme.phosphor, background: theme.background,
                                                           foreground: theme.foreground, dark: theme.dark)
        renderActivity()
    }

    // MARK: Command status (OSC 133)

    /// Watches the shell's OSC 133 marks. The handler runs on SwiftTerm's delivery queue for every OSC
    /// sequence, so it only filters by code, parses the few bytes of an OSC 133 payload and hops to main.
    private func installShellMarkObserver() {
        shellMarkObservation = terminal.observeOscEvents { [weak self] event in
            guard event.code == 133 else { return }
            let mark = ShellMark(osc133: event.payload)
            guard mark != .other else { return }
            let time = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.shellMarkReceived(mark, at: time) }
            }
        }
    }

    private func shellMarkReceived(_ mark: ShellMark, at time: TimeInterval) {
        shellMarksSeen = true
        switch mark {
        case .commandStart:
            commandStartTime = time
        case .commandEnd(let exitCode):
            let duration = commandStartTime.map { time - $0 }
            commandStartTime = nil
            lastCommandEnd = exitCode.map { ($0, time) }
            if let exitCode, preferences.showCommandStatus, isBeingViewed,
               let pulse = CommandOutcome(exitCode: exitCode).pulse(after: duration) {
                scannerPulse.pulse(pulse == .failure ? theme.failure : theme.phosphor)
            }
            fadeInDeadline = time + 1
            scheduleStatusRefresh()
        case .promptStart, .other:
            scheduleStatusRefresh()
        }
    }

    /// Coalesces every trigger (output, scrolling, resize, theme, marks) into one refresh, at most about
    /// 8 times a second, using a single pending work item and no timer. Does nothing until the shell has
    /// sent an OSC 133 mark or while the preference is off.
    private func scheduleStatusRefresh() {
        guard shellMarksSeen, preferences.showCommandStatus, statusRefresh == nil else { return }
        let wait = max(0, statusRefreshTime + Self.statusRefreshInterval - ProcessInfo.processInfo.systemUptime)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refreshCommandStatus() }
        }
        statusRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    private func refreshCommandStatus() {
        statusRefresh = nil
        let now = ProcessInfo.processInfo.systemUptime
        statusRefreshTime = now
        guard preferences.showCommandStatus, host?.isPaneVisible(self) == true,
              let viewport = terminal.semanticViewport, let metrics = terminal.cellMetrics() else {
            statusMargin.clear()
            return
        }
        let spans = terminal.commandSpans(in: viewport.top..<min(viewport.total, viewport.top + viewport.rows))
        let bars = CommandStatusLayout.bars(spans: spans, viewportTop: viewport.top, visibleRows: viewport.rows)
        // The terminal's rows start at its top edge; the margin view spans the pane's full height.
        let originY = view.bounds.height - terminal.frame.maxY
        let fade = fadeInDeadline.map { now < $0 } ?? false
        if statusMargin.show(bars, originY: originY, rowHeight: metrics.height, fadeInNewest: fade) || !fade {
            fadeInDeadline = nil
        }
    }

    // MARK: Shutdown

    /// Keep the PTY/view alive until SwiftTerm has reaped the child and drained output.
    /// Only called after synchronous launch returns. No PID is captured or signalled here.
    func beginShutdown() {
        guard live, state != .closing else { return }
        state = .closing
        setStatus("Closing session…")
        terminal.isHidden = false
        terminal.process.terminate(signal: SIGHUP)
        let session = id
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.id == session, self.state == .closing else { return }
            self.terminal.process.terminate(signal: SIGKILL)
        }
        fallback = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: work)
    }

    func cancelShutdownFallback() {
        fallback?.cancel(); fallback = nil
    }

    // MARK: Process delegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        dimensionsText = "\(newCols) × \(newRows)"
        scheduleStatusRefresh()
        find.contentMayHaveChanged()
        host?.pane(self, didChangeDimensions: dimensionsText)
    }
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        let clean = String(title.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(120))
        if !clean.isEmpty {
            terminalTitle = clean
            host?.pane(self, didSetTitle: clean)
        }
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        if let path = ShellLaunch.localDirectory(from: directory) {
            currentDirectory = path
            host?.paneDidChangeDirectory(self)
            host?.paneDidChangeLocation(self)
        } else if session.isRemote, let location = ShellLaunch.remoteDirectory(from: directory) {
            remoteLocation = location
            host?.paneDidChangeLocation(self)
            renderActivity()
        }
    }

    func refreshDirectory() {
        if didStart, let process = terminal.process, process.running {
            // Before exec, the forked child can still be in the app's working directory.
            if !shellHasExecuted {
                shellHasExecuted = ForegroundProcessReader.hasExecuted(process.shellPid)
            }
            if shellHasExecuted, let path = ForegroundProcessReader.workingDirectory(of: process.shellPid), path != currentDirectory {
                currentDirectory = path
                host?.paneDidChangeDirectory(self)
            }
        }
        host?.paneDidChangeLocation(self)
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        // The window may be released by the close below; keep it for the final callback.
        let host = host
        terminationCount += 1
        resetActivity()
        let wasClosing = state == .closing
        state = .exited
        cancelShutdownFallback()
        setStatus(exitCode == 0 ? "Session ended" : "Session ended · \(exitCode.map(String.init) ?? "signal")")
        setRestartHidden(false)
        // Preserve any outstanding close/quit sheet. Cancel must keep its window.
        if wasClosing || (preferences.closeTabOnShellExit && host?.permitsAutomaticClose(for: self) == true) {
            host?.paneWantsClose(self)
        }
        host?.paneDidTerminate(self)
    }
    func processFailedToStart(source: TerminalView, error: LocalProcessError) {
        state = .failed
        resetActivity()
        setStatus("Couldn’t start the shell")
        setRestartHidden(false)
    }

    func clearScreenAndScrollback() {
        terminal.selectNone()
        // Local parser output only: never send a control key/command to the shell.
        // Keep terminal modes and the configured history capacity intact.
        terminal.feed(text: "\u{1B}[H\u{1B}[2J")
        terminal.clearScrollback()
    }

    private static func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

extension TerminalPane: TerminalPathDelegate {
    /// The foreground job, read fresh: the polled value can lag a click by one sample.
    private func refreshForeground() -> Bool {
        guard let process = terminal.process, process.running else { return false }
        let current = tcgetpgrp(process.childfd)
        let job = current > 0 && current != process.shellPid
        updateSession(group: job ? current : 0)
        return job
    }

    var pathsAreRemote: Bool {
        _ = refreshForeground()
        return session.isRemote
    }

    func resolvePath(_ detected: DetectedPath) -> ResolvedPath? {
        FileOpener.resolve(detected, relativeTo: directoryForNewSession)
    }

    func hoverHint(for path: ResolvedPath) -> String {
        guard path.isDirectory else { return FileOpener.hoverHint(for: path, with: preferences.fileOpener) }
        return state == .running && !refreshForeground() && !session.isRemote ? "cd here · ⇧ new tab" : "Open in new tab"
    }

    func openPath(_ path: ResolvedPath, inNewTab: Bool) {
        guard path.isDirectory else {
            FileOpener.open(path, with: preferences.fileOpener)
            return
        }
        // Typing `cd` is only safe when the shell is waiting at its prompt.
        if !inNewTab, state == .running, !refreshForeground(), !session.isRemote {
            terminal.send(txt: "\u{15}cd -- " + ShellEscape.path(path.url.path) + "\r")
        } else {
            host?.pane(self, opensTerminalIn: path.url)
        }
    }
}

private extension ForegroundSession {
    var isRemote: Bool {
        if case .remote = self { return true }
        return false
    }

    func mark(tint: NSColor?) -> SessionMark {
        switch self {
        case .local: return .none
        case .root: return .root
        case .remote(let tool, let host):
            return .remote(host.map { "Connected to \($0) over \(tool)" } ?? "Remote session over \(tool)", tint: tint)
        }
    }
}
