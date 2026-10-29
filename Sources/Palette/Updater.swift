import AppKit
import Sparkle

/// Sparkle auto-updates. Only active in builds whose Info.plist has a feed URL
/// and an EdDSA public key, so `swift run` and test builds never check.
final class Updater: NSObject, SPUStandardUserDriverDelegate {
    static let shared = Updater()

    private var controller: SPUStandardUpdaterController?

    /// Version a scheduled check found, shown in the menu until installed.
    private(set) var pendingVersion: String?

    var isAvailable: Bool { controller != nil }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    func start() {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let feed = info["SUFeedURL"] as? String, !feed.isEmpty,
              let key = info["SUPublicEDKey"] as? String, !key.isEmpty else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    func checkForUpdates() {
        // Menu-bar apps are never frontmost on their own; bring the update window forward.
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    // MARK: SPUStandardUserDriverDelegate

    // Scheduled checks don't open a window over the terminal; the menu shows the update instead.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        guard !state.userInitiated else { return }
        pendingVersion = update.displayVersionString
    }

    func standardUserDriverWillFinishUpdateSession() {
        pendingVersion = nil
    }
}
