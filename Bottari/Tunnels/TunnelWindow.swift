import AppKit
import BottariCore
import BottariSFTP
import SwiftUI

/// "SSH만 되는 곳이면 어디서든 켜는 VPN": saved tunnels on the left, the
/// selected one's settings, routes and live connections on the right.
struct TunnelWindow: View {
    @State private var selection: TunnelProfile.ID?
    @Environment(\.dismissWindow) private var dismissWindow
    private var store: TunnelStore { .shared }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                BackButton(title: "메인으로") { dismissWindow(id: "tunnels") }
                    .buttonStyle(PanelButtonStyle())
                    .fixedSize()
                Text("터널").font(.ui(.title3, weight: .bold))
                if store.activeCount > 0 {
                    Label("\(store.activeCount)개 켜짐", systemImage: "circle.fill")
                        .font(.ui(.caption, weight: .semibold))
                        .foregroundStyle(Color(light: 0x0F7C5A, dark: 0x3CC48E))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color(light: 0x0F7C5A, dark: 0x3CC48E).opacity(0.12), in: .capsule)
                }
                Spacer()
                Text("SSH만 되는 곳이면 어디서든 켜는 VPN · Bottari만 → 프록시 쓰는 앱 → Mac 전체")
                    .font(.ui(.caption))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            HStack(alignment: .top, spacing: 12) {
                list
                    .frame(width: 290)
                if let id = selection, let profile = store.profiles.first(where: { $0.id == id }) {
                    TunnelDetail(profile: Binding(get: { store.profiles.first { $0.id == id } ?? profile }, set: { store.update($0) }))
                        .id(id)
                } else {
                    ContentUnavailableView("터널을 골라 주세요", systemImage: "point.3.connected.trianglepath.dotted",
                                           description: Text("왼쪽 아래 + 로 터널을 만들어요"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .card()
                }
            }
            .padding([.horizontal, .bottom], 12)
        }
        .background(Palette.background)
        .frame(minWidth: 1100, minHeight: 640)
        .onAppear { selection = selection ?? store.profiles.first?.id }
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(store.profiles) { profile in
                    TunnelCard(profile: profile, state: store.state(profile.id), isSelected: selection == profile.id)
                        .onTapGesture { selection = profile.id }
                        .contextMenu {
                            Button("지우기", role: .destructive) { store.remove(profile.id) }
                        }
                }
                Button {
                    selection = store.add().id
                } label: {
                    Label("새 터널", systemImage: "plus")
                }
                .buttonStyle(PanelButtonStyle(dashed: true))
                if !store.profiles.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("메뉴 막대에서는 이렇게", systemImage: "menubar.rectangle")
                            .font(.ui(.callout, weight: .semibold))
                        ForEach(store.profiles) { profile in
                            HStack(spacing: 8) {
                                StatusDot(on: store.state(profile.id).isActive)
                                Text(profile.name).font(.ui(.callout))
                                Spacer()
                                if profile.mode == .proxy {
                                    Text(verbatim: ":\(profile.socksPort)").font(.themeMono(.caption2)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(12)
                    .card()
                }
            }
        }
        .scrollIndicators(.never)
    }
}

