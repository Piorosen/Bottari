import AppKit
@testable import Bottari
import Testing

struct TestHostTests {
    @Test func theAppHostingTheTestsOpensNothingOfTheUsers() {
        #expect(Launch.hostsTests)
        #expect(AppDelegate.leavesUserDataAlone)
        #expect(NSApp.windows.isEmpty)
    }
}
