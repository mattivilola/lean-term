import AppKit
import SwiftTerm
import Synchronization

/// Terminal view that reports the bell to the app without making any sound.
final class LeanTerminalView: LocalProcessTerminalView {
    private let bellPending = Atomic<Bool>(false)
    /// Called on the main thread, at most once per burst of bells.
    var onBell: (@MainActor () -> Void)?

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
}
