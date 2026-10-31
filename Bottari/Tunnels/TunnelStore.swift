import AppKit
import BottariCore
import BottariSFTP
import Foundation
import Observation

/// A saved way through an SSH server: for Bottari only, for apps that use a
/// proxy, or for the whole Mac.
struct TunnelProfile: Codable, Identifiable, Hashable {
    enum Mode: String, Codable, CaseIterable {
        /// Bottari's own connections to matching hosts go through the server.
        case bottariOnly
        /// SOCKS5 and HTTP proxies on this Mac, with a PAC file.
        case proxy
        /// sshuttle diverts every TCP connection to matching ranges.
        case wholeMac

        /// sshuttle needs sudo and Terminal, out of reach from the App Sandbox.
        static var available: [Mode] {
            FolderAccess.isSandboxed ? [.bottariOnly, .proxy] : allCases
        }
    }

    /// Changing the Mac's proxy settings takes an administrator prompt, which
    /// the App Sandbox does not allow.
    static var canApplySystemProxy: Bool { !FolderAccess.isSandboxed }

    var id = UUID()
    var name = String(localized: "새 터널")
    var siteID: SavedSite.ID?
    var mode = Mode.proxy
    var routes = "10.0.0.0/8\n*.internal"
    var socksPort = 1080
    var httpEnabled = true
    var httpPort = 8118
    var appliesSystemProxy = false
    /// sshuttle --dns: names are resolved at the server.
    var remoteDNS = true
    var reconnects = true
    var reconnectsOnWake = true

    var rules: RouteRules { RouteRules.parse(routes).rules }
    var invalidRoutes: [String] { RouteRules.parse(routes).invalid }
    var pacURL: String { "http://127.0.0.1:\(httpPort)/bottari.pac" }
}

enum TunnelState: Equatable {
    case off
    case connecting
    case on(String)
    case failed(String)

    var isActive: Bool {
        switch self {
        case .connecting, .on: true
        case .off, .failed: false
        }
    }
}

/// Saved tunnels and the ones running now.
@Observable
final class TunnelStore {
    static let shared = TunnelStore()

    struct LogLine: Identifiable {
        let id = UUID()
        let at = Date()
        let text: String
    }

    private(set) var profiles: [TunnelProfile] = []
    private(set) var states: [TunnelProfile.ID: TunnelState] = [:]
    private(set) var connections: [TunnelProfile.ID: [TunnelProxy.Connection]] = [:]
    private(set) var logs: [TunnelProfile.ID: [LogLine]] = [:]

    /// One run of a tunnel, from connecting until it is closed.
    private struct Runtime {
        /// Tells this run's events from those of a run that replaced it.
        let token = UUID()
        var provider: SFTPFileProvider?
        var proxy: TunnelProxy?
        var activity: Task<Void, Never>?
        /// Closed on purpose: its connection dropping is not news.
        var closing = false
        /// Turned off by the user: no more retries.
        var stopping = false
    }

    @ObservationIgnored private var runtimes: [TunnelProfile.ID: Runtime] = [:]
    /// Seconds before the next reconnect attempt, doubling while the server stays away.
    @ObservationIgnored private var retryDelays: [TunnelProfile.ID: Double] = [:]
    /// The PAC address a tunnel put in the Mac's proxy settings. It stays
    /// across reconnects (each change needs an administrator) and comes out
    /// when the tunnel is turned off or Bottari quits.
    @ObservationIgnored private var systemProxies: [TunnelProfile.ID: String] = [:]
    @ObservationIgnored private let file = URL.applicationSupportDirectory.appending(path: "Bottari/tunnels.json")

