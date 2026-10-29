import BottariCore
import BottariSFTP
import BottariTransfer
import Foundation

/// Transfer preferences, kept in UserDefaults.
enum TransferSettings {
    static let maxConcurrentKey = "transfers.maxConcurrent"
    static let conflictPolicyKey = "transfers.conflictPolicy"
    static let verifiesChecksumsKey = "transfers.verifiesChecksums"
    static let directBetweenServersKey = "transfers.directBetweenServers"

    static var maxConcurrentTransfers: Int {
        let stored = UserDefaults.standard.integer(forKey: maxConcurrentKey)
        return stored == 0 ? 3 : stored
    }

    static var verifiesChecksums: Bool {
        UserDefaults.standard.bool(forKey: verifiesChecksumsKey)
    }

    static var conflictPolicy: ConflictPolicy {
        UserDefaults.standard.string(forKey: conflictPolicyKey).flatMap(ConflictPolicy.init) ?? .ask
    }

    /// Off unless the user turns it on: the source server borrows the login to
    /// the destination while it sends, so it should be a server the user trusts.
    static var directBetweenServers: Bool {
        UserDefaults.standard.bool(forKey: directBetweenServersKey)
    }

    /// One SFTP server sending straight to another, with the destination's
    /// login forwarded as an agent; see `SFTPFileProvider.send(_:directlyTo:into:)`.
    static let directRoute = DirectRoute(
        canSend: { from, to in
            guard let from = from as? SFTPFileProvider, let to = to as? SFTPFileProvider else { return false }
            return from.canSend(directlyTo: to)
        },
        send: { item, from, to, folder in
            guard let from = from as? SFTPFileProvider, let to = to as? SFTPFileProvider else {
                throw DirectRouteUnavailable(reason: String(localized: "SFTP 서버끼리만 직접 보낼 수 있습니다"))
            }
            do {
                try await from.send([item], directlyTo: to, into: folder)
            } catch DirectCopyError.unreachable(let reason) {
                throw DirectRouteUnavailable(reason: reason)
            }
        }
    )
}

extension ConflictPolicy {
    var label: String {
        switch self {
        case .ask: String(localized: "물어보기")
        case .overwriteIfNewer: String(localized: "더 최신이면 덮어쓰기")
        case .overwrite: String(localized: "항상 덮어쓰기")
        case .skip: String(localized: "건너뛰기")
        }
    }

    /// The end of "같은 이름의 파일은 …", for confirmations.
    var consequence: String {
        switch self {
        case .ask: String(localized: "파일마다 확인합니다")
        case .overwriteIfNewer: String(localized: "보내는 파일이 더 최신일 때만 덮어씁니다")
        case .overwrite: String(localized: "덮어씁니다")
        case .skip: String(localized: "건너뜁니다")
        }
    }
}
