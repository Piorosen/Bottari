import Foundation
import Testing
@testable import BottariCore

@Suite struct UserHomeTests {
    @Test func isTheAccountsHomeFolder() {
        // Tests run outside the sandbox, where both agree.
        #expect(UserHome.path == NSHomeDirectory())
    }

    @Test func expandsAndAbbreviatesTheTilde() {
        #expect(UserHome.expand("~") == UserHome.path)
        #expect(UserHome.expand("~/.ssh/id_ed25519") == UserHome.path + "/.ssh/id_ed25519")
        #expect(UserHome.expand("/etc/hosts") == "/etc/hosts")
        #expect(UserHome.expand("~other/x") == "~other/x")
        #expect(UserHome.abbreviate(UserHome.path + "/.ssh/config") == "~/.ssh/config")
        #expect(UserHome.abbreviate(UserHome.path) == "~")
        // A sibling whose name merely starts the same is not inside.
        #expect(UserHome.abbreviate(UserHome.path + "2/x") == UserHome.path + "2/x")
    }

    @Test func everythingIsReachableOutsideTheSandbox() {
        #expect(!FolderAccess.isSandboxed)
        let access = FolderAccess(defaults: UserDefaults(suiteName: "UserHomeTests-\(UUID())")!)
        #expect(access.covers("/private/etc"))
        access.restore()
        access.remember(URL(fileURLWithPath: "/tmp"))
        #expect(access.paths.isEmpty)
    }
}
