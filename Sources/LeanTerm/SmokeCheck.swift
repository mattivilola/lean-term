import AppKit
import LeanTermCore

/// An opt-in, bounded native integration check. Normal sessions never run this task.
@MainActor
final class SmokeCheck {
    private weak var app: AppDelegate?
    private let report: URL
    private var checks: [String] = []
    private struct Failure: Error { let message: String }

    init(app: AppDelegate, report: String) {
        self.app = app; self.report = URL(fileURLWithPath: report)
    }

    func start() {
        Task { @MainActor in
            do {
                try await run()
                finish(passed: true)
            } catch {
                checks.append("FAILED: \(error)")
                if let app {
                    for session in Array(app.sessions.values) where session.live { session.beginShutdown() }
                    try? await wait { !app.sessions.values.contains(where: \.live) }
                }
                finish(passed: false)
            }
        }
    }

    private func run() async throws {
        guard let app, let first = app.newTerminal(smoke: true) else { throw Failure(message: "No native session") }
        try expect(!first.terminal.isUsingMetalRenderer, "CoreGraphics selected")
        first.terminal.send(txt: "printf '\\033[32mLEAN_TERM_RUNTIME_%s\\033[0m · café 日本語 👋\\n' 'OK'\r")
        try await wait { first.terminal.findNext("LEAN_TERM_RUNTIME_OK") }
        try expect(first.terminal.findNext("café 日本語"), "PTY echo, ANSI and Unicode output searchable")
        let before = first.terminal.terminalDimensions
        first.window?.setContentSize(NSSize(width: 780, height: 480))
        first.window?.contentView?.layoutSubtreeIfNeeded()
        try expect(first.terminal.terminalDimensions.cols != before.cols, "Native resize reaches the terminal")
        for mode in Preferences.Appearance.allCases {
            for palette in Preferences.Palette.allCases {
                var value = app.preferences
                value.appearance = mode; value.palette = palette; value.fontSize = 15
                app.updatePreferences(value)
                try expect(first.terminal.font.pointSize == 15 && !first.terminal.isUsingMetalRenderer,
                           "\(mode.title)/\(palette.title) applies without changing renderer")
            }
        }
        let find = NSMenuItem(); find.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        first.terminal.performFindPanelAction(find)
        let hide = NSMenuItem(); hide.tag = NSTextFinder.Action.hideFindInterface.rawValue
        first.terminal.performTextFinderAction(hide)
        first.terminal.clearScrollback()
        try expect(first.terminal.findNext("LEAN_TERM_RUNTIME_OK"), "Clear Scrollback preserves the visible screen")
        first.terminal.send(txt: "exit\r")
        try await wait { first.state == .exited }
        try expect(first.terminationCount == 1, "Shell exit callback delivered once after reap")
        first.window?.close()

        let savedFrame = WindowPlacement(defaults: app.defaults)?.fitted(to: NSScreen.screens.map(\.visibleFrame))
        guard let resistant = app.newTerminal(smoke: true) else { throw Failure(message: "No resistant session") }
        try expect(savedFrame != nil && resistant.window?.frame == savedFrame,
                   "New window restores the saved position and size")
        resistant.terminal.send(txt: "trap '' HUP TERM; printf 'LEAN_TERM_RESIST_%s\\n' 'READY'; while true; do sleep 1; done\r")
        try await wait { resistant.terminal.findNext("LEAN_TERM_RESIST_READY") }
        resistant.beginShutdown()
        try await wait { resistant.state == .exited }
        try expect(resistant.terminationCount == 1, "HUP/TERM-resistant child force-closes through the safe reaper")

        guard let a = app.newTerminal(smoke: true), let b = app.newTerminal(tabOf: a, smoke: true) else {
            throw Failure(message: "No tab group")
        }
        try expect(a.window?.tabGroup === b.window?.tabGroup && a.window?.tabbedWindows?.count == 2,
                   "Two native tabs own independent sessions")
        guard let c = app.newTerminal(smoke: true) else { throw Failure(message: "No independent window") }
        a.window?.setFrame(CGRect(x: 50, y: 80, width: 700, height: 480), display: true)
        a.window?.makeKeyAndOrderFront(nil)
        c.window?.setFrame(CGRect(x: 100, y: 140, width: 820, height: 540), display: true)
        c.window?.makeKeyAndOrderFront(nil)
        try await wait { app.activeSession === c }
        c.savePlacement()
        let current = WindowPlacement(defaults: app.defaults)
        a.savePlacement() // A late callback from a background window must not win.
        try expect(current?.frame == c.window?.frame && WindowPlacement(defaults: app.defaults) == current,
                   "Only the last active window updates saved placement")
        a.beginShutdown(); b.beginShutdown(); c.beginShutdown()
        try await wait { a.state == .exited && b.state == .exited && c.state == .exited }
        try expect(a.terminationCount == 1 && b.terminationCount == 1 && c.terminationCount == 1 && app.sessions.isEmpty,
                   "Multiple sessions close and release without duplicate callbacks")
    }

    private func expect(_ value: Bool, _ description: String) throws {
        guard value else { throw Failure(message: description) }
        checks.append(description)
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Failure(message: "Timed out waiting for native session state")
    }
    private func finish(passed: Bool) {
        let result: [String: Any] = ["passed": passed, "checks": checks, "renderer": "CoreGraphics",
                                   "version": "0.1.0", "sessionCount": app?.sessions.count ?? -1]
        do {
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: report, options: .atomic)
        } catch { fputs("Could not write native smoke report: \(error)\n", stderr) }
        NSApp.terminate(nil)
    }
}
