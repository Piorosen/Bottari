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
                BackButton(title: String(localized: "메인으로")) { dismissWindow(id: "tunnels") }
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
                Text("SSH 서버를 거치는 VPN")
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
                    ContentUnavailableView {
                        Label("터널 선택", glyph: "bt.tunnel", size: 40)
                    } description: {
                        Text("왼쪽의 ‘새 터널’로 추가")
                    }
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
                            Button("삭제", role: .destructive) { store.remove(profile.id) }
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
                        Label("메뉴 막대 미리보기", systemImage: "menubar.rectangle")
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
                Text(route).font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(1)
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
        guard let via = profile.siteID.flatMap(AppServices.sites.site) else { return String(localized: "경유 서버 없음 · \(profile.mode.title)") }
        return String(localized: "\(via.name) 경유 · \(profile.mode.title)")
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
        case .on(let detail): String(localized: "켜짐 · \(detail)")
        case .connecting: String(localized: "연결 중…")
        case .failed(let reason): reason
        case .off: String(localized: "꺼짐")
        }
    }
}

extension TunnelProfile.Mode {
    var title: String {
        switch self {
        case .bottariOnly: String(localized: "Bottari만")
        case .proxy: String(localized: "프록시 사용 앱")
        }
    }

    var detail: String {
        switch self {
        case .bottariOnly: String(localized: "Bottari의 연결만 이 서버 경유")
        case .proxy: String(localized: "Mac에 SOCKS5·HTTP 프록시를 열고, 프록시를 설정한 앱의 지정 주소만 터널로 전송")
        }
    }

    var caveat: String {
        switch self {
        case .bottariOnly: String(localized: "다른 앱은 직접 연결")
        case .proxy: String(localized: "쓸 앱마다 프록시를 직접 설정")
        }
    }

