import AppKit
import BottariCore
import BottariSFTP
import SwiftUI

/// The design's "연결 관리" screen: saved connections on the left, the
/// selected one's settings on the right. Edits are saved as they are made;
/// a typed password or passphrase goes to the Keychain once it has worked.
struct SiteManagerSheet: View {
    let library: SiteLibrary
    /// Called with the open connection and the site it belongs to.
    let onOpen: (any FileProvider, SavedSite) -> Void

    private enum Activity {
        case testing, opening
    }

    private enum Outcome {
        case success(String)
        case failure(String, hostKeyFix: HostKeyFix?, needsSecret: Bool)
    }

    /// What "trust and try again" does about a host key that was refused.
    enum HostKeyFix {
        /// Forget the remembered key, so the next one is taken.
        case forget(host: String)
        /// Remember this key, which known_hosts could not vouch for.
        case trust(host: String, key: String)

        func apply() {
            switch self {
            case .forget(let host): AppServices.knownHosts.forget(hostKeyID: host)
            case .trust(let host, let key): AppServices.knownHosts.trust(key, hostKeyID: host)
            }
        }
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
    @State private var isSigningIn = false

    /// `initialError` is why opening `initialSelection` from the pane menu
    /// failed, shown straight away.
    init(
        library: SiteLibrary,
        initialSelection: SavedSite.ID? = nil,
        initialError: (any Error)? = nil,
        onOpen: @escaping (any FileProvider, SavedSite) -> Void
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
            HStack(alignment: .top, spacing: 12) {
                sidebar
                    .frame(width: 280)
                    .card()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .top) {
                        if current?.tag == .prod {
                            Rectangle().fill(SavedSite.Tag.prod.color).frame(height: 3)
                        }
                    }
                    .card()
            }
            .padding(.horizontal, 12)
            if case .failure(let message, let hostKeyFix, _) = outcome {
                failureBanner(message, hostKeyFix: hostKeyFix)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
            }
            footer
        }
        .background(Palette.background)
        .themed()
        .frame(minWidth: 960, idealWidth: 1040, minHeight: 680, idealHeight: 760)
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
            String(localized: "‘\(pendingDelete?.name ?? "")’ 연결을 삭제하겠습니까?"),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { site in
            Button("삭제", role: .destructive) { delete(site) }
        } message: { _ in
            Text("키체인에 저장된 비밀번호와 키 암호도 함께 삭제됩니다.")
        }
    }

    private var header: some View {
        HStack {
            WindowHeading(title: String(localized: "연결 관리"), subtitle: String(localized: "비밀번호와 키 암호는 macOS 키체인에만 저장됨"))
            Spacer()
            Button("닫기") { dismiss() }
                .buttonStyle(PanelButtonStyle())
                .fixedSize()
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - List

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let error = library.storageError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.ui(.caption))
                        .foregroundStyle(.orange)
                }
                if !library.importableHosts.isEmpty {
                    importBanner
                }
                ForEach([(String(localized: "서버"), true), (String(localized: "클라우드"), false)], id: \.0) { title, servers in
                    let group = library.sites.filter { $0.isSFTP == servers }
                    if !group.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            SectionLabel(title).padding(.horizontal, 8).padding(.top, 4)
                            ForEach(group) { site in
                                Button {
                                    selection = site.id
                                } label: {
                                    SiteRow(site: site, isNew: library.recentlyImported.contains(site.id))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 6)
                                        .background(selection == site.id ? Palette.selection : .clear, in: .rect(cornerRadius: 8))
                                        .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("삭제…", role: .destructive) { pendingDelete = site }
                                }
                            }
                        }
                    }
                }
                if library.sites.isEmpty {
                    VStack(spacing: 6) {
                        Glyph("bt.server", size: 22)
                        Text("저장된 연결 없음")
                            .font(.ui(.callout, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                }
                Button {
                    selection = library.add().id
                } label: {
                    Label("새 연결", systemImage: "plus")
                }
                .buttonStyle(PanelButtonStyle(dashed: true))
                .padding(.top, 4)
            }
            .padding(12)
        }
        .scrollIndicators(.never)
    }

    private var importBanner: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("~/.ssh/config의 새 호스트 \(library.importableHosts.count)개", systemImage: "square.and.arrow.down")
                .font(.ui(.callout, weight: .semibold))
            Text(library.importableHosts.map(\.alias).joined(separator: " · "))
                .font(.themeMono(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text("ProxyJump, ProxyCommand, IdentityFile, Match 설정 포함")
                .font(.ui(.caption))
                .foregroundStyle(.secondary)
            Button("가져오기") {
                let added = library.importSSHConfig()
                if let first = added.first { selection = first.id }
            }
            .buttonStyle(PanelButtonStyle(prominent: true))
            .fixedSize()
            .padding(.top, 4)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.selection, in: .rect(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.themeAccent.opacity(0.35)))
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
                secretFocused: $secretFocused,
                isSigningIn: isSigningIn,
                isSignedIn: library.isSignedInToGoogle(site),
                signIn: { Task { await signIn(id) } },
                signOut: { if let site = library.site(id) { library.signOutOfGoogle(site) } }
            )
            .disabled(activity != nil)
            // Its own state (settings set aside while switching kinds) is per site.
            .id(id)
            .onChange(of: library.site(id)) {
                if case .success = outcome { outcome = nil }
            }
        } else {
            ContentUnavailableView("연결 선택", systemImage: "sidebar.left")
        }
    }

    private func failureBanner(_ message: String, hostKeyFix: HostKeyFix?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let hostKeyFix {
                Button("새 호스트 키를 신뢰하고 다시 시도", role: .destructive) {
                    hostKeyFix.apply()
                    Task { await run(lastActivity) }
                }
            }
        }
        .font(.ui(.callout))
        .padding(12)
        .background(Color.orange.opacity(0.08), in: .rect(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.orange.opacity(0.35)))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(activity == .testing ? String(localized: "연결 확인 중…") : String(localized: "연결 테스트")) {
                Task { await run(.testing) }
            }
            .buttonStyle(PanelButtonStyle())
            .fixedSize()
            .disabled(!canConnect || activity != nil)
            if activity != nil {
                ProgressView()
                    .controlSize(.small)
            } else if case .success(let message) = outcome {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.ui(.callout))
                    .foregroundStyle(Color(light: 0x0F7C5A, dark: 0x3CC48E))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("저장하고 열기") {
                Task { await run(.opening) }
            }
            .buttonStyle(PanelButtonStyle(prominent: true))
            .fixedSize()
            .keyboardShortcut(.defaultAction)
            .disabled(!canConnect || activity != nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var canConnect: Bool {
        guard let site = current else { return false }
        switch site.kind {
        case .s3(let settings):
            return !settings.bucket.isEmpty && !settings.accessKey.isEmpty
        case .googleDrive(let settings):
            return (!settings.clientID.isEmpty || GoogleClient.builtIn != nil) && library.isSignedInToGoogle(site)
        case .sftp:
            break
        }
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
        if case .s3 = site.kind {
            if !password.isEmpty { typed[site.s3SecretKey] = password }
        } else {
            if !password.isEmpty { typed[site.passwordKey] = password }
            if !passphrase.isEmpty { typed[site.passphraseKey] = passphrase }
        }
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
                var parts = [String(localized: "연결 성공")]
                if let server = provider as? SFTPFileProvider {
                    parts.append(String(localized: "홈 \(server.home.string)"))
                    if !site.proxyJump.isEmpty { parts.append(String(localized: "\(site.proxyJump.joined(separator: " → ")) 경유")) }
                    parts.append(server.canRunCommands ? String(localized: "명령 실행 가능") : String(localized: "SFTP 전용"))
                    parts.append("\(milliseconds) ms")
                    await server.disconnect()
                } else {
                    let count = (try? await provider.list(.root).count) ?? 0
                    parts.append(String(localized: "최상위 항목 \(count)개"))
                    parts.append("\(milliseconds) ms")
                }
                outcome = .success(parts.joined(separator: " · "))
            case .opening:
                onOpen(provider, site)
                dismiss()
            }
        } catch {
            outcome = Self.failure(error)
            if case .failure(_, _, true) = outcome { secretFocused = true }
        }
    }

    private func signIn(_ id: SavedSite.ID) async {
        guard let site = library.site(id) else { return }
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            try await library.signInToGoogle(site, clientSecret: passphrase)
            passphrase = ""
            outcome = .success(String(localized: "Google 계정으로 로그인됨"))
        } catch {
            outcome = Self.failure(error)
        }
    }

    private static func failure(_ error: any Error) -> Outcome {
        var hostKeyFix: HostKeyFix?
        switch error {
        case SFTPConnectError.hostKeyChanged(let host, _, _):
            hostKeyFix = .forget(host: host)
        case SFTPConnectError.hostKeyNotListed(let host, _, let key):
            hostKeyFix = .trust(host: host, key: key)
        default:
            break
        }
        var needsSecret = false
        switch error {
        case SiteConnectError.passwordMissing, SiteConnectError.passwordUnreadable:
            needsSecret = true
        default:
            break
        }
        return .failure(error.localizedDescription, hostKeyFix: hostKeyFix, needsSecret: needsSecret)
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
                        .font(.ui(.body, weight: .semibold))
                        .lineLimit(1)
                    if isNew {
                        Text("가져옴")
                            .font(.ui(.caption2))
                            .padding(.horizontal, 4)
                            .background(Color.themeAccent.opacity(0.15), in: .rect(cornerRadius: 3))
                    }
                }
                Text(site.summary)
                    .font(.themeMono(.caption))
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
                TagChip.outlined(tag)
            }
        }
    }
}