    private init() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([TunnelProfile].self, from: data) {
            profiles = saved
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { TunnelStore.shared.reconnectAfterWake() }
        }
    }

    func state(_ id: TunnelProfile.ID) -> TunnelState { states[id] ?? .off }

    #if DEBUG
    /// Sample tunnels for snapshots; nothing is saved.
    func showPreview(_ samples: [TunnelProfile], states: [TunnelProfile.ID: TunnelState], connections: [TunnelProfile.ID: [TunnelProxy.Connection]]) {
        profiles = samples
        self.states = states
        self.connections = connections
        for sample in samples {
            log(sample.id, String(localized: "프록시 시작: SOCKS5 :1080 · HTTP :8118"))
            log(sample.id, String(localized: "home-nas에 연결 중"))
        }
    }
    #endif
    var activeCount: Int { states.values.filter(\.isActive).count }

    // MARK: - Editing

    @discardableResult
    func add() -> TunnelProfile {
        var profile = TunnelProfile()
        profile.siteID = AppServices.sites.sites.first?.id
        profiles.append(profile)
        save()
        return profile
    }

    func update(_ profile: TunnelProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }), profiles[index] != profile else { return }
        profiles[index] = profile
        save()
    }

    func remove(_ id: TunnelProfile.ID) {
        Task { await stop(id) }
        profiles.removeAll { $0.id == id }
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(profiles).write(to: file, options: .atomic)
    }

    // MARK: - Running

    func toggle(_ id: TunnelProfile.ID) {
        Task {
            if state(id).isActive { await stop(id) } else { await start(id) }
        }
    }

    func start(_ id: TunnelProfile.ID) async {
        await run(id, reconnecting: false)
    }

    /// Opens the tunnel, first closing a run still going. A reconnect that
    /// fails tries again later instead of giving up.
    private func run(_ id: TunnelProfile.ID, reconnecting: Bool) async {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        guard let siteID = profile.siteID, let site = AppServices.sites.site(siteID) else {
            states[id] = .failed(String(localized: "경유 서버 미지정"))
            return
        }
        await cleanUp(id, keepingSystemProxy: true)
        let runtime = Runtime()
        let token = runtime.token
        runtimes[id] = runtime
        states[id] = .connecting
        log(id, String(localized: "\(site.name)에 연결 중"))
        if profile.mode == .wholeMac, !TunnelProfile.Mode.available.contains(.wholeMac) {
            states[id] = .failed(String(localized: "App Store 판에서는 Mac 전체 터널(sshuttle)을 쓸 수 없습니다."))
            return
        }
        if profile.mode == .wholeMac {
            startSshuttle(profile, site: site)
            return
        }
        do {
            let provider = try await AppServices.sites.connectSFTP(site, takingDetours: false)
            guard let current = runtimes[id], current.token == token, !current.stopping, !current.closing else {
                await provider.disconnect()
                return
            }
            runtimes[id]?.provider = provider
            retryDelays[id] = nil
            provider.whenDisconnected { [id] in
                Task { @MainActor in TunnelStore.shared.connectionDropped(id, token: token) }
            }
            switch profile.mode {
            case .bottariOnly:
                states[id] = .on(String(localized: "Bottari 연결만 \(site.name) 경유"))
                log(id, String(localized: "Bottari 연결 경로 변경됨"))
            case .proxy:
                try await startProxy(profile, site: site, provider: provider)
            case .wholeMac:
                break
            }
        } catch {
            guard let current = runtimes[id], current.token == token, !current.stopping else { return }
            log(id, String(localized: "연결 실패: \(error.localizedDescription)"))
            if reconnecting, profile.reconnects {
                retry(id, token: token)
            } else {
                states[id] = .failed(error.localizedDescription)
                await cleanUp(id, keepingSystemProxy: false)
            }
        }
    }

    private func startProxy(_ profile: TunnelProfile, site: SavedSite, provider: SFTPFileProvider) async throws {
        let id = profile.id
        let rules = profile.rules
        let socks = profile.socksPort
        let http = profile.httpEnabled ? profile.httpPort : nil
        let proxy = try await provider.startProxy(socksPort: socks, httpPort: http) {
            rules.pacFile(socksPort: socks, httpPort: http, fallBackToDirect: false)
        }
        runtimes[id]?.proxy = proxy
        connections[id] = []
        runtimes[id]?.activity = Task {
            for await event in proxy.activity {
                switch event {
                case .opened(let connection):
                    connections[id, default: []].append(connection)
                case .closed(let connectionID):
                    connections[id]?.removeAll { $0.id == connectionID }
                case .failed(let host, let port, let reason):
                    log(id, String(localized: "\(host):\(port) 연결 실패 · \(reason)"))
                }
            }
        }
        var summary = "SOCKS5 :\(proxy.socksPort)"
        if let http = proxy.httpPort { summary += " · HTTP :\(http)" }
        log(id, String(localized: "프록시 시작: \(summary)"))
        if profile.appliesSystemProxy, profile.httpEnabled, TunnelProfile.canApplySystemProxy {
            if systemProxies[id] == profile.pacURL {
                summary += String(localized: " · 시스템 프록시에 PAC 적용")
            } else {
                do {
                    try await SystemProxy.setAutoProxy(url: profile.pacURL)
                    systemProxies[id] = profile.pacURL
                    summary += String(localized: " · 시스템 프록시에 PAC 적용")
                    log(id, String(localized: "시스템 프록시에 PAC 적용됨"))
                } catch {
                    log(id, String(localized: "시스템 프록시 변경 실패: \(error.localizedDescription)"))
                }
            }
        } else if systemProxies[id] != nil {
            await restoreSystemProxy(id)
        }
        states[id] = .on(summary)
    }

    /// sshuttle needs sudo for its firewall rules, so it runs in Terminal where
    /// macOS asks for the password itself; Bottari never holds it. Bottari
    /// cannot see into Terminal, so it looks for the sshuttle process instead.
    private func startSshuttle(_ profile: TunnelProfile, site: SavedSite) {
        let command = Self.sshuttleCommand(profile, site: site)
        let script = FileManager.default.temporaryDirectory.appending(path: "bottari-\(profile.id.uuidString).command")
        let banner = String(localized: "\(profile.name) · Ctrl-C로 종료하면 방화벽 규칙도 복원됩니다")
        let text = "#!/bin/zsh\necho \(SFTPFileProvider.quote(banner))\n\(command)\n"
        do {
            try text.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
            log(profile.id, String(localized: "터미널에서 실행: \(command)"))
            log(profile.id, String(localized: "터미널 창에서 sudo 암호를 입력하십시오"))
            watchSshuttle(profile.id, target: Self.sshuttleTarget(site))
        } catch {
            states[profile.id] = .failed(error.localizedDescription)
        }
    }

    /// On once an sshuttle for the server runs; off again when it ends, or
    /// when none started within two minutes.
    private func watchSshuttle(_ id: TunnelProfile.ID, target: String) {
        let pattern = "sshuttle.* -r " + NSRegularExpression.escapedPattern(for: target)
        let started = Date()
        runtimes[id]?.activity = Task {
            var seen = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                let running = (try? await SystemProxy.run("/usr/bin/pgrep", ["-f", pattern])) != nil
                if running, !seen {
                    seen = true
                    states[id] = .on(String(localized: "터미널에서 sshuttle 실행 중 (Ctrl-C로 종료)"))
                    log(id, String(localized: "sshuttle 실행됨"))
                } else if !running, seen || Date().timeIntervalSince(started) > 120 {
                    states[id] = seen ? .off : .failed(String(localized: "sshuttle이 시작되지 않았습니다"))
                    log(id, seen ? String(localized: "sshuttle 종료됨") : String(localized: "sshuttle이 시작되지 않았습니다"))
                    return
                }
            }
        }
    }

    private static func sshuttleTarget(_ site: SavedSite) -> String {
        var target = "\(site.endpoint.username)@\(site.endpoint.host)"
        if site.endpoint.port != 22 { target += ":\(site.endpoint.port)" }
        return target
    }

    static func sshuttleCommand(_ profile: TunnelProfile, site: SavedSite) -> String {
        let binary = ["/opt/homebrew/bin/sshuttle", "/usr/local/bin/sshuttle"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? "sshuttle"
        let target = sshuttleTarget(site)
        var ssh: [String] = []
        if case .keyFile(let path) = site.authentication { ssh += ["-i", path] }
        if !site.proxyJump.isEmpty { ssh += ["-J", site.proxyJump.joined(separator: ",")] }
        var arguments = [binary, "-r", target]
        if !ssh.isEmpty { arguments += ["-e", (["ssh"] + ssh).joined(separator: " ")] }
        if profile.remoteDNS { arguments.append("--dns") }
        arguments += profile.rules.subnets
        arguments += ["-x", site.endpoint.host]
        return arguments.map(SFTPFileProvider.quote).joined(separator: " ")
    }

    func stop(_ id: TunnelProfile.ID) async {
        runtimes[id]?.stopping = true
        if profiles.first(where: { $0.id == id })?.mode == .wholeMac {
            log(id, String(localized: "터미널 창에서 Ctrl-C를 눌러 종료하십시오"))
        }
        await cleanUp(id, keepingSystemProxy: false)
        retryDelays[id] = nil
        states[id] = .off
        connections[id] = []
        log(id, String(localized: "꺼짐"))
    }

    /// Whether quitting has to put the Mac's proxy settings back first.
    var changedSystemProxy: Bool { !systemProxies.isEmpty }

    /// Puts back every proxy setting a tunnel changed, before quitting.
    func restoreSystemProxies() async {
        for id in Array(systemProxies.keys) { await restoreSystemProxy(id) }
    }

    private func restoreSystemProxy(_ id: TunnelProfile.ID) async {
        guard systemProxies.removeValue(forKey: id) != nil else { return }
        do {
            try await SystemProxy.setAutoProxy(url: nil)
            log(id, String(localized: "시스템 프록시 복원됨"))
        } catch {
            log(id, String(localized: "시스템 프록시 변경 실패: \(error.localizedDescription)"))
        }
    }

    private func cleanUp(_ id: TunnelProfile.ID, keepingSystemProxy: Bool) async {
        if let runtime = runtimes[id] {
            runtimes[id]?.closing = true
            runtime.activity?.cancel()
            await runtime.proxy?.close()
            await runtime.provider?.disconnect()
            runtimes[id]?.provider = nil
            runtimes[id]?.proxy = nil
            runtimes[id]?.activity = nil
        }
        if !keepingSystemProxy { await restoreSystemProxy(id) }
    }

    private func connectionDropped(_ id: TunnelProfile.ID, token: UUID) {
        guard let runtime = runtimes[id], runtime.token == token, !runtime.stopping, !runtime.closing else { return }
        guard profiles.first(where: { $0.id == id })?.reconnects == true else {
            states[id] = .failed(String(localized: "연결 끊김"))
            Task { await cleanUp(id, keepingSystemProxy: false) }
            return
        }
        retry(id, token: token)
    }

    /// Tries the run again after a pause that grows while the server stays away.
    private func retry(_ id: TunnelProfile.ID, token: UUID) {
        let delay = retryDelays[id] ?? 2
        retryDelays[id] = min(delay * 2, 60)
        states[id] = .connecting
        log(id, String(localized: "연결 끊김, \(Int(delay))초 후 재연결"))
        Task {
            await cleanUp(id, keepingSystemProxy: true)
            try? await Task.sleep(for: .seconds(delay))
            guard let runtime = runtimes[id], runtime.token == token, !runtime.stopping else { return }
            await run(id, reconnecting: true)
        }
    }

    private func reconnectAfterWake() {
        for profile in profiles where profile.reconnectsOnWake && profile.mode != .wholeMac && state(profile.id).isActive {
            log(profile.id, String(localized: "잠자기에서 깨어나 재연결"))
            Task { await run(profile.id, reconnecting: true) }
        }
    }

    private func log(_ id: TunnelProfile.ID, _ text: String) {
        logs[id, default: []].insert(LogLine(text: text), at: 0)
        if logs[id]!.count > 200 { logs[id]!.removeLast() }
    }

    // MARK: - Routing

    /// Where Bottari's connection to `host` goes: through which running tunnel, or straight.
    func route(for host: String) -> (profile: TunnelProfile, via: SavedSite)? {
        for profile in profiles where state(profile.id).isActive && profile.rules.matches(host) {
            if let siteID = profile.siteID, let site = AppServices.sites.site(siteID) {
                return (profile, site)
            }
        }
        return nil
    }

    /// For a Bottari-only tunnel covering `site`, the server to go through first.
    func detour(for site: SavedSite) -> SavedSite? {
        for profile in profiles where profile.mode == .bottariOnly && state(profile.id).isActive && profile.rules.matches(site.endpoint.host) {
            guard let siteID = profile.siteID, siteID != site.id, let via = AppServices.sites.site(siteID),
                  !site.proxyJump.contains(via.name) else { continue }
            return via
        }
        return nil
    }
}

