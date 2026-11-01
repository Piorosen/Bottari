import AppKit
import BottariCore
import BottariSFTP
import SwiftUI

/// Putting an SSH key on a server that Bottari reached with a password, the
/// way `ssh-copy-id` would, so the password can go.
struct KeySetupRequest: Identifiable {
    let id = UUID()
    let site: SavedSite
    /// The connection just made, to put the key on; nil connects anew.
    let provider: SFTPFileProvider?
    /// Offered after a password login, rather than asked for in the connection manager.
    let isOffer: Bool
    /// Passwords typed on the way, for connecting anew when there is no `provider`.
    var typed: [String: String] = [:]
}

/// When to offer a key after a password login.
enum KeySetupOffers {
    static let enabledKey = "keys.offerAfterPasswordLogin"
    private static let declinedKey = "keys.declinedSites"

    /// Settings › 연결 turns the offer off for every site.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// The site logged in with a password: its own way, or because its key
    /// was out of reach or refused and a password was typed.
    static func shouldOffer(for site: SavedSite, typed: [String: String]) -> Bool {
        guard isEnabled, site.isSFTP, !site.readOnly, !isDeclined(site.id) else { return false }
        if case .password = site.authentication { return true }
        return typed[site.passwordKey] != nil
    }

    static func isDeclined(_ site: SavedSite.ID) -> Bool {
        (UserDefaults.standard.stringArray(forKey: declinedKey) ?? []).contains(site.uuidString)
    }

    static func decline(_ site: SavedSite.ID) {
        let declined = UserDefaults.standard.stringArray(forKey: declinedKey) ?? []
        UserDefaults.standard.set(declined + [site.uuidString], forKey: declinedKey)
    }

    static func forgetDeclines() {
        UserDefaults.standard.removeObject(forKey: declinedKey)
    }
}

enum KeySetupStep {
    case generating, installing, checking
}

struct KeySetupError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension SiteLibrary {
    /// The saved sites `site` goes through on the way, outermost first.
    func jumpSites(of site: SavedSite, visiting: Set<SavedSite.ID> = []) -> [SavedSite] {
        site.proxyJump.flatMap { name -> [SavedSite] in
            guard let jump = sites.first(where: { $0.name == name || $0.sshConfigAlias == name }),
                  !visiting.contains(jump.id), jump.id != site.id else { return [] }
            return jumpSites(of: jump, visiting: visiting.union([site.id])) + [jump]
        }
    }

    /// Makes a key of `kind`, puts it in the server's `~/.ssh/authorized_keys`
    /// over `provider` (or a new connection), checks that the key alone logs
    /// in, then keeps it in this Mac's Keychain and switches the site to it.
    /// The saved password goes too when `forgettingPassword`. Until the key
    /// is known to work, the site stays as it was.
    func switchToKey(
        _ site: SavedSite,
        kind: NewSSHKey.Kind,
        over provider: SFTPFileProvider?,
        typedSecrets: [String: String] = [:],
        forgettingPassword: Bool,
        progress: (KeySetupStep) -> Void
    ) async throws -> NewSSHKey {
        progress(.generating)
        let comment = "bottari@" + (Host.current().localizedName ?? "Mac").replacingOccurrences(of: " ", with: "-")
        let key = try await Task.detached { try NewSSHKey.generate(kind, comment: comment) }.value

        progress(.installing)
        if let provider, provider.isConnected {
            try await provider.authorize(publicKey: key.publicKey)
        } else {
            let opened: SFTPFileProvider
            do {
                opened = try await connectSFTP(site, typedSecrets: typedSecrets, keepingTypedSecrets: false)
            } catch let error as SiteConnectError {
                throw KeySetupError(message: error.localizedDescription + " " + String(localized: "먼저 비밀번호로 연결한 뒤 다시 시도하십시오."))
            }
            do {
                try await opened.authorize(publicKey: key.publicKey)
            } catch {
                await opened.disconnect()
                throw error
            }
            await opened.disconnect()
        }

        progress(.checking)
        // The key alone, the way the next connection logs in: a stand-in
        // site has no saved password to fall back on.
        var probeSite = site
        probeSite.id = UUID()
        probeSite.authentication = .storedKey
        do {
            let probe = try await connectSFTP(probeSite, typedSecrets: [probeSite.privateKeyKey: key.privateKey], keepingTypedSecrets: false)
            await probe.disconnect()
        } catch SFTPConnectError.authenticationFailed {
            throw KeySetupError(message: String(localized: "키를 서버의 ~/.ssh/authorized_keys에 넣었지만 서버가 이 키로 로그인을 받지 않습니다. sshd 설정(PubkeyAuthentication, AuthorizedKeysFile)이나 홈 폴더 권한(그룹과 다른 사용자가 쓸 수 없어야 함)을 확인하십시오. 로그인 방식은 바꾸지 않았습니다."))
        }

        try secrets.setSecret(key.privateKey, for: site.privateKeyKey)
        var updated = self.site(site.id) ?? site
        updated.authentication = .storedKey
        update(updated)
        if forgettingPassword {
            try? secrets.setSecret(nil, for: site.passwordKey)
        }
        Log.connection.info("\(site.name): Bottari 키로 바꿈 (\(kind.rawValue), \(key.fingerprint))")
        return key
    }

