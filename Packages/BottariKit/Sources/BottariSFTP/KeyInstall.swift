import BottariCore
import Foundation

public enum KeySetupStep: Sendable {
    case generating, installing, checking
}

public struct KeySetupError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

extension SavedSite {
    /// Puts `key` in the server's `file` (`~/.ssh/authorized_keys`) over
    /// `provider`, or a connection of its own, and checks that the key alone
    /// logs in. Then `previous`, the key this Mac kept for the site, comes out
    /// of the file if Bottari made it; a key copied in from one of the user's
    /// key files stays. `connect` opens a connection to a site with the
    /// secrets typed for it in front of the stored ones. Switching the site
    /// and its secrets to the key is the caller's, once this returns.
    public func install(
        _ key: NewSSHKey,
        replacing previous: NewSSHKey?,
        over provider: SFTPFileProvider?,
        typed: TypedSecrets,
        in file: String = ".ssh/authorized_keys",
        isolation: isolated (any Actor)? = #isolation,
        connect: (SavedSite, TypedSecrets) async throws -> SFTPFileProvider,
        progress: (KeySetupStep) -> Void
    ) async throws {
        progress(.installing)
        if let provider, provider.isConnected {
            try await provider.authorize(publicKey: key.publicKey, in: file)
        } else {
            let opened: SFTPFileProvider
            do {
                opened = try await connect(self, typed)
            } catch let error as SiteConnectError {
                throw KeySetupError(message: error.localizedDescription + " " + String(localized: "먼저 비밀번호로 연결한 뒤 다시 시도하십시오."))
            }
            do {
                try await opened.authorize(publicKey: key.publicKey, in: file)
            } catch {
                await opened.disconnect()
                throw error
            }
            await opened.disconnect()
        }

        progress(.checking)
        // The key alone, the way the next connection logs in: a stand-in
        // site has no saved password to fall back on.
        var probeSite = self
        probeSite.id = UUID()
        probeSite.authentication = .storedKey
        var probeSecrets = TypedSecrets()
        probeSecrets.set(key.privateKey, for: probeSite.privateKeyKey, keeping: false)
        let probe: SFTPFileProvider
        do {
            probe = try await connect(probeSite, probeSecrets)
        } catch SFTPConnectError.authenticationFailed {
            throw KeySetupError(message: String(localized: "키를 서버의 ~/.ssh/authorized_keys에 넣었지만 서버가 이 키로 로그인을 받지 않습니다. sshd 설정(PubkeyAuthentication, AuthorizedKeysFile)이나 홈 폴더 권한(그룹과 다른 사용자가 쓸 수 없어야 함)을 확인하십시오. 로그인 방식은 바꾸지 않았습니다."))
        }
        do {
            if let previous, previous.isBottariKey {
                try await probe.unauthorize(publicKey: previous.publicKey, in: file)
            }
        } catch {
            await probe.disconnect()
            throw error
        }
        await probe.disconnect()
    }
}

extension SFTPFileProvider {
    /// Adds `line` (a public key as `authorized_keys` writes it) to `file` on
    /// the server, `~/.ssh/authorized_keys` unless told otherwise, the way
    /// `ssh-copy-id` does: a new `.ssh` folder and file are private to the
    /// account, and a line already there is left alone. An account that cannot
    /// run commands gets it over SFTP, under the folder SFTP calls home.
    public func authorize(publicKey line: String, in file: String = ".ssh/authorized_keys") async throws {
        let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if canRunCommands {
            let path = file.hasPrefix("/") ? Self.quote(file) : "\"$HOME\"/" + Self.quote(file)
            let key = Self.quote(line)
            _ = try await run("""
            umask 077; f=\(path)
            mkdir -p -- "$(dirname -- "$f")" && touch -- "$f" || exit 1
            grep -qxF -- \(key) "$f" && exit 0
            if [ -s "$f" ] && [ -n "$(tail -c 1 -- "$f")" ]; then echo >> "$f"; fi
            printf '%s\\n' \(key) >> "$f"
            """)
            return
        }
        let target = file.hasPrefix("/") ? RemotePath(file) : home.appending(file)
        guard let folder = target.parent else { throw ProviderError.permissionDenied(target) }
        if (try? await stat(folder)) == nil {
            try await makeDirectory(folder)
            try? await setPermissions(0o700, at: folder)
        }
        var text = (try? await readData(target)).map { String(decoding: $0, as: UTF8.self) }
        let isNew = text == nil
        if text?.split(whereSeparator: \.isNewline).contains(where: { $0 == line }) == true { return }
        if let existing = text, !existing.isEmpty, !existing.hasSuffix("\n") { text = existing + "\n" }
        try await write(target, data: Data(((text ?? "") + line + "\n").utf8))
        if isNew { try? await setPermissions(0o600, at: target) }
    }

    /// Takes the key in `line` out of `file` (`~/.ssh/authorized_keys` unless
    /// told otherwise), matching on the key itself, so a changed comment does
    /// not hide it. Other lines, the file's permissions and a missing file are
    /// left as they are.
    public func unauthorize(publicKey line: String, in file: String = ".ssh/authorized_keys") async throws {
        let fields = line.split(separator: " ")
        guard fields.count >= 2 else { return }
        let blob = String(fields[1])
        if canRunCommands {
            let path = file.hasPrefix("/") ? Self.quote(file) : "\"$HOME\"/" + Self.quote(file)
            _ = try await run("""
            f=\(path); [ -f "$f" ] || exit 0
            t=$(mktemp) || exit 1
            grep -vF -- \(Self.quote(blob)) "$f" > "$t"
            if [ $? -le 1 ]; then cat "$t" > "$f"; s=$?; else s=1; fi
            rm -f "$t"; exit $s
            """)
            return
        }
        let target = file.hasPrefix("/") ? RemotePath(file) : home.appending(file)
        guard let data = try? await readData(target) else { return }
        let text = String(decoding: data, as: UTF8.self)
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.contains(blob) }
        guard kept.count != text.split(separator: "\n", omittingEmptySubsequences: false).count else { return }
        try await write(target, data: Data(kept.joined(separator: "\n").utf8))
    }
}
