import AppKit
import Sparkle

/// Sparkle owns scheduling, validation, downloading and installation. Its Apple
/// quit event uses the same session-safe NSApplication termination path as Cmd-Q.
@MainActor
final class Updates: NSObject, NSMenuItemValidation {
    private(set) var controller: SPUStandardUpdaterController?
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
        let updater = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        do {
            try updater.updater.start()
            controller = updater
            if updater.updater.automaticallyChecksForUpdates {
                updater.updater.checkForUpdatesInBackground()
            }
        } catch {
            NSLog("Lean Term updater could not start: %@", error.localizedDescription)
        }
    }

    @objc func checkForUpdates(_ sender: Any?) { controller?.checkForUpdates(sender) }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { controller?.updater.canCheckForUpdates ?? false }
    func restoreDefaults() {
        automaticallyChecks = true
        automaticallyDownloads = true
    }
}
