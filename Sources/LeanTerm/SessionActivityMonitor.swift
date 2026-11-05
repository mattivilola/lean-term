import AppKit
import LeanTermCore

/// Samples terminal sessions only while something is happening. When every session is idle there is no
/// timer at all; PTY output (see `TerminalWindow`) wakes it again.
@MainActor
final class SessionActivityMonitor {
    var sessions: () -> [TerminalWindow] = { [] }
    var enabled = false {
        didSet {
            guard enabled != oldValue else { return }
            if enabled {
                wake()
            } else {
                stopTimer()
                for session in sessions() { session.resetActivity() }
            }
        }
    }
    var isPolling: Bool { timer != nil }

    private var timer: Timer?
    // Observers live for the app's lifetime (the monitor is owned by AppDelegate), so they are never removed.
    private var observers: [NSObjectProtocol] = []

    init() {
        let changed: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for session in self.sessions() { session.motionOptionsChanged() }
            }
        }
        observers = [
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: nil, queue: .main, using: changed),
            NotificationCenter.default.addObserver(
                forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main, using: changed)
        ]
    }

    func wake() {
        guard enabled, timer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.1
        self.timer = timer
        RunLoop.main.add(timer, forMode: .default)
        tick()
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        var needsPolling = false
        for session in sessions() where session.sampleActivity(at: now) { needsPolling = true }
        if !needsPolling { stopTimer() }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
