import AppKit
import BottariSFTP
import SwiftUI

/// The design's "연결 관리" screen: saved connections on the left, the
/// selected one's settings on the right. Edits are saved as they are made;
/// a typed password or passphrase goes to the Keychain once it has worked.
struct SiteManagerSheet: View {
    let library: SiteLibrary
    /// Called with the open connection and the site it belongs to.
    let onOpen: (SFTPFileProvider, SavedSite) -> Void

    private enum Activity {
        case testing, opening
    }

    private enum Outcome {
        case success(String)
        case failure(String, changedHostKey: String?, needsSecret: Bool)
    }

    @Environment(\.dismiss) private var dismiss
    @State private var selection: SavedSite.ID?
    @State private var password = ""
    @State private var passphrase = ""
    @State private var activity: Activity?
    @State private var lastActivity: Activity = .testing
    @State private var outcome: Outcome?
    @State private var pendingDelete: SavedSite?
    @FocusState private var secretFocused: Bool

    /// `initialError` is why opening `initialSelection` from the pane menu
    /// failed, shown straight away.
    init(
        library: SiteLibrary,
        initialSelection: SavedSite.ID? = nil,
        initialError: (any Error)? = nil,
        onOpen: @escaping (SFTPFileProvider, SavedSite) -> Void
    ) {
        self.library = library
        self.onOpen = onOpen
        _selection = State(initialValue: initialSelection ?? library.sites.first?.id)
        _outcome = State(initialValue: initialError.map(Self.failure))
    }

