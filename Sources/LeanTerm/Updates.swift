import AppKit
import Sparkle

/// Sparkle owns scheduling, validation, downloading and installation. Its Apple
/// quit event uses the same session-safe NSApplication termination path as Cmd-Q.
@MainActor
final class Updates: NSObject, NSMenuItemValidation {
    private(set) var controller: SPUStandardUpdaterController?
    private var started = false
    var available: Bool { controller != nil }
    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }
    var automaticallyDownloads: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue }
    }

    init(disabled: Bool) {
        super.init()
        guard !disabled, Bundle.main.object(forInfoDictionaryKey: "LeanTermReleaseBuild") as? Bool == true else { return }
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    }

    /// Starts Sparkle once, off the launch path; the menu item and settings exist before this runs.
    func start() {
        guard let updater = controller?.updater, !started else { return }
        started = true
        do {
            try updater.start()
            if updater.automaticallyChecksForUpdates { updater.checkForUpdatesInBackground() }
        } catch {
            NSLog("Lean Term updater could not start: %@", error.localizedDescription)
        }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        start()
        controller?.checkForUpdates(sender)
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { controller?.updater.canCheckForUpdates ?? false }
    func restoreDefaults() {
        automaticallyChecks = true
        automaticallyDownloads = true
    }
}
