import Observation
import Sparkle

/// Sparkle, for builds that know where updates come from and the key they are
/// signed with: the releases made by `scripts/release.sh`. Others never check.
@Observable
final class Updates {
    static let shared = Updates()

    @ObservationIgnored private let controller: SPUStandardUpdaterController?

    private init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let key = info["SUPublicEDKey"] as? String ?? ""
        let feed = info["SUFeedURL"] as? String ?? ""
        controller = key.isEmpty || feed.isEmpty || AppDelegate.isRenderingSnapshots
            ? nil
            : SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        automaticallyChecks = controller?.updater.automaticallyChecksForUpdates ?? false
    }

    var isAvailable: Bool { controller != nil }

    var automaticallyChecks: Bool {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticallyChecks }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
