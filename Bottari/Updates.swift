import Observation
#if !APP_STORE
import Sparkle
#endif

/// Sparkle, for builds that know where updates come from and the key they are
/// signed with: the releases made by `scripts/release.sh`. Others never check,
/// and the App Store edition has no Sparkle at all: the App Store updates it.
@Observable
final class Updates {
    #if APP_STORE
    static let shared = Updates()
    let isAvailable = false
    var automaticallyChecks = false
    func checkForUpdates() {}
    #else
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
    #endif
}