    /// Logs in with the site's Bottari key and takes that key out of the
    /// server's `~/.ssh/authorized_keys`, before the site is deleted.
    func removeKeyFromServer(_ site: SavedSite) async throws {
        guard let key = storedKey(of: site) else { return }
        let provider = try await connectSFTP(site, keepingTypedSecrets: false)
        do {
            try await provider.unauthorize(publicKey: key.publicKey)
        } catch {
            await provider.disconnect()
            throw error
        }
        await provider.disconnect()
        Log.connection.info("\(site.name): 서버의 authorized_keys에서 Bottari 키를 지움 (\(key.fingerprint))")
    }

    /// The key Bottari keeps for the site on this Mac, if any.
    func storedKey(of site: SavedSite) -> NewSSHKey? {
        guard let text = try? secrets.readableSecret(for: site.privateKeyKey) else { return nil }
        return NewSSHKey(privateKey: text)
    }
}

extension NewSSHKey.Kind {
    var title: String {
        switch self {
        case .ed25519: "Ed25519"
        case .ecdsa: "ECDSA P-256"
        case .rsa: "RSA 4096"
        }
    }

    var detail: String {
        switch self {
        case .ed25519: String(localized: "권장. 짧고 빠르며 OpenSSH 6.5 이후 서버는 모두 받습니다.")
        case .ecdsa: String(localized: "Ed25519를 받지 않는 서버용(FIPS 모드 등).")
        case .rsa: String(localized: "오래된 서버와 장비용. rsa-sha2-512, rsa-sha2-256 순서로 서명하고, 둘 다 모르는 서버에만 SHA-1을 씁니다.")
        }
    }
}

/// Offers, makes and installs the key, then shows what was done.
struct KeySetupSheet: View {
    let request: KeySetupRequest
    /// Called once the site logs in with its new key.
    var finished: (NewSSHKey) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var kind = NewSSHKey.Kind.ed25519
    @State private var forgetsPassword = true
    @State private var step: KeySetupStep?
    @State private var error: String?
    @State private var made: NewSSHKey?

