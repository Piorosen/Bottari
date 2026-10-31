/// Which build this is: the one from GitHub, or the App Store edition, which
/// runs in the App Sandbox (target "Bottari App Store", flag APP_STORE).
enum AppEdition {
    #if APP_STORE
    static let isAppStore = true
    #else
    static let isAppStore = false
    #endif
}
