import AppKit
import SwiftTerm

// A measurement window, not the eventual LeanTerm interface.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, LocalProcessTerminalViewDelegate {
    private var window: NSWindow!
    private var terminal: LocalProcessTerminalView!

    private func argument(_ key: String) -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: key), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit LeanTerm Bench", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu

        let options = TerminalOptions(cols: 120, rows: 40, cursorStyle: .steadyBar, scrollback: 10_000)
        terminal = LocalProcessTerminalView(frame: .zero, font: NSFont(name: "Menlo", size: 13), options: options)
        terminal.processDelegate = self
        terminal.bellStyle = .none
        terminal.nativeForegroundColor = NSColor(white: 0.92, alpha: 1)
        terminal.nativeBackgroundColor = NSColor(white: 0.08, alpha: 1)
        let renderer = argument("--renderer") ?? "cg"
        do {
            terminal.metalBufferingMode = .perFrameAggregated
            try terminal.setUseMetal(renderer == "metal")
        } catch {
            fputs("Requested renderer unavailable: \(error)\n", stderr)
            NSApp.terminate(nil)
            return
        }
        let frame = terminal.getOptimalFrameSize()
        terminal.frame = frame
        terminal.autoresizingMask = [.width, .height]
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "LeanTerm Bench — \(renderer)"
        window.contentView = terminal
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(terminal)
        NSApp.activate(ignoringOtherApps: true)

        if let infoPath = argument("--info") {
            let dimensions = terminal.terminalDimensions
            let info: [String: Any] = [
                "pid": ProcessInfo.processInfo.processIdentifier,
                "renderer": terminal.isUsingMetalRenderer ? "metal" : "coregraphics",
                "renderLoop": terminal.isUsingRenderLoop,
                "cols": dimensions.cols, "rows": dimensions.rows,
                "font": terminal.font.fontName, "fontSize": terminal.font.pointSize,
                "screenHz": window.screen?.maximumFramesPerSecond ?? 0,
                "screenScale": window.backingScaleFactor
            ]
            if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: infoPath))
            }
        }

        let environment = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "TERM=xterm-256color", "LANG=en_US.UTF-8", "PS1=leanterm> "]
        if let workload = argument("--workload") {
            var args = [workload, "--output", argument("--output") ?? "/tmp/leanterm-result.json"]
            for option in ["--gate", "--delay", "--hold", "--soak-seconds"] {
                if let value = argument(option) { args += [option, value] }
            }
            terminal.startProcess(executable: "/usr/bin/python3", args: args, environment: environment)
        } else {
            terminal.startProcess(executable: "/bin/zsh", args: ["-f"], environment: environment)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {}
    func processFailedToStart(source: TerminalView, error: LocalProcessError) {
        fputs("PTY launch failed: \(error)\n", stderr)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