    private var library: SiteLibrary { AppServices.sites }
    private var site: SavedSite { library.site(request.site.id) ?? request.site }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Glyph("bt.server", size: 26)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(made == nil
                        ? (request.isOffer ? String(localized: "‘\(site.name)’에 SSH 키로 로그인할까요?") : String(localized: "‘\(site.name)’ SSH 키 만들기"))
                        : String(localized: "‘\(site.name)’은(는) 이제 키로 로그인합니다"))
                        .font(.ui(.title3, weight: .semibold))
                    Text("\(site.endpoint.username)@\(site.endpoint.host)" + (site.endpoint.port == 22 ? "" : ":\(site.endpoint.port)"))
                        .font(.themeMono(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if let made {
                done(made)
            } else {
                choices
            }
        }
        .padding(20)
        .frame(width: 460)
        .interactiveDismissDisabled(step != nil)
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Bottari가 이 Mac에서 키를 만들어 서버의 ~/.ssh/authorized_keys에 넣고, 그 키만으로 로그인되는지 확인한 뒤 바꿉니다. 개인 키는 이 Mac의 키체인에만 둡니다.")
                .font(.ui(.callout))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(NewSSHKey.Kind.allCases, id: \.self) { option in
                        Button(option.title) { kind = option }
                            .buttonStyle(ChoiceButtonStyle(isOn: kind == option))
                            .fixedSize()
                    }
                }
                Text(kind.detail)
                    .font(.ui(.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(step != nil)
            Toggle("키로 로그인되면 저장된 비밀번호 지우기", isOn: $forgetsPassword)
                .font(.ui(.callout))
                .disabled(step != nil)
            if let step {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(Self.describe(step)).font(.ui(.callout)).foregroundStyle(.secondary)
                }
            }
            if let error {
                Text(error)
                    .font(.ui(.callout))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack {
                if request.isOffer {
                    Button("다시 묻지 않기") {
                        KeySetupOffers.decline(site.id)
                        dismiss()
                    }
                    .buttonStyle(PanelButtonStyle())
                    .fixedSize()
                    .disabled(step != nil)
                }
                Spacer()
                Button(request.isOffer ? String(localized: "나중에") : String(localized: "취소"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(step != nil)
                Button("키 만들고 설치", action: install)
                    .keyboardShortcut(.defaultAction)
                    .disabled(step != nil)
            }
        }
    }

    private func done(_ key: NewSSHKey) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(forgetsPassword
                ? String(localized: "서버에 키를 넣고 키로 로그인되는 것을 확인했습니다. 저장된 비밀번호는 지웠습니다.")
                : String(localized: "서버에 키를 넣고 키로 로그인되는 것을 확인했습니다."))
                .font(.ui(.callout))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            KeySummary(key: key)
            HStack {
                Spacer()
                Button("닫기") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private static func describe(_ step: KeySetupStep) -> String {
        switch step {
        case .generating: String(localized: "키 만드는 중…")
        case .installing: String(localized: "서버의 authorized_keys에 넣는 중…")
        case .checking: String(localized: "키로 로그인되는지 확인하는 중…")
        }
    }

    private func install() {
        error = nil
        let site = site
        Task {
            do {
                let key = try await library.switchToKey(site, kind: kind, over: request.provider, typedSecrets: request.typed, forgettingPassword: forgetsPassword) { step = $0 }
                step = nil
                made = key
                finished(key)
            } catch {
                step = nil
                self.error = error.localizedDescription
            }
        }
    }
}

/// A key's kind and fingerprint, with its public half to copy.
struct KeySummary: View {
    let key: NewSSHKey

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(key.kind.title).font(.ui(.callout, weight: .semibold))
                Text(key.fingerprint)
                    .font(.themeMono(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Button("공개 키 복사") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(key.publicKey, forType: .string)
                }
                .buttonStyle(PanelButtonStyle())
                Button("개인 키 내보내기…") { export() }
                    .buttonStyle(PanelButtonStyle())
            }
            .fixedSize()
        }
        .padding(12)
        .well()
    }

    /// Saves the private key where the user picks, for `ssh` or another Mac.
    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "bottari_\(key.kind.rawValue)"
        panel.message = String(localized: "개인 키는 암호 없이 저장됩니다. 다른 사람이 읽을 수 없는 곳에 두십시오.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try key.privateKey.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
