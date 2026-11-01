import AppKit
import BottariCore
import BottariSFTP
import Foundation
import Observation

/// A saved way through an SSH server: for Bottari only, or for apps that use a proxy.
struct TunnelProfile: Codable, Identifiable, Hashable {
    enum Mode: String, Codable, CaseIterable {
        /// Bottari's own connections to matching hosts go through the server.
        case bottariOnly
        /// SOCKS5 and HTTP proxies on this Mac, with a PAC file.
        case proxy

        /// A tunnel saved with a mode Bottari no longer has (the whole-Mac
        /// sshuttle one) opens as a proxy.
        init(from decoder: any Decoder) throws {
            self = Mode(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .proxy
        }
    }

    var id = UUID()
    var name = String(localized: "새 터널")
    var siteID: SavedSite.ID?
    var mode = Mode.proxy
    var routes = "10.0.0.0/8\n*.internal"
    var socksPort = 1080
    var httpEnabled = true
    var httpPort = 8118
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
        await cleanUp(id)
        let runtime = Runtime()
        let token = runtime.token
        runtimes[id] = runtime
        states[id] = .connecting
        log(id, String(localized: "\(site.name)에 연결 중"))
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
            }
        } catch {
            guard let current = runtimes[id], current.token == token, !current.stopping else { return }
            log(id, String(localized: "연결 실패: \(error.localizedDescription)"))
            if reconnecting, profile.reconnects {
                retry(id, token: token)
            } else {
                states[id] = .failed(error.localizedDescription)
                await cleanUp(id)
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
        states[id] = .on(summary)
    }

    func stop(_ id: TunnelProfile.ID) async {
        runtimes[id]?.stopping = true
        await cleanUp(id)
        retryDelays[id] = nil
        states[id] = .off
        connections[id] = []
        log(id, String(localized: "꺼짐"))
    }

    private func cleanUp(_ id: TunnelProfile.ID) async {
        if let runtime = runtimes[id] {
            runtimes[id]?.closing = true
            runtime.activity?.cancel()
            await runtime.proxy?.close()
            await runtime.provider?.disconnect()
            runtimes[id]?.provider = nil
            runtimes[id]?.proxy = nil
            runtimes[id]?.activity = nil
        }
    }

    private func connectionDropped(_ id: TunnelProfile.ID, token: UUID) {
        guard let runtime = runtimes[id], runtime.token == token, !runtime.stopping, !runtime.closing else { return }
        guard profiles.first(where: { $0.id == id })?.reconnects == true else {
            states[id] = .failed(String(localized: "연결 끊김"))
            Task { await cleanUp(id) }
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
            await cleanUp(id)
            try? await Task.sleep(for: .seconds(delay))
            guard let runtime = runtimes[id], runtime.token == token, !runtime.stopping else { return }
            await run(id, reconnecting: true)
        }
    }

    private func reconnectAfterWake() {
        for profile in profiles where profile.reconnectsOnWake && state(profile.id).isActive {
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
