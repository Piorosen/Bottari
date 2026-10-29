import BottariSFTP
import SwiftUI

/// A connection that stopped for a password, the way `ssh` stops to ask: none
/// is saved for the site (or for a jump host on the way), the server refused
/// the one tried, or it refused the keys. A key file that needs its
/// passphrase asks for that instead.
struct PasswordRequest: Identifiable {
    let id = UUID()
    let site: SavedSite
    let side: PaneSide
    /// The site whose password it is: the one connected to, or a jump host.
    let owner: SavedSite
    /// Where the answer goes among the typed secrets, and in the Keychain if kept.
    let key: String
    let isPassphrase: Bool
    /// Why it is asked, when that is not just "nothing is saved".
    let reason: String?
    /// Passwords already typed on the way here, e.g. a jump host's.
    let typed: [String: String]
    let failed: ((any Error) -> Void)?
    let then: ((PaneModel) async -> Void)?

    /// The request `error` calls for, or nil when a password would not help.
    init?(
        site: SavedSite,
        side: PaneSide,
        error: any Error,
        typed: [String: String],
        sites: [SavedSite],
        failed: ((any Error) -> Void)?,
        then: ((PaneModel) async -> Void)?
    ) {
        switch error {
        case SiteConnectError.passwordMissing(_, let key):
            owner = sites.first { $0.passwordKey == key } ?? site
            self.key = key
            isPassphrase = false
            reason = typed[key] == nil ? nil : String(localized: "비밀번호가 맞지 않습니다.")
        case SiteConnectError.passwordUnreadable(_, let key):
            owner = sites.first { $0.passwordKey == key } ?? site
            self.key = key
            isPassphrase = false
            reason = String(localized: "키체인에 저장된 비밀번호를 읽을 수 없습니다. 다시 입력하면 새로 저장합니다.")
        case SFTPConnectError.authenticationFailed:
            owner = site
            key = site.passwordKey
            isPassphrase = false
            reason = switch (typed[key] != nil, site.authentication) {
            case (true, _): String(localized: "비밀번호가 맞지 않습니다.")
            case (false, .password): String(localized: "저장된 비밀번호가 맞지 않습니다.")
            case (false, _): String(localized: "서버가 키를 거부했습니다. 저장하면 다음부터 키가 거부될 때 이 비밀번호를 사용합니다.")
            }
        case SFTPConnectError.unreadableKey:
            guard case .keyFile = site.authentication else { return nil }
            owner = site
            key = site.passphraseKey
            isPassphrase = true
            reason = typed[key] == nil ? nil : String(localized: "키 암호가 맞지 않습니다.")
        default:
            return nil
        }
        self.site = site
        self.side = side
        self.typed = typed
        self.failed = failed
        self.then = then
    }

    /// `user@host`, with the port when it is not 22.
    var address: String {
        let endpoint = owner.endpoint
        return "\(endpoint.username)@\(endpoint.host)" + (endpoint.port == 22 ? "" : ":\(endpoint.port)")
    }
}

/// Asks for the password (or key passphrase) a connection is waiting for.
struct PasswordSheet: View {
    let request: PasswordRequest
    let submit: (_ secret: String, _ keep: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var secret = ""
    @State private var keeps = true
    @FocusState private var focused: Bool

    private var noun: String { request.isPassphrase ? String(localized: "키 암호") : String(localized: "비밀번호") }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Glyph("bt.server", size: 26)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("‘\(request.owner.name)’ \(noun) 입력")
                        .font(.ui(.title3, weight: .semibold))
                    Text(request.address)
                        .font(.themeMono(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if let reason = request.reason {
                Text(reason)
                    .font(.ui(.callout))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if request.owner.id != request.site.id {
                Text("‘\(request.site.name)’에 가는 길에 거치는 점프 호스트")
                    .font(.ui(.caption))
                    .foregroundStyle(.secondary)
            }
            SecureField(noun, text: $secret)
                .designField()
                .focused($focused)
                .onSubmit(connect)
            Toggle("키체인에 저장", isOn: $keeps)
                .font(.ui(.callout))
            HStack {
                Spacer()
                Button("취소", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("연결", action: connect)
                    .keyboardShortcut(.defaultAction)
                    .disabled(secret.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { focused = true }
    }

    private func connect() {
        guard !secret.isEmpty else { return }
        submit(secret, keeps)
        dismiss()
    }
}