    var symbol: String {
        switch self {
        case .bottariOnly: "bt.bundle"
        case .proxy: "network"
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
                        LabeledField(String(localized: "이름")) { TextField("이름", text: $profile.name).designField() }
                        Button(state.isActive ? String(localized: "끄기") : String(localized: "켜기")) { store.toggle(profile.id) }
                            .buttonStyle(PanelButtonStyle(prominent: !state.isActive))
                            .fixedSize()
                            .keyboardShortcut(.defaultAction)
                    }
                    statusBadge
                    LabeledField(String(localized: "경유 서버")) {
                        // A menu, not a row of cards: people keep a dozen servers or more.
                        let servers = AppServices.sites.sites.filter(\.isSFTP)
                        let chosen = profile.siteID.flatMap(AppServices.sites.site)
                        HStack(spacing: 10) {
                            Picker("경유 서버", selection: $profile.siteID) {
                                // Also stands in for a server that has since been deleted.
                                if chosen == nil {
                                    Text("서버 선택").tag(profile.siteID)
                                }
                                ForEach(servers) { site in
                                    Text(site.name).tag(Optional(site.id))
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize()
                            if let site = chosen {
                                Text(site.summary)
                                    .font(.themeMono(.caption))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    LabeledField(String(localized: "터널 범위")) {
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
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(String(localized: "자동 재연결"))
                        HStack(spacing: 10) {
                            SwitchRow(title: String(localized: "연결이 끊겼을 때"), isOn: $profile.reconnects)
                            SwitchRow(title: String(localized: "잠자기에서 깨어날 때"), isOn: $profile.reconnectsOnWake)
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
        return LabeledField(String(localized: "터널로 보낼 주소"), hint: String(localized: "IP 대역(CIDR), 호스트 이름, *.도메인. 0/0은 전체 트래픽. 경유 서버 자체의 주소는 자동 제외")) {
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
                        .iconHelp(String(localized: "\(token) 빼기"))
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(profile.invalidRoutes.contains(token) ? Color.orange.opacity(0.1) : Palette.selection, in: .rect(cornerRadius: 6))
                }
                TextField("예: 10.1.0.0/16, *.corp", text: $newRoute)
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
                Label("올바른 형식이 아닙니다: “\(profile.invalidRoutes.joined(separator: "”, “"))”", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.ui(.caption))
            }
        }
    }

    private func kind(of token: String) -> String {
        if token.contains("/") { return String(localized: "대역") }
        if token.hasPrefix("*.") { return String(localized: "도메인") }
        return String(localized: "호스트")
    }

    private var proxySettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("프록시 설정").font(.ui(.body, weight: .semibold))
            HStack(alignment: .bottom, spacing: 16) {
                LabeledField(String(localized: "SOCKS5 포트")) {
                    HStack(spacing: 4) {
                        Text(verbatim: "127.0.0.1:").font(.themeMono(.callout)).foregroundStyle(.secondary)
                        TextField("SOCKS5 포트", value: $profile.socksPort, format: .number.grouping(.never)).designField(mono: true).frame(width: 80)
                    }
                }
                .fixedSize()
                if profile.httpEnabled {
                    LabeledField(String(localized: "HTTP 프록시 포트")) {
                        HStack(spacing: 4) {
                            Text(verbatim: "127.0.0.1:").font(.themeMono(.callout)).foregroundStyle(.secondary)
                            TextField("HTTP 프록시 포트", value: $profile.httpPort, format: .number.grouping(.never)).designField(mono: true).frame(width: 80)
                        }
                    }
                    .fixedSize()
                    LabeledField(String(localized: "PAC 주소")) {
                        HStack {
                            Text(profile.pacURL).font(.themeMono(.caption)).textSelection(.enabled).lineLimit(1)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(profile.pacURL, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .iconHelp(String(localized: "PAC 주소 복사"))
                            .buttonStyle(.borderless)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    }
                }
            }
            SwitchRow(title: String(localized: "HTTP 프록시도 열기"), detail: String(localized: "SOCKS 미지원 앱용 (HTTP CONNECT)"), isOn: $profile.httpEnabled)
        }
        .padding(14)
        .well()
    }

    private var probeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("주소별 경로 확인").font(.ui(.body, weight: .semibold))
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
                Text("프록시를 사용 중인 연결").font(.ui(.body, weight: .semibold))
                Spacer()
                Text("\(connections.count)개").font(.ui(.caption)).foregroundStyle(.secondary)
            }
            if connections.isEmpty {
                Text(state.isActive ? String(localized: "연결 없음") : String(localized: "터널 꺼짐"))
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
            Text("앱별 설정 방법").font(.ui(.body, weight: .semibold))
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
                Text("기록 없음").font(.ui(.caption)).foregroundStyle(.secondary)
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
        case .connecting: (String(localized: "연결 중…"), .yellow)
        case .failed(let reason): (reason, .red)
        case .off: (String(localized: "꺼짐"), .secondary)
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
                Label(mode.title, glyph: mode.symbol)
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
                return String(localized: "“\(other.profile.name)” 터널 · \(other.via.name) 경유")
            }
            return String(localized: "일치하는 규칙이 없어 직접 연결")
        }
        let via = profile.siteID.flatMap(AppServices.sites.site)?.name ?? String(localized: "서버")
        let path = switch profile.mode {
        case .bottariOnly: String(localized: "Bottari의 연결만 해당, 다른 앱은 직접 연결")
        case .proxy: String(localized: "프록시를 설정한 앱만 해당")
        }
        return String(localized: "\(via) 경유 · \(path)") + (state.isActive ? "" : String(localized: " (터널이 꺼져 있어 현재는 직접 연결)"))
    }

    private var instructions: some View {
        let socks = profile.socksPort
        let http = profile.httpPort
        // The whole Mac by hand: the App Sandbox does not let Bottari change
        // the Mac's proxy settings itself.
        let system = (
            String(localized: "Mac 전체 (시스템 설정)"),
            profile.httpEnabled ? profile.pacURL : String(localized: "먼저 ‘HTTP 프록시도 열기’를 켜십시오.")
        )
        let lines: [(String, String)] = [
            system,
            ("curl", "curl --socks5-hostname 127.0.0.1:\(socks) http://gitlab.internal"),
            (String(localized: "셸 전체 (~/.zshrc)"), "export ALL_PROXY=socks5h://127.0.0.1:\(socks)"),
            (String(localized: "git (특정 저장소만)"), "git config --global http.https://gitlab.internal.proxy socks5h://127.0.0.1:\(socks)"),
            (String(localized: "ssh (macOS 기본 nc)"), "ssh -o ProxyCommand='nc -X 5 -x 127.0.0.1:\(socks) %h %p' user@10.0.4.21"),
            (String(localized: "HTTP 프록시 전용 앱"), profile.httpEnabled ? "http_proxy=http://127.0.0.1:\(http) https_proxy=http://127.0.0.1:\(http)" : String(localized: "먼저 ‘HTTP 프록시도 열기’를 켜십시오.")),
            (String(localized: "DB 도구 (JDBC)"), String(localized: "SOCKS 프록시 127.0.0.1:\(socks) (대부분의 JDBC 도구에서 지원)")),
            ("Firefox", String(localized: "설정 › 네트워크 › SOCKS v5 127.0.0.1:\(socks) · ‘SOCKS v5 사용 시 DNS도 프록시’ 켜기")),
        ]
        let chosen = lines[min(instructionTab, lines.count - 1)]
        let isSystem = chosen.0 == system.0
        return VStack(alignment: .leading, spacing: 8) {
            FlowChips(titles: lines.map(\.0), selection: $instructionTab)
            if isSystem {
                Text("시스템 설정 › 네트워크 › 사용 중인 연결 › 세부사항 › 프록시에서 ‘자동 프록시 구성’을 켜고 아래 주소를 넣으십시오. 터널로 보낼 주소만 서버를 거치고 나머지는 그대로 연결됩니다. 터널을 끌 때는 그 설정도 끄십시오.")
                    .font(.ui(.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(chosen.1)
                .font(.themeMono(.caption))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .well()
            HStack(spacing: 8) {
                Button("복사") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(chosen.1, forType: .string)
                }
                .buttonStyle(PanelButtonStyle())
                if isSystem, let settings = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension") {
                    Button("네트워크 설정 열기") { NSWorkspace.shared.open(settings) }
                        .buttonStyle(PanelButtonStyle())
                }
            }
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
            Text("터널 없음")
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
            // Tinted only while a tunnel runs, so the toolbar dims it like the rest otherwise.
            if store.activeCount > 0 {
                Label("터널 \(store.activeCount)", glyph: "bt.tunnel", size: 17)
                    .foregroundStyle(Color.themeAccent)
            } else {
                Label("터널", glyph: "bt.tunnel", size: 17)
            }
        }
        .help("터널 (SSH VPN)")
    }
}
