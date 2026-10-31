import Testing
@testable import BottariSFTP

@Suite struct SSHConfigTests {
    func config(_ text: String, files: [String: String] = [:]) -> SSHConfig {
        SSHConfig(text: text, directory: "/Users/me/.ssh", home: "/Users/me", localUser: "me") { files[$0] }
    }

    @Test func listsConcreteHostsWithTheirSettings() {
        let parsed = config("""
        # Work
        Host prod-web
          HostName 203.0.113.10
          User deploy
          IdentityFile ~/.ssh/id_ed25519

        Host dev-api staging-web
          HostName %h.internal
          Port 2222

        Host *.internal !secret.internal
          User ops
        """)

        #expect(parsed.aliases == ["prod-web", "dev-api", "staging-web"])
        let prod = parsed.resolve("prod-web")
        #expect(prod.hostName == "203.0.113.10")
        #expect(prod.user == "deploy")
        #expect(prod.port == 22)
        #expect(prod.identityFiles == ["/Users/me/.ssh/id_ed25519"])
        let dev = parsed.resolve("dev-api")
        #expect(dev.hostName == "dev-api.internal")
        #expect(dev.port == 2222)
        #expect(dev.user == nil)
    }

    @Test func firstValueWinsButIdentityFilesAccumulate() {
        let parsed = config("""
        Host gpu-box
          User ml
          IdentityFile ~/.ssh/gpu
        Host *
          User nobody
          Port 22
          IdentityFile ~/.ssh/id_ed25519
        """)

        let gpu = parsed.resolve("gpu-box")
        #expect(gpu.user == "ml")
        #expect(gpu.identityFiles == ["/Users/me/.ssh/gpu", "/Users/me/.ssh/id_ed25519"])
        #expect(parsed.resolve("anything-else").user == "nobody")
    }

    @Test func settingsBeforeTheFirstHostApplyEverywhere() {
        let parsed = config("""
        User early
        Host box
          User late
        """)
        #expect(parsed.resolve("box").user == "early")
    }

    @Test func wildcardsAndNegation() {
        #expect(SSHConfig.matches("db.internal", patterns: ["*.internal"]))
        #expect(SSHConfig.matches("web1", patterns: ["web?"]))
        #expect(!SSHConfig.matches("secret.internal", patterns: ["*.internal", "!secret.internal"]))
        #expect(!SSHConfig.matches("other", patterns: ["!secret"]))
    }

    @Test func proxyJumpListsHopsAndNoneClearsThem() {
        let parsed = config("""
        Host inside
          ProxyJump bastion, admin@relay.example.com:2200
        Host direct
          ProxyJump none
        Host *
          ProxyJump bastion
        """)
        #expect(parsed.resolve("inside").proxyJump == ["bastion", "admin@relay.example.com:2200"])
        #expect(parsed.resolve("direct").proxyJump.isEmpty)
        #expect(parsed.resolve("other").proxyJump == ["bastion"])
    }

    @Test func equalsSignsQuotesAndComments() {
        let parsed = config("""
        Host=quoted
          HostName="203.0.113.5" # trailing comment
          IdentityFile "~/Library/My Keys/id_ed25519"
          IdentityAgent "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
        """)
        let host = parsed.resolve("quoted")
        #expect(host.hostName == "203.0.113.5")
        #expect(host.identityFiles == ["/Users/me/Library/My Keys/id_ed25519"])
        #expect(host.identityAgent == "/Users/me/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock")
    }

    @Test func anEqualsSignWithSpacesAroundIt() {
        let parsed = config("""
        Host spaced
          HostName = 10.0.0.5
          Port = 2222
          User =deploy
          SetEnv KEY=value
        """)
        let host = parsed.resolve("spaced")
        #expect(host.hostName == "10.0.0.5")
        #expect(host.port == 2222)
        #expect(host.user == "deploy")
    }

