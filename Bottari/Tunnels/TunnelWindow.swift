import AppKit
import BottariCore
import BottariSFTP
import SwiftUI

/// "SSH만 되는 곳이면 어디서든 켜는 VPN": saved tunnels on the left, the
/// selected one's settings, routes and live connections on the right.
struct TunnelWindow: View {
    @State private var selection: TunnelProfile.ID?
    private var store: TunnelStore { .shared }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(store.profiles) { profile in
                    TunnelRow(profile: profile, state: store.state(profile.id))
                        .tag(profile.id)
                        .contextMenu {
                            Button("지우기", role: .destructive) { store.remove(profile.id) }
                        }
                }
            }
            .overlay {
                if store.profiles.isEmpty {
                    Text("아래 + 로 터널을 만들어요")
                        .foregroundStyle(.secondary)
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button {
                        selection = store.add().id
                    } label: {
                        Label("새 터널", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                }
                .padding(10)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            if let id = selection, let profile = store.profiles.first(where: { $0.id == id }) {
                TunnelDetail(profile: Binding(get: { store.profiles.first { $0.id == id } ?? profile }, set: { store.update($0) }))
                    .id(id)
            } else {
                ContentUnavailableView("터널을 골라 주세요", systemImage: "point.3.connected.trianglepath.dotted",
                                       description: Text("SSH만 되는 곳이면 어디서든 켜는 VPN · Bottari만 → 프록시 쓰는 앱 → Mac 전체"))
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear { selection = selection ?? store.profiles.first?.id }
    }
}

private struct TunnelRow: View {
    let profile: TunnelProfile
    let state: TunnelState

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                Text(subtitle)
                    .font(.ui(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { state.isActive }, set: { _ in TunnelStore.shared.toggle(profile.id) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
        .padding(.vertical, 2)
    }

    private var color: Color {
        switch state {
        case .on: .green
        case .connecting: .yellow
        case .failed: .red
        case .off: .secondary.opacity(0.4)
        }
    }

    private var subtitle: String {
        switch state {
        case .on(let detail): detail
        case .connecting: "연결하는 중…"
        case .failed(let reason): reason
        case .off: profile.mode.title
        }
    }
}

extension TunnelProfile.Mode {
    var title: String {
        switch self {
        case .bottariOnly: "Bottari 안에서만"
        case .proxy: "프록시 쓰는 앱"
        case .wholeMac: "Mac 전체 (sshuttle)"
        }
    }

    var detail: String {
        switch self {
        case .bottariOnly: "Bottari의 SFTP · 터미널 · VNC · 영상 연결만 이 서버를 거쳐요."
        case .proxy: "내 Mac에 SOCKS5 · HTTP 프록시를 열어요. 브라우저, DB 툴, git, curl이 정한 주소만 터널로 보내요."
        case .wholeMac: "방화벽 규칙으로 정한 대역의 모든 TCP를 돌려요. 프록시를 모르는 앱도 따라와요."
        }
    }

    var caveat: String {
        switch self {
        case .bottariOnly: "다른 앱은 그대로 바로 나가요"
        case .proxy: "시스템 프록시 자동 적용 시 관리자 확인"
        case .wholeMac: "sudo · 서버에 Python 3 · UDP 제외 · sshuttle 설치 필요"
        }
    }

    var symbol: String {
        switch self {
        case .bottariOnly: "shippingbox"
        case .proxy: "network"
        case .wholeMac: "laptopcomputer"
        }
    }
}

private struct TunnelDetail: View {
    @Binding var profile: TunnelProfile
    @State private var probe = ""
    private var store: TunnelStore { .shared }
    private var state: TunnelState { store.state(profile.id) }

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("이름", text: $profile.name)
                        .font(.ui(.title3, weight: .semibold))
                        .textFieldStyle(.plain)
                    Spacer()
                    statusBadge
                    Button(state.isActive ? "끄기" : "켜기") { store.toggle(profile.id) }
                        .keyboardShortcut(.defaultAction)
                }
                Picker("거쳐 갈 서버", selection: $profile.siteID) {
                    Text("고르세요").tag(SavedSite.ID?.none)
                    ForEach(AppServices.sites.sites.filter(\.isSFTP)) { site in
                        Text("\(site.name) · \(site.summary)").tag(SavedSite.ID?.some(site.id))
                    }
                }
            }

            Section("어디까지 터널로 보낼까요") {
                HStack(spacing: 10) {
                    ForEach(TunnelProfile.Mode.allCases, id: \.self) { mode in
                        modeCard(mode)
                    }
                }
            }

            Section {
                TextEditor(text: $profile.routes)
                    .font(.themeMono(.body))
                    .frame(minHeight: 90)
                if !profile.invalidRoutes.isEmpty {
                    Label("“\(profile.invalidRoutes.joined(separator: "”, “"))” 은 대역 · IP · 호스트 · *.도메인 형식이 아니에요", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.ui(.caption))
                }
            } header: {
                Text("터널로 보낼 주소")
            } footer: {
                Text("IP 대역(CIDR), 호스트 이름, *.도메인 을 쓸 수 있어요. 0/0 은 전체 트래픽이에요. 거쳐 갈 서버 자신의 주소는 자동으로 빼요.")
            }

            if profile.mode == .proxy {
                Section("프록시 설정") {
                    TextField("SOCKS5 포트 127.0.0.1:", value: $profile.socksPort, format: .number.grouping(.never))
                    Toggle("HTTP 프록시 (SOCKS를 모르는 앱용, HTTP CONNECT)", isOn: $profile.httpEnabled)
                    if profile.httpEnabled {
                        TextField("HTTP 프록시 포트 127.0.0.1:", value: $profile.httpPort, format: .number.grouping(.never))
                        LabeledContent("PAC 주소") {
                            HStack {
                                Text(profile.pacURL)
                                    .font(.themeMono(.callout))
                                    .textSelection(.enabled)
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(profile.pacURL, forType: .string)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        Toggle(isOn: $profile.appliesSystemProxy) {
                            Text("시스템 프록시에 PAC 적용")
                            Text("켜면 Safari · Chrome은 따로 설정할 필요 없어요. 끄면 원래 설정으로 되돌려요 · 관리자 확인")
                        }
                    }
                }
            }
            if profile.mode == .wholeMac {
                Section("Mac 전체") {
                    Toggle(isOn: $profile.remoteDNS) {
                        Text("DNS도 터널로")
                        Text("--dns 로 원격에서 이름을 풀어요. 사내 도메인을 쓰려면 켜 두세요.")
                    }
                    if let site = profile.siteID.flatMap(AppServices.sites.site) {
                        LabeledContent("실행할 명령") {
                            Text(TunnelStore.sshuttleCommand(profile, site: site))
                                .font(.themeMono(.caption))
                                .textSelection(.enabled)
                        }
                    }
                    Text("sudo가 필요해서 터미널 창에서 실행해요. 비밀번호는 macOS가 직접 묻고, Bottari는 받지 않아요. sshuttle은 이름 규칙(*.도메인)을 모르니 대역으로 적어 주세요.")
                        .font(.ui(.caption))
                        .foregroundStyle(.secondary)
                }
            }

            Section("알아서 켜고 끄기") {
                Toggle("끊기면 자동으로 다시 연결", isOn: $profile.reconnects)
                Toggle("잠자기에서 깨면 다시 연결", isOn: $profile.reconnectsOnWake)
            }

            Section("이 주소는 어디로 나가요?") {
                TextField("예: gitlab.internal, 10.1.2.3", text: $probe)
                if !probe.isEmpty {
                    Text(probeAnswer)
                        .foregroundStyle(.secondary)
                }
            }

            if profile.mode == .proxy {
                Section("지금 이 프록시를 쓰는 연결 · \(store.connections[profile.id]?.count ?? 0)개") {
                    ForEach(store.connections[profile.id] ?? []) { connection in
                        HStack {
                            Text(connection.kind)
                                .font(.themeMono(.caption))
                                .foregroundStyle(.secondary)
                            Text(verbatim: "\(connection.host):\(connection.port)")
                                .font(.themeMono(.callout))
                            Spacer()
                            Text(connection.opened.formatted(date: .omitted, time: .standard))
                                .font(.ui(.caption))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section("앱마다 연결하는 법") {
                    instructions
                }
            }

            Section("기록") {
                ForEach((store.logs[profile.id] ?? []).prefix(30)) { line in
                    HStack(alignment: .top) {
                        Text(line.at.formatted(date: .omitted, time: .standard))
                            .font(.themeMono(.caption))
                            .foregroundStyle(.secondary)
                        Text(line.text)
                            .font(.ui(.caption))
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(false)
    }

    private var statusBadge: some View {
        let (text, color): (String, Color) = switch state {
        case .on(let detail): (detail, .green)
        case .connecting: ("연결하는 중…", .yellow)
        case .failed(let reason): (reason, .red)
        case .off: ("꺼짐", .secondary)
        }
        return Label(text, systemImage: "circle.fill")
            .font(.ui(.caption))
            .foregroundStyle(color)
            .lineLimit(1)
    }

    private func modeCard(_ mode: TunnelProfile.Mode) -> some View {
        let selected = profile.mode == mode
        return Button {
            profile.mode = mode
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Label(mode.title, systemImage: mode.symbol)
                    .font(.ui(.callout, weight: .semibold))
                Text(mode.detail)
                    .font(.ui(.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(mode.caveat)
                    .font(.ui(.caption2))
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
            .background(selected ? Color.themeAccent.opacity(0.12) : .clear, in: .rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? Color.themeAccent : Color.secondary.opacity(0.3), lineWidth: selected ? 1.5 : 1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var probeAnswer: String {
        let host = probe.trimmingCharacters(in: .whitespaces)
        guard profile.rules.matches(host) else {
            if let other = store.route(for: host), other.profile.id != profile.id {
                return "“\(other.profile.name)” 터널로 가요 · \(other.via.name) 경유"
            }
            return "어느 규칙에도 해당하지 않아서 바로 나가요."
        }
        let via = profile.siteID.flatMap(AppServices.sites.site)?.name ?? "서버"
        let path = switch profile.mode {
        case .bottariOnly: "Bottari의 연결만 이 길로 가요. 브라우저 같은 다른 앱은 바로 나가요."
        case .proxy: profile.appliesSystemProxy ? "시스템 프록시에 걸려 있어서 Safari · Chrome은 따로 설정할 필요 없어요." : "프록시를 쓰는 앱만 이 길로 가요. 앱마다 프록시를 지정해야 해요."
        case .wholeMac: "Mac의 모든 TCP 연결이 이 길로 가요" + (profile.remoteDNS ? ", 이름도 원격 DNS로 풀어요." : ".")
        }
        return "\(via) 을(를) 거쳐 나가요 · \(path)" + (state.isActive ? "" : " (지금은 꺼져 있어서 바로 나가요)")
    }

    private var instructions: some View {
        let socks = profile.socksPort
        let http = profile.httpPort
        let lines: [(String, String)] = [
            ("curl", "curl --socks5-hostname 127.0.0.1:\(socks) http://gitlab.internal"),
            ("셸 전체 (~/.zshrc)", "export ALL_PROXY=socks5h://127.0.0.1:\(socks)"),
            ("git (특정 저장소만)", "git config --global http.https://gitlab.internal.proxy socks5h://127.0.0.1:\(socks)"),
            ("ssh (macOS 기본 nc)", "ssh -o ProxyCommand='nc -X 5 -x 127.0.0.1:\(socks) %h %p' user@10.0.4.21"),
            ("HTTP 프록시만 받는 앱", profile.httpEnabled ? "http_proxy=http://127.0.0.1:\(http) https_proxy=http://127.0.0.1:\(http)" : "위에서 HTTP 프록시를 켜 주세요"),
            ("DB 툴 (JDBC)", "SOCKS 프록시 127.0.0.1:\(socks) · JDBC 기반 툴은 대부분 SOCKS를 지원해요"),
            ("Firefox", "설정 › 네트워크 › SOCKS v5 127.0.0.1:\(socks) · ‘SOCKS v5 사용 시 DNS도 프록시’ 켜기"),
        ]
        return ForEach(lines, id: \.0) { line in
            VStack(alignment: .leading, spacing: 2) {
                Text(line.0)
                    .font(.ui(.caption, weight: .semibold))
                Text(line.1)
                    .font(.themeMono(.caption))
                    .textSelection(.enabled)
            }
        }
    }
}

/// The tunnels in the menu bar, to switch on and off without opening Bottari.
struct TunnelMenu: View {
    @Environment(\.openWindow) private var openWindow
    private var store: TunnelStore { .shared }

    var body: some View {
        if store.profiles.isEmpty {
            Text("터널이 없어요")
        }
        ForEach(store.profiles) { profile in
            Toggle(isOn: Binding(get: { store.state(profile.id).isActive }, set: { _ in store.toggle(profile.id) })) {
                Text(profile.name + " · " + profile.mode.title)
            }
        }
        Divider()
        Button("터널 관리…") { openWindow(id: "tunnels") }
        Button("Bottari 열기") {
            NSApp.activate()
            openWindow(id: "main")
        }
        Divider()
        Button("종료") { NSApp.terminate(nil) }
    }
}

/// A toolbar chip with the running tunnels.
struct TunnelStatusButton: View {
    @Environment(\.openWindow) private var openWindow
    private var store: TunnelStore { .shared }

    var body: some View {
        Button {
            openWindow(id: "tunnels")
        } label: {
            Label(store.activeCount > 0 ? "터널 \(store.activeCount)" : "터널", systemImage: store.activeCount > 0 ? "point.3.filled.connected.trianglepath.dotted" : "point.3.connected.trianglepath.dotted")
        }
        .help("터널 · SSH VPN")
    }
}
