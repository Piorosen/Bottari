import AppKit
@testable import Bottari
import Testing

struct TestHostTests {
    /// The tests run inside the app, in the user's own container.
    @Test func theAppHostingTheTestsOpensNothingOfTheUsers() {
        #expect(Launch.hostsTests)
        #expect(AppDelegate.leavesUserDataAlone)
        #expect(NSApp.windows.isEmpty)
    }
}