    @Test func linesAfterAnIncludeStayWithTheirOwnBlock() {
        let parsed = config(
            """
            Include orbstack/config
            User me
            IdentityFile ~/.ssh/work

            Host gpu
              Include gpu/a.conf
              Port 2200
            """,
            files: [
                "/Users/me/.ssh/orbstack/config": "Host orb\n  HostName localhost\n",
                "/Users/me/.ssh/gpu/a.conf": "User trainer\nHost other\n  User wrong\n",
            ]
        )
        // The global settings below the Include reach every host, not just "orb".
        #expect(parsed.resolve("anything").user == "me")
        #expect(parsed.resolve("orb").identityFiles == ["/Users/me/.ssh/work"])
        // Inside "Host gpu", the included file counts for gpu only.
        #expect(parsed.resolve("gpu").port == 2200)
        #expect(parsed.resolve("other").user == "me")
    }

    @Test func percentTokensExpandInIdentityFiles() {
        let parsed = config("""
        Host box
          HostName box.example.com
          User admin
          IdentityFile %d/.ssh/%r@%h
        """)
        #expect(parsed.resolve("box").identityFiles == ["/Users/me/.ssh/admin@box.example.com"])
    }

    @Test func includeInlinesOtherFilesRelativeToSshDirectory() {
        let parsed = config(
            """
            Include orbstack/config
            Host mine
              User me
            """,
            files: ["/Users/me/.ssh/orbstack/config": "Host orb\n  HostName localhost\n  Port 32222\n"]
        )
        #expect(parsed.aliases == ["orb", "mine"])
        #expect(parsed.resolve("orb").port == 32222)
    }

    @Test func matchBlocksApplyWhenTheirConditionsHold() {
        let parsed = config("""
        Host box
          HostName box.example.com
        Match host *.example.com
          User fromHost
        Match originalhost other !user root
          User fromOriginal
        Match exec "true"
          Port 2222
        Match !localuser me
          Port 2200
        Match all
          IdentityFile ~/.ssh/everyone
        """)
        #expect(parsed.aliases == ["box"])
        let box = parsed.resolve("box")
        #expect(box.user == "fromHost")
        // `exec` is never run, so its block does not apply.
        #expect(box.port == 22)
        #expect(box.identityFiles == ["/Users/me/.ssh/everyone"])
        #expect(parsed.resolve("other").user == "fromOriginal")
    }

    @Test func matchLocalNetworkChecksTheMacsAddresses() {
        let text = """
        Match localnetwork 10.1.0.0/16,!10.1.9.0/24
          ProxyJump none
        Host *
          ProxyJump bastion
        """
        func resolve(_ addresses: [String]) -> [String] {
            SSHConfig(text: text, directory: "/Users/me/.ssh", home: "/Users/me", localUser: "me", readFile: { _ in nil }, localAddresses: { addresses })
                .resolve("db").proxyJump
        }
        #expect(resolve(["10.1.2.3"]).isEmpty)
        #expect(resolve(["192.168.0.5", "fe80::1"]) == ["bastion"])
        #expect(resolve(["10.1.9.7"]) == ["bastion"])
    }

    @Test func proxyCommandKeepsTheWholeLineAndRulesOutProxyJump() {
        let parsed = config("""
        Host tunnel
          ProxyCommand=cloudflared access ssh --hostname %h  
          ProxyJump bastion
        Host jumped
          ProxyJump bastion
          ProxyCommand nc %h %p
        Host plain
          ProxyCommand none
        """)
        #expect(parsed.resolve("tunnel").proxyCommand == "cloudflared access ssh --hostname %h")
        #expect(parsed.resolve("tunnel").proxyJump.isEmpty)
        #expect(parsed.resolve("jumped").proxyCommand == nil)
        #expect(parsed.resolve("jumped").proxyJump == ["bastion"])
        #expect(parsed.resolve("plain").proxyCommand == nil)
    }

    @Test func addressRanges() {
        #expect(IPRange("10.0.0.0/8")?.contains("10.255.1.1") == true)
        #expect(IPRange("10.0.0.0/8")?.contains("11.0.0.1") == false)
        #expect(IPRange("192.168.1.0/25")?.contains("192.168.1.127") == true)
        #expect(IPRange("192.168.1.0/25")?.contains("192.168.1.128") == false)
        #expect(IPRange("fd00::/8")?.contains("fd12:3456::1") == true)
        #expect(IPRange("fd00::/8")?.contains("10.0.0.1") == false)
        #expect(IPRange("not an address") == nil)
    }
}