private enum AuthKind: CaseIterable, Identifiable {
    case agent, keyFile, password

    var id: Self { self }

    var label: String {
        switch self {
        case .agent: String(localized: "SSH 에이전트")
        case .keyFile: String(localized: "키 파일")
        case .password: String(localized: "비밀번호")
        }
    }

    var hint: String {
        switch self {
        case .agent: String(localized: "ssh-agent 또는 1Password 에이전트의 키 사용, 맞는 키가 없으면 ~/.ssh의 id_ed25519, id_ecdsa, id_rsa 시도")
        case .keyFile: String(localized: "OpenSSH 형식 개인 키(Ed25519, RSA). 키 암호는 키체인에 저장됨")
        case .password: String(localized: "키체인에 저장됨")
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

    let isSigningIn: Bool
    /// This Mac holds a Google sign-in for the site.
    let isSignedIn: Bool
    let signIn: () -> Void
    let signOut: () -> Void

    /// What the site had before the user clicked another kind or sign-in
    /// method, so clicking back (a slip, say) brings it back instead of blanks.
    @State private var kindsSetAside: [Int: SavedSite.Kind] = [:]
    @State private var authenticationsSetAside: [AuthKind: SavedSite.Authentication] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(String(localized: "종류"))
                    HStack(spacing: 8) {
                        kindCard(0, "SFTP", String(localized: "SSH 서버"), "bt.server")
                        kindCard(1, "S3", "AWS, R2, MinIO", "bt.bucket")
                        kindCard(2, "Google Drive", String(localized: "OAuth 로그인"), "bt.cloud")
                        Spacer()
                    }
                    Text(kindHint).font(.ui(.caption)).foregroundStyle(.secondary)
                }
                switch site.kind {
                case .sftp:
                    sftpFields
                case .s3:
                    s3Fields
                case .googleDrive:
                    driveFields
                }
                Rectangle().fill(Palette.line).frame(height: 1)
                safety
            }
            .padding(20)
        }
        .scrollIndicators(.never)
    }

    private func kindCard(_ choice: Int, _ title: String, _ subtitle: String, _ symbol: String) -> some View {
        let selected = kindChoice.wrappedValue == choice
        return Button {
            kindChoice.wrappedValue = choice
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Glyph(symbol, size: 18)
                    .foregroundStyle(selected ? Color.themeAccent : .secondary)
                Text(title).font(.ui(.callout, weight: .semibold))
                Text(subtitle).font(.ui(.caption)).foregroundStyle(.secondary)
            }
            .frame(width: 128, alignment: .leading)
            .padding(12)
            .background(selected ? Palette.selection : Palette.panel, in: .rect(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? Color.themeAccent : Palette.line, lineWidth: selected ? 1.5 : 1))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var kindHint: String {
        switch site.kind {
        case .sftp: String(localized: "이 연결로 터미널과 원격 화면도 열 수 있음")
        case .s3: String(localized: "AWS, Cloudflare R2, MinIO 등 S3 호환 저장소")
        case .googleDrive: String(localized: "공유 드라이브 포함")
        }
    }

    private var kindChoice: Binding<Int> {
        Binding(
            get: {
                switch site.kind {
                case .sftp: 0
                case .s3: 1
                case .googleDrive: 2
                }
            },
            set: { choice in
                let current = switch site.kind {
                case .sftp: 0
                case .s3: 1
                case .googleDrive: 2
                }
                guard choice != current else { return }
                kindsSetAside[current] = site.kind
                let fresh: SavedSite.Kind = switch choice {
                case 1: .s3(SavedSite.S3Settings())
                case 2: .googleDrive(SavedSite.DriveSettings())
                default: .sftp
                }
                site.kind = kindsSetAside[choice] ?? fresh
            }
        )
    }

    private var s3: Binding<SavedSite.S3Settings> {
        Binding(
            get: { if case .s3(let settings) = site.kind { settings } else { SavedSite.S3Settings() } },
            set: { site.kind = .s3($0) }
        )
    }

    private var drive: Binding<SavedSite.DriveSettings> {
        Binding(
            get: { if case .googleDrive(let settings) = site.kind { settings } else { SavedSite.DriveSettings() } },
            set: { site.kind = .googleDrive($0) }
        )
    }

    @ViewBuilder
    private var s3Fields: some View {
        LabeledField(String(localized: "이름")) { TextField("이름", text: $site.name).designField() }
        HStack(alignment: .top, spacing: 12) {
            LabeledField(String(localized: "버킷")) { TextField("버킷", text: s3.bucket).designField(mono: true) }
            LabeledField(String(localized: "리전")) { TextField("리전", text: s3.region, prompt: Text("us-east-1")).designField(mono: true) }
                .frame(width: 180)
        }
        LabeledField(String(localized: "엔드포인트"), hint: String(localized: "비워 두면 AWS 사용")) {
            TextField("엔드포인트", text: s3.endpoint, prompt: Text(verbatim: "s3.amazonaws.com")).designField(mono: true)
        }
        SwitchRow(title: String(localized: "경로 방식 주소"), detail: String(localized: "버킷 이름을 주소 경로에 넣음 (MinIO 등)"), isOn: s3.usesPathStyle)
        HStack(alignment: .top, spacing: 12) {
            LabeledField(String(localized: "액세스 키")) { TextField("액세스 키", text: s3.accessKey).designField(mono: true) }
            LabeledField(String(localized: "비밀 키"), hint: String(localized: "연결에 성공하면 키체인에 저장")) {
                SecureField("비밀 키", text: $password, prompt: Text("비워 두면 저장된 키 사용"))
                    .focused(secretFocused)
                    .designField()
            }
        }
    }

    @ViewBuilder
    private var driveFields: some View {
        LabeledField(String(localized: "이름")) { TextField("이름", text: $site.name).designField() }
        HStack(spacing: 12) {
            Image(systemName: isSignedIn ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.questionmark")
                .font(.ui(.title2))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Group {
                    if isSignedIn {
                        Text(drive.wrappedValue.account.isEmpty ? String(localized: "로그인됨") : String(localized: "로그인됨 · \(drive.wrappedValue.account)"))
                    } else if !drive.wrappedValue.account.isEmpty {
                        // Signed in on another Mac; this one needs its own sign-in.
                        Text("이 Mac에서 로그인 필요 · \(drive.wrappedValue.account)")
                    } else {
                        Text("연결된 Google 계정 없음")
                    }
                }
                .font(.ui(.body, weight: .medium))
                Text(isSignedIn ? String(localized: "토큰은 키체인에 저장됨") : String(localized: "브라우저에서 Google 로그인 창이 열림"))
                    .font(.ui(.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isSigningIn {
                ProgressView().controlSize(.small)
            } else if !isSignedIn {
                Button("Google 계정으로 로그인", action: signIn)
                    .buttonStyle(PanelButtonStyle(prominent: true))
                    .fixedSize()
                    .disabled(drive.wrappedValue.clientID.isEmpty && GoogleClient.builtIn == nil)
            } else {
                Button("로그아웃", action: signOut)
                    .buttonStyle(PanelButtonStyle())
                    .fixedSize()
            }
        }
        .padding(14)
        .well()
        LabeledField(
            String(localized: "OAuth 클라이언트 ID"),
            hint: GoogleClient.builtIn != nil
                ? String(localized: "비워 두면 Bottari의 클라이언트를 사용합니다. 직접 만든 데스크톱 앱 클라이언트를 쓰려면 입력하십시오.")
                : String(localized: "Google Cloud에서 만든 데스크톱 앱 클라이언트. 테스트 상태에서는 7일마다 다시 로그인해야 합니다.")
        ) {
            TextField("OAuth 클라이언트 ID", text: drive.clientID, prompt: Text(GoogleClient.builtIn != nil ? String(localized: "Bottari 기본 클라이언트") : "…apps.googleusercontent.com")).designField(mono: true)
        }
        LabeledField(String(localized: "클라이언트 보안 비밀")) {
            SecureField("클라이언트 보안 비밀", text: $passphrase, prompt: Text("비워 두면 저장된 값 사용")).designField()
        }
        LabeledField(String(localized: "Google 문서 내보내기 형식"), hint: String(localized: "Google 문서, 스프레드시트, 프레젠테이션을 받을 때 이 형식으로 변환")) {
            HStack(spacing: 6) {
                ForEach([("office", "DOCX / XLSX / PPTX"), ("pdf", "PDF"), ("openDocument", "ODT / ODS / ODP")], id: \.0) { value, title in
                    Button(title) { drive.wrappedValue.exportFormat = value }
                        .buttonStyle(ChoiceButtonStyle(isOn: drive.wrappedValue.exportFormat == value))
                        .fixedSize()
                }
            }
        }
    }

    @ViewBuilder
    private var sftpFields: some View {
        LabeledField(String(localized: "이름")) { TextField("이름", text: $site.name).designField() }
        HStack(alignment: .top, spacing: 12) {
            LabeledField(String(localized: "호스트")) {
                TextField("호스트", text: $site.endpoint.host, prompt: Text("example.com")).designField(mono: true)
            }
            LabeledField(String(localized: "포트")) {
                TextField("포트", value: $site.endpoint.port, format: .number.grouping(.never)).designField(mono: true)
            }
            .frame(width: 140)
        }
        HStack(alignment: .top, spacing: 12) {
            LabeledField(String(localized: "사용자")) { TextField("사용자", text: $site.endpoint.username).designField(mono: true) }
            LabeledField(String(localized: "시작 폴더")) {
                TextField("시작 폴더", text: optional(\.startPath), prompt: Text(verbatim: "~")).designField(mono: true)
            }
        }
        LabeledField(String(localized: "인증"), hint: site.authentication.kind.hint) {
            HStack(spacing: 6) {
                ForEach(AuthKind.allCases) { kind in
                    Button(kind.label) { authKind.wrappedValue = kind }
                        .buttonStyle(ChoiceButtonStyle(isOn: site.authentication.kind == kind))
                        .fixedSize()
                }
            }
            switch site.authentication {
            case .agent:
                TextField("에이전트 소켓", text: agentSocket, prompt: Text(verbatim: "$SSH_AUTH_SOCK")).designField(mono: true)
            case .keyFile:
                HStack {
                    TextField("키 파일", text: keyPath, prompt: Text("~/.ssh/id_ed25519")).designField(mono: true)
                    Button("선택…", action: chooseKey)
                        .buttonStyle(PanelButtonStyle())
                        .fixedSize()
                }
                SecureField("키 암호", text: $passphrase, prompt: Text("키 암호 (비워 두면 저장된 암호 사용)"))
                    .focused(secretFocused)
                    .designField()
            case .password:
                SecureField("비밀번호", text: $password, prompt: Text("비밀번호 (비워 두면 저장된 비밀번호 사용)"))
                    .focused(secretFocused)
                    .designField()
            }
        }
        LabeledField(String(localized: "점프 호스트 (ProxyJump)"), hint: String(localized: "저장된 연결 이름, ~/.ssh/config 별칭 또는 user@host:port. 쉼표로 구분하면 순서대로 경유")) {
            JumpHostField(site: $site, candidates: jumpHostNames)
                .id(site.id)
        }
        if site.proxyJump.isEmpty {
            LabeledField(String(localized: "프록시 명령 (ProxyCommand)"), hint: String(localized: "표준 입출력으로 SSH를 전달하는 명령. %h 호스트, %p 포트, %r 사용자로 바뀜")) {
                TextField("프록시 명령", text: proxyCommand, prompt: Text(verbatim: "cloudflared access ssh --hostname %h")).designField(mono: true)
            }
        }
        VStack(alignment: .leading, spacing: 10) {
            Text("원격 제어").font(.ui(.body, weight: .semibold))
            HStack(spacing: 6) {
                ForEach([(SavedSite.RemoteScreen.Kind?.none, String(localized: "사용 안 함")), (.some(.vnc), "VNC"), (.some(.appleScreenSharing), String(localized: "macOS 화면 공유"))], id: \.1) { kind, title in
                    Button(title) { screenKind.wrappedValue = kind }
                        .buttonStyle(ChoiceButtonStyle(isOn: site.remoteScreen?.kind == kind))
                        .fixedSize()
                }
            }
            if site.remoteScreen != nil {
                HStack(alignment: .bottom, spacing: 12) {
                    LabeledField(String(localized: "화면 포트")) {
                        TextField("화면 포트", value: screenPort, format: .number.grouping(.never)).designField(mono: true)
                    }
                    .frame(width: 140)
                    SwitchRow(
                        title: String(localized: "SSH 터널로 연결"),
                        detail: site.remoteScreen?.throughTunnel == true
                            ? String(localized: "서버 방화벽에 화면 포트를 열 필요 없음")
                            : String(localized: "직접 연결 (VNC는 암호화가 약해 권장하지 않음)"),
                        isOn: screenTunnel
                    )
                }
            }
            Text(screenHint).font(.ui(.caption)).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .well()
    }

    private var safety: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(String(localized: "구분과 안전"))
            TagPicker(tag: tag)
            SwitchRow(title: String(localized: "읽기 전용으로 열기"), detail: String(localized: "쓰기와 삭제 버튼 숨김"), isOn: $site.readOnly)
            SwitchRow(title: String(localized: "쓰기 전에 항상 확인"), detail: site.tag == .prod ? String(localized: "PROD 태그에서는 자동으로 켜짐") : String(localized: "복사, 삭제, 덮어쓰기 전에 확인"), isOn: $site.confirmsWrites)
            Text("PROD로 지정하면 패인 위에 색 띠가 표시되고, 파일을 쓰기 전에 항상 확인합니다.")
                .font(.ui(.caption))
                .foregroundStyle(.secondary)
        }
    }

    private var screenKind: Binding<SavedSite.RemoteScreen.Kind?> {
        Binding(
            get: { site.remoteScreen?.kind },
            set: { kind in
                if let kind {
                    var screen = site.remoteScreen ?? SavedSite.RemoteScreen(kind: kind)
                    screen.kind = kind
                    site.remoteScreen = screen
                } else {
                    site.remoteScreen = nil
                }
            }
        )
    }

    private var screenPort: Binding<Int> {
        Binding(get: { site.remoteScreen?.port ?? 5900 }, set: { site.remoteScreen?.port = $0 })
    }

    private var screenTunnel: Binding<Bool> {
        Binding(get: { site.remoteScreen?.throughTunnel ?? true }, set: { site.remoteScreen?.throughTunnel = $0 })
    }

    private var screenHint: String {
        switch site.remoteScreen?.kind {
        case nil: String(localized: "SSH 터미널은 이 설정과 관계없이 사용 가능")
        case .vnc: String(localized: "서버에서 VNC 서버(TigerVNC, x11vnc 등)가 실행 중이어야 합니다. 비밀번호는 처음 연결할 때 입력하며 키체인에 저장됩니다.")
        case .appleScreenSharing: String(localized: "원격 Mac에서 시스템 설정 › 일반 › 공유 › 화면 공유를 켜야 합니다. macOS 계정으로 로그인합니다.")
        }
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
                authenticationsSetAside[site.authentication.kind] = site.authentication
                let fresh: SavedSite.Authentication = switch kind {
                case .agent: .agent(socket: nil)
                case .keyFile: .keyFile(path: "~/.ssh/id_ed25519")
                case .password: .password
                }
                site.authentication = authenticationsSetAside[kind] ?? fresh
            }
        )
    }

    private var agentSocket: Binding<String> {
        Binding(
            get: { if case .agent(let socket) = site.authentication { socket ?? "" } else { "" } },
            set: { site.authentication = .agent(socket: $0.isEmpty ? nil : $0) }
        )
    }

    private var proxyCommand: Binding<String> {
        Binding(
            get: { site.proxyCommand ?? "" },
            set: {
                site.proxyCommand = $0.isEmpty ? nil : $0
                // Typed here, so it may run here.
                if !$0.isEmpty { SiteLibrary.allowProxyCommand($0.trimmingCharacters(in: .whitespaces), for: site.id) }
            }
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
        panel.title = String(localized: "개인 키 선택")
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
            TextField("경유 호스트", text: $text, prompt: Text(verbatim: "bastion"))
                .designField(mono: true)
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
                    .frame(width: 30, height: 30)
                    .background(Palette.panel, in: .rect(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.line))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
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
            chip(nil, label: String(localized: "없음"), color: .secondary.opacity(0.4))
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
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: 10, height: 10)
                Text(label)
                    .font(.ui(.callout, weight: selected ? .semibold : .regular))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(selected ? Palette.selection : Palette.panel, in: .rect(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(selected ? Color.themeAccent : Palette.line, lineWidth: selected ? 1.5 : 1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