    private var current: SavedSite? { selection.flatMap(library.site) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 280)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if case .failure(let message, let changedHostKey, _) = outcome {
                Divider()
                failureBanner(message, changedHostKey: changedHostKey)
            }
            Divider()
            footer
        }
        .frame(minWidth: 880, idealWidth: 880, minHeight: 640, idealHeight: 640)
        .onAppear {
            library.reloadSSHConfig()
            if case .failure(_, _, true) = outcome { secretFocused = true }
        }
        .onChange(of: selection) {
            password = ""
            passphrase = ""
            outcome = nil
        }
        .confirmationDialog(
            "‘\(pendingDelete?.name ?? "")’ 연결을 지울까요?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { site in
            Button("지우기", role: .destructive) { delete(site) }
        } message: { _ in
            Text("저장된 비밀번호와 키 암호도 키체인에서 지워요.")
        }
    }

    private var header: some View {
        HStack {
            Text("연결 관리")
                .font(.title3.weight(.semibold))
            Spacer()
            Label("비밀번호와 키 암호는 macOS 키체인에만 저장해요.", systemImage: "key")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - List

    private var sidebar: some View {
        VStack(spacing: 0) {
            if let error = library.storageError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(10)
            }
            if !library.importableHosts.isEmpty {
                importBanner
                    .padding([.horizontal, .top], 10)
            }
            List(selection: $selection) {
                if !library.sites.isEmpty {
                    Section("서버") {
                        ForEach(library.sites) { site in
                            SiteRow(site: site, isNew: library.recentlyImported.contains(site.id))
                                .tag(site.id as SavedSite.ID?)
                                .contextMenu {
                                    Button("지우기…", role: .destructive) { pendingDelete = site }
                                }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if library.sites.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "server.rack")
                            .font(.title2)
                        Text("저장된 연결이 없어요")
                            .font(.callout.weight(.medium))
                        Text("아래 + 로 새 연결을 만들어요.")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack(spacing: 4) {
                Button {
                    selection = library.add().id
                } label: {
                    Label("새 연결", systemImage: "plus")
                }
                Button {
                    pendingDelete = current
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 18)
                }
                .disabled(current == nil)
                .help("선택한 연결 지우기")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    private var importBanner: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("~/.ssh/config 에서 새 호스트 \(library.importableHosts.count)개", systemImage: "square.and.arrow.down")
                .font(.callout.weight(.semibold))
            Text(library.importableHosts.map(\.alias).joined(separator: " · "))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text("ProxyJump, IdentityFile 설정도 그대로 가져와요.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("가져오기") {
                let added = library.importSSHConfig()
                if let first = added.first { selection = first.id }
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: .rect(cornerRadius: 8))
    }

    // MARK: - Settings

    @ViewBuilder
    private var detail: some View {
        if let id = selection, let site = library.site(id) {
            SiteForm(
                site: Binding(get: { library.site(id) ?? site }, set: { library.update($0) }),
                password: $password,
                passphrase: $passphrase,
                jumpHostNames: library.jumpHostNames,
                secretFocused: $secretFocused
            )
            .disabled(activity != nil)
            .onChange(of: library.site(id)) {
                if case .success = outcome { outcome = nil }
            }
        } else {
            ContentUnavailableView("연결을 골라 주세요", systemImage: "sidebar.left")
        }
    }

    private func failureBanner(_ message: String, changedHostKey: String?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let changedHostKey {
                Button("서버를 다시 설치했어요. 새 키를 믿고 다시 시도", role: .destructive) {
                    AppServices.knownHosts.forget(hostKeyID: changedHostKey)
                    Task { await run(lastActivity) }
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.08))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(activity == .testing ? "연결 확인 중…" : "연결 테스트") {
                Task { await run(.testing) }
            }
            .disabled(!canConnect || activity != nil)
            if activity != nil {
                ProgressView()
                    .controlSize(.small)
            } else if case .success(let message) = outcome {
                Label(message, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("닫기", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("저장하고 열기") {
                Task { await run(.opening) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canConnect || activity != nil)
        }
        .padding(14)
    }

    private var canConnect: Bool {
        guard let site = current else { return false }
        let endpoint = site.endpoint
        guard !endpoint.host.trimmingCharacters(in: .whitespaces).isEmpty,
              !endpoint.username.trimmingCharacters(in: .whitespaces).isEmpty,
              (1...65535).contains(endpoint.port)
        else { return false }
        if case .keyFile(let path) = site.authentication { return !path.isEmpty }
        return true
    }

    // MARK: - Actions

    private func run(_ kind: Activity) async {
        guard let site = current else { return }
        var typed: [String: String] = [:]
        if !password.isEmpty { typed[site.passwordKey] = password }
        if !passphrase.isEmpty { typed[site.passphraseKey] = passphrase }
        activity = kind
        lastActivity = kind
        outcome = nil
        defer { activity = nil }
        let started = ContinuousClock.now
        do {
            let provider = try await library.connect(site, typedSecrets: typed)
            password = ""
            passphrase = ""
            switch kind {
            case .testing:
                let elapsed = (ContinuousClock.now - started).components
                let milliseconds = elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000
                var parts = ["연결 성공", "홈 \(provider.home.string)"]
                if !site.proxyJump.isEmpty { parts.append("\(site.proxyJump.joined(separator: " → ")) 경유") }
                parts.append(provider.canRunCommands ? "명령 실행 가능" : "SFTP 전용")
                parts.append("\(milliseconds) ms")
                outcome = .success(parts.joined(separator: " · "))
                await provider.disconnect()
            case .opening:
                onOpen(provider, site)
                dismiss()
            }
        } catch {
            outcome = Self.failure(error)
            if case .failure(_, _, true) = outcome { secretFocused = true }
        }
    }

    private static func failure(_ error: any Error) -> Outcome {
        var changedHostKey: String?
        if case SFTPConnectError.hostKeyChanged(let host, _, _) = error {
            changedHostKey = host
        }
        var needsSecret = false
        if case SiteConnectError.passwordMissing = error {
            needsSecret = true
        }
        return .failure(error.localizedDescription, changedHostKey: changedHostKey, needsSecret: needsSecret)
    }

    private func delete(_ site: SavedSite) {
        let index = library.sites.firstIndex(of: site)
        library.remove(site.id)
        if selection == site.id {
            let remaining = library.sites
            selection = index.flatMap { remaining.indices.contains($0) ? remaining[$0].id : remaining.last?.id }
        }
    }
}

/// One saved connection in the list: tag stripe, name, `user@host`, tag chip.
private struct SiteRow: View {
    let site: SavedSite
    let isNew: Bool

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(site.tag?.color ?? Color.secondary.opacity(0.3))
                .frame(width: 3, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(site.name)
                        .lineLimit(1)
                    if isNew {
                        Text("가져옴")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .background(Color.accentColor.opacity(0.15), in: .rect(cornerRadius: 3))
                    }
                }
                Text(site.summary)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if site.readOnly {
                Image(systemName: "lock")
                    .foregroundStyle(.secondary)
                    .help("읽기 전용")
            }
            if let tag = site.tag {
                TagChip(tag: tag)
            }
        }
        .padding(.vertical, 2)
    }
}

private enum AuthKind: CaseIterable, Identifiable {
    case agent, keyFile, password

    var id: Self { self }

    var label: String {
        switch self {
        case .agent: "SSH 에이전트"
        case .keyFile: "키 파일"
        case .password: "비밀번호"
        }
    }

    var hint: String {
        switch self {
        case .agent: "ssh-agent 또는 1Password 에이전트의 키를 그대로 써요. 키 파일을 앱에 넣지 않아요."
        case .keyFile: "OpenSSH 형식의 Ed25519 키를 추천해요. 키 암호는 키체인에 저장해요."
        case .password: "키체인에 저장해요. 가능하면 키 인증을 쓰세요."
        }
    }
}

private extension SavedSite.Authentication {
    var kind: AuthKind {
        switch self {
        case .agent: .agent
        case .keyFile: .keyFile
        case .password: .password
        }
    }
}

/// Settings for one site, edited in place.
private struct SiteForm: View {
    @Binding var site: SavedSite
    @Binding var password: String
    @Binding var passphrase: String
    let jumpHostNames: [String]
    var secretFocused: FocusState<Bool>.Binding

    var body: some View {
        Form {
            Section("서버") {
                TextField("이름", text: $site.name)
                TextField("호스트", text: $site.endpoint.host, prompt: Text("example.com"))
                TextField("포트", value: $site.endpoint.port, format: .number.grouping(.never))
                TextField("사용자", text: $site.endpoint.username)
                TextField("시작 폴더", text: optional(\.startPath), prompt: Text("~ (로그인 폴더)"))
            }

            Section {
                Picker("인증", selection: authKind) {
                    ForEach(AuthKind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                switch site.authentication {
                case .agent:
                    TextField("에이전트 소켓", text: agentSocket, prompt: Text("SSH_AUTH_SOCK"))
                case .keyFile:
                    HStack {
                        TextField("키 파일", text: keyPath, prompt: Text("~/.ssh/id_ed25519"))
                        Button("선택…", action: chooseKey)
                    }
                    SecureField("키 암호", text: $passphrase, prompt: Text("비워 두면 저장된 암호를 써요"))
                        .focused(secretFocused)
                case .password:
                    SecureField("비밀번호", text: $password, prompt: Text("비워 두면 저장된 비밀번호를 써요"))
                        .focused(secretFocused)
                }
            } header: {
                Text("인증")
            } footer: {
                Text(site.authentication.kind.hint)
                    .foregroundStyle(.secondary)
            }

            Section {
                JumpHostField(site: $site, candidates: jumpHostNames)
                    .id(site.id)
            } header: {
                Text("점프 호스트 (ProxyJump)")
            } footer: {
                Text("저장된 연결 이름, ~/.ssh/config 별칭, user@host:port 를 쉼표로 이어 쓰면 차례로 거쳐요.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("색 태그") {
                    TagPicker(tag: tag)
                }
                Toggle(isOn: $site.readOnly) {
                    Text("읽기 전용으로 열기")
                    Text("쓰기 · 삭제 버튼을 숨겨요")
                }
                Toggle(isOn: $site.confirmsWrites) {
                    Text("쓰기 전에 항상 확인")
                    Text(site.tag == .prod ? "PROD 태그라 자동으로 켜져요" : "복사 · 삭제 · 덮어쓰기 전에 물어봐요")
                }
            } header: {
                Text("구분과 안전")
            } footer: {
                Text("PROD 로 지정하면 패인 위에 띠가 생기고, 파일을 쓰기 전에 항상 확인해요.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// A text field for an optional setting, where empty means unset.
    private func optional(_ keyPath: WritableKeyPath<SavedSite, String?>) -> Binding<String> {
        Binding(
            get: { site[keyPath: keyPath] ?? "" },
            set: { site[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    private var authKind: Binding<AuthKind> {
        Binding(
            get: { site.authentication.kind },
            set: { kind in
                guard kind != site.authentication.kind else { return }
                site.authentication = switch kind {
                case .agent: .agent(socket: nil)
                case .keyFile: .keyFile(path: "~/.ssh/id_ed25519")
                case .password: .password
                }
            }
        )
    }

    private var agentSocket: Binding<String> {
        Binding(
            get: { if case .agent(let socket) = site.authentication { socket ?? "" } else { "" } },
            set: { site.authentication = .agent(socket: $0.isEmpty ? nil : $0) }
        )
    }

    private var keyPath: Binding<String> {
        Binding(
            get: { if case .keyFile(let path) = site.authentication { path } else { "" } },
            set: { site.authentication = .keyFile(path: $0) }
        )
    }

    /// PROD turns on write confirmation, as the design says.
    private var tag: Binding<SavedSite.Tag?> {
        Binding(
            get: { site.tag },
            set: { tag in
                var edited = site
                edited.tag = tag
                if tag == .prod { edited.confirmsWrites = true }
                site = edited
            }
        )
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.title = "개인 키 선택"
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh")
        if panel.runModal() == .OK, let url = panel.url {
            site.authentication = .keyFile(path: (url.path as NSString).abbreviatingWithTildeInPath)
        }
    }
}

/// Jump hosts as comma-separated text, with a menu to add known names.
private struct JumpHostField: View {
    @Binding var site: SavedSite
    let candidates: [String]
    @State private var text: String

    init(site: Binding<SavedSite>, candidates: [String]) {
        _site = site
        self.candidates = candidates
        _text = State(initialValue: site.wrappedValue.proxyJump.joined(separator: ", "))
    }

    private var addable: [String] {
        candidates.filter { $0 != site.name && $0 != site.sshConfigAlias && !site.proxyJump.contains($0) }
    }

    var body: some View {
        HStack {
            TextField("거쳐 갈 호스트", text: $text, prompt: Text("없음"))
                .onChange(of: text) {
                    site.proxyJump = text.split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                }
            Menu {
                ForEach(addable, id: \.self) { name in
                    Button(name) {
                        text = (site.proxyJump + [name]).joined(separator: ", ")
                    }
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(addable.isEmpty)
            .help("저장된 연결이나 ~/.ssh/config 호스트 추가")
        }
    }
}

/// None, PROD, STAGING, DEV, 개인 as coloured chips.
private struct TagPicker: View {
    @Binding var tag: SavedSite.Tag?

    var body: some View {
        HStack(spacing: 6) {
            chip(nil, label: "없음", color: .secondary.opacity(0.4))
            ForEach(SavedSite.Tag.allCases, id: \.self) { tag in
                chip(tag, label: tag.label, color: tag.color)
            }
        }
    }

    private func chip(_ value: SavedSite.Tag?, label: String, color: Color) -> some View {
        let selected = tag == value
        return Button {
            tag = value
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(label)
                    .fontWeight(selected ? .semibold : .regular)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(selected ? Color.accentColor.opacity(0.14) : .clear, in: .rect(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: selected ? 1.5 : 1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
