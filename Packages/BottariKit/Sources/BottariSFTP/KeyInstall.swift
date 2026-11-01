import BottariCore
import Foundation

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
