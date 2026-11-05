import AppKit
import Darwin

@main
enum LeanTermMain {
    @MainActor static func main() {
        guard let path = Bundle.main.resourceURL?.appendingPathComponent("Build.lock").path else { return }
        let lock = open(path, O_RDONLY | O_CLOEXEC)
        guard lock >= 0, flock(lock, LOCK_SH | LOCK_NB) == 0 else {
            if lock >= 0 { close(lock) }
            fputs("Lean Term is being rebuilt. Try opening it again when the build finishes.\n", stderr)
            return
        }
        defer { close(lock) }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
