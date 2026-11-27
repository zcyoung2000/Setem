import AppKit
import Sparkle

/// Owns the Sparkle controller for the menu-bar application.
///
/// The feed URL and Ed25519 public key are in the generated Info.plist. Keeping
/// the controller alive for the entire application lifetime is required because
/// Sparkle retains its updater delegates weakly.
@MainActor
final class UpdateManager {
    private let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func start() {
        controller.startUpdater()
    }

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