/// A tunnel in the list: stripe, name, route, state and its switch.
private struct TunnelCard: View {
    let profile: TunnelProfile
    let state: TunnelState
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.name).font(.ui(.body, weight: .semibold)).lineLimit(1)
                Text(route).font(.themeMono(.caption2)).foregroundStyle(.secondary).lineLimit(1)
                Text(subtitle).font(.ui(.caption, weight: .medium)).foregroundStyle(color).lineLimit(1)
            }
            Spacer()
            Toggle("켜기", isOn: Binding(get: { state.isActive }, set: { _ in TunnelStore.shared.toggle(profile.id) }))
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(14)
        .background(isSelected ? Palette.selection : Palette.panel, in: .rect(cornerRadius: 10))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5).fill(state.isActive ? color : Palette.line).frame(width: 3).padding(.vertical, 12)
        }
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isSelected ? Color.themeAccent : Palette.line, lineWidth: isSelected ? 1.5 : 1))
        .contentShape(.rect)
    }

    private var route: String {
        let via = profile.siteID.flatMap(AppServices.sites.site)?.name ?? "서버 미지정"
        return "via \(via) · \(profile.mode.title)"
    }

    private var color: Color {
        switch state {
        case .on: Color(light: 0x0F7C5A, dark: 0x3CC48E)
        case .connecting: .orange
        case .failed: .red
        case .off: .secondary
        }
    }

    private var subtitle: String {
        switch state {
        case .on(let detail): "켜짐 · \(detail)"
        case .connecting: "연결하는 중…"
        case .failed(let reason): reason
        case .off: "꺼짐"
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
    @State private var newRoute = ""
    @State private var instructionTab = 0
    private var store: TunnelStore { .shared }
    private var state: TunnelState { store.state(profile.id) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .bottom, spacing: 12) {
                        LabeledField("이름") { TextField("이름", text: $profile.name).designField() }
                        Button(state.isActive ? "끄기" : "켜기") { store.toggle(profile.id) }
                            .buttonStyle(PanelButtonStyle(prominent: !state.isActive))
                            .fixedSize()
                            .keyboardShortcut(.defaultAction)
                    }
                    statusBadge
                    LabeledField("거쳐 갈 서버") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(AppServices.sites.sites.filter(\.isSFTP)) { site in
                                    let selected = profile.siteID == site.id
                                    Button {
                                        profile.siteID = site.id
                                    } label: {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(site.name).font(.ui(.callout, weight: .semibold))
                                                .foregroundStyle(selected ? Color.themeAccent : Palette.text)
                                            Text(site.summary).font(.themeMono(.caption2)).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(selected ? Palette.selection : Palette.panel, in: .rect(cornerRadius: 8))
                                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.themeAccent : Palette.line, lineWidth: selected ? 1.5 : 1))
                                        .contentShape(.rect)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    LabeledField("어디까지 터널로 보낼까요") {
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(TunnelProfile.Mode.allCases, id: \.self) { mode in
                                modeCard(mode)
                            }
                        }
                    }
                    routesField
                    if profile.mode == .proxy {
                        proxySettings
                    }
                    if profile.mode == .wholeMac {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Mac 전체").font(.ui(.body, weight: .semibold))
                            SwitchRow(title: "DNS도 터널로", detail: "--dns 로 원격에서 이름을 풀어요. 사내 도메인을 쓰려면 켜 두세요.", isOn: $profile.remoteDNS)
                            if let site = profile.siteID.flatMap(AppServices.sites.site) {
                                Text(TunnelStore.sshuttleCommand(profile, site: site))
                                    .font(.themeMono(.caption))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                                    .background(Palette.panel, in: .rect(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line))
                            }
                            Text("sudo가 필요해서 터미널 창에서 실행해요. 비밀번호는 macOS가 직접 묻고, Bottari는 받지 않아요. sshuttle은 이름 규칙(*.도메인)을 모르니 대역으로 적어 주세요.")
                                .font(.ui(.caption))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(14)
                        .well()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel("알아서 켜고 끄기")
                        HStack(spacing: 10) {
                            SwitchRow(title: "끊기면 다시 연결", detail: "서버가 잠깐 끊겨도 알아서 이어요", isOn: $profile.reconnects)
                            SwitchRow(title: "잠자기에서 깨면 다시 연결", detail: "Mac을 열면 바로 다시 켜요", isOn: $profile.reconnectsOnWake)
                        }
                    }
                }
                .padding(20)
            }
            .scrollIndicators(.never)
            .card()

            ScrollView {
                VStack(spacing: 12) {
                    probeCard
                    if profile.mode == .proxy {
                        connectionsCard
                        instructionsCard
                    }
                    logCard
                }
            }
            .scrollIndicators(.never)
            .frame(width: 340)
        }
    }

    /// Route rules as chips, each removable, with a field to add more.
    private var routesField: some View {
        let tokens = profile.routes.split(whereSeparator: { $0 == "\n" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return LabeledField("터널로 보낼 주소", hint: "IP 대역(CIDR), 호스트 이름, *.도메인 을 쓸 수 있어요. 0/0 은 전체 트래픽이에요. 거쳐 갈 서버 자신의 주소는 자동으로 빼요.") {
            FlowLayout(spacing: 6) {
                ForEach(tokens, id: \.self) { token in
                    HStack(spacing: 5) {
                        Text(token).font(.themeMono(.caption)).foregroundStyle(profile.invalidRoutes.contains(token) ? Color.orange : Color.themeAccent)
                        Text(kind(of: token)).font(.ui(.caption2)).foregroundStyle(.secondary)
                        Button {
                            profile.routes = tokens.filter { $0 != token }.joined(separator: "\n")
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(profile.invalidRoutes.contains(token) ? Color.orange.opacity(0.1) : Palette.selection, in: .rect(cornerRadius: 6))
                }
                TextField("10.1.0.0/16 · *.corp · host", text: $newRoute)
                    .designField(mono: true)
                    .frame(width: 220)
                    .onSubmit {
                        let value = newRoute.trimmingCharacters(in: .whitespaces)
                        guard !value.isEmpty else { return }
                        profile.routes = (tokens + [value]).joined(separator: "\n")
                        newRoute = ""
                    }
                Button("전체 트래픽 (0/0)") {
                    profile.routes = (tokens + ["0.0.0.0/0"]).joined(separator: "\n")
                }
                .buttonStyle(PanelButtonStyle())
                .fixedSize()
                .disabled(tokens.contains("0.0.0.0/0") || tokens.contains("0/0"))
            }
            if !profile.invalidRoutes.isEmpty {
                Label("“\(profile.invalidRoutes.joined(separator: "”, “"))” 은 대역 · IP · 호스트 · *.도메인 형식이 아니에요", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.ui(.caption))
            }
        }
    }

    private func kind(of token: String) -> String {
        if token.contains("/") { return "대역" }
        if token.hasPrefix("*.") { return "도메인" }
        return "호스트"
    }

    private var proxySettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("프록시 설정").font(.ui(.body, weight: .semibold))
            HStack(alignment: .bottom, spacing: 16) {
                LabeledField("SOCKS5 포트") {
                    HStack(spacing: 4) {
                        Text(verbatim: "127.0.0.1:").font(.themeMono(.callout)).foregroundStyle(.secondary)
                        TextField("SOCKS5 포트", value: $profile.socksPort, format: .number.grouping(.never)).designField(mono: true).frame(width: 80)
                    }
                }
                .fixedSize()
                if profile.httpEnabled {
                    LabeledField("HTTP 프록시 포트") {
                        HStack(spacing: 4) {
                            Text(verbatim: "127.0.0.1:").font(.themeMono(.callout)).foregroundStyle(.secondary)
                            TextField("HTTP 프록시 포트", value: $profile.httpPort, format: .number.grouping(.never)).designField(mono: true).frame(width: 80)
                        }
                    }
                    .fixedSize()
                    LabeledField("PAC 주소") {
                        HStack {
                            Text(profile.pacURL).font(.themeMono(.caption)).textSelection(.enabled).lineLimit(1)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(profile.pacURL, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    }
                }
            }
            HStack(alignment: .top, spacing: 10) {
                SwitchRow(title: "HTTP 프록시도 열기", detail: "SOCKS를 모르는 앱용 (HTTP CONNECT)", isOn: $profile.httpEnabled)
                if profile.httpEnabled {
                    SwitchRow(title: "켜면 시스템 프록시에 자동 적용", detail: "끄면 원래 설정으로 되돌려요 · 처음 한 번 관리자 확인", isOn: $profile.appliesSystemProxy)
                }
            }
        }
        .padding(14)
        .well()
    }

    private var probeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("이 주소는 어디로 나가요?").font(.ui(.body, weight: .semibold))
            TextField("예: gitlab.internal, 10.1.2.3", text: $probe).designField(mono: true)
            if !probe.isEmpty {
                Text(probeAnswer)
                    .font(.ui(.caption))
                    .foregroundStyle(Color(light: 0x0F7C5A, dark: 0x3CC48E))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var connectionsCard: some View {
        let connections = store.connections[profile.id] ?? []
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("지금 이 프록시를 쓰는 연결").font(.ui(.body, weight: .semibold))
                Spacer()
                Text("\(connections.count)개").font(.ui(.caption)).foregroundStyle(.secondary)
            }
            if connections.isEmpty {
                Text(state.isActive ? "아직 이 프록시로 들어온 연결이 없어요" : "터널을 켜면 보여요")
                    .font(.ui(.caption))
                    .foregroundStyle(.secondary)
            }
            ForEach(connections.prefix(8)) { connection in
                HStack(spacing: 8) {
                    Text(connection.kind)
                        .font(.themeMono(.caption2))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .leading)
                    Text(verbatim: "\(connection.host):\(connection.port)")
                        .font(.themeMono(.caption))
                        .lineLimit(1)
                    Spacer()
                    Text(connection.opened.formatted(date: .omitted, time: .shortened))
                        .font(.themeMono(.caption2))
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .well()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var instructionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("앱마다 연결하는 법").font(.ui(.body, weight: .semibold))
            instructions
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("기록").font(.ui(.body, weight: .semibold))
            let lines = (store.logs[profile.id] ?? []).prefix(20)
            if lines.isEmpty {
                Text("켜고 끈 기록이 여기에 남아요").font(.ui(.caption)).foregroundStyle(.secondary)
            }
            ForEach(lines) { line in
                HStack(alignment: .top) {
                    Text(line.at.formatted(date: .omitted, time: .standard))
                        .font(.themeMono(.caption2))
                        .foregroundStyle(.secondary)
                    Text(line.text)
                        .font(.ui(.caption))
                        .textSelection(.enabled)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
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
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(0..<3) { index in
                        Capsule()
                            .fill(index <= TunnelProfile.Mode.allCases.firstIndex(of: mode)! ? (selected ? Color.themeAccent : Color.secondary.opacity(0.7)) : Palette.line)
                            .frame(height: 4)
                    }
                }
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
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
            .background(selected ? Palette.selection : Palette.panel, in: .rect(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(selected ? Color.themeAccent : Palette.line, lineWidth: selected ? 1.5 : 1)
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
        let chosen = lines[min(instructionTab, lines.count - 1)]
        return VStack(alignment: .leading, spacing: 8) {
            FlowChips(titles: lines.map(\.0), selection: $instructionTab)
            Text(chosen.1)
                .font(.themeMono(.caption))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .well()
            Button("복사") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(chosen.1, forType: .string)
            }
            .buttonStyle(PanelButtonStyle())
            .fixedSize()
        }
    }
}

/// Choice chips that wrap onto more lines.
private struct FlowChips: View {
    let titles: [String]
    @Binding var selection: Int

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(titles.indices, id: \.self) { index in
                Button(titles[index]) { selection = index }
                    .buttonStyle(ChoiceButtonStyle(isOn: selection == index))
                    .fixedSize()
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