/// The Mac's proxy settings, changed with an administrator's approval.
enum SystemProxy {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Network services that are switched on (Wi-Fi, Ethernet …).
    static func services() async throws -> [String] {
        let output = try await run("/usr/sbin/networksetup", ["-listallnetworkservices"])
        return output.split(separator: "\n").dropFirst().map(String.init).filter { !$0.hasPrefix("*") }
    }

    /// Sets (or with nil, turns off) the automatic proxy configuration on every service.
    static func setAutoProxy(url: String?) async throws {
        let commands = try await services().flatMap { service -> [String] in
            let name = SFTPFileProvider.quote(service)
            if let url {
                return ["/usr/sbin/networksetup -setautoproxyurl \(name) \(SFTPFileProvider.quote(url))", "/usr/sbin/networksetup -setautoproxystate \(name) on"]
            }
            return ["/usr/sbin/networksetup -setautoproxystate \(name) off"]
        }
        let shell = commands.joined(separator: " && ").replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        _ = try await run("/usr/bin/osascript", ["-e", "do shell script \"\(shell)\" with administrator privileges"])
    }

    static func run(_ path: String, _ arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            process.terminationHandler = { process in
                let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if process.terminationStatus == 0 {
                    continuation.resume(returning: text)
                } else {
                    continuation.resume(throwing: Failure(message: text.isEmpty ? String(localized: "실패했습니다 (종료 코드 \(process.terminationStatus))") : text))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
