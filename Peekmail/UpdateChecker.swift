import Sparkle

/// Owns Sparkle's standard updater for the lifetime of the application.
final class UpdateChecker {
    static let shared = UpdateChecker()

    let updaterController: SPUStandardUpdaterController

    private init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkManually() {
        updaterController.checkForUpdates(nil)
    }
}
