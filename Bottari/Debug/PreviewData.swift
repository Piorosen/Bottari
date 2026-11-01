#if DEBUG
import BottariCore
import BottariSFTP
import Foundation

extension SiteLibrary {
    /// The design's sample connections, saved to a temporary folder with
    /// secrets in memory, so previews never touch the real list or Keychain.
    static func preview() -> SiteLibrary {
        let library = SiteLibrary(
            store: SiteStore(fileURL: FileManager.default.temporaryDirectory.appending(path: "bottari-preview-\(UUID().uuidString)/sites.json")),
            secrets: InMemorySecretStore(),
            loadSSHConfig: {
                SSHConfig(
                    text: """
                    Host bastion
                      HostName bastion.example.com
                      User me
                    Host gpu-box
                      HostName 10.0.4.21
                      User ml
                      ProxyJump bastion
                    Host staging-web
                      HostName 10.0.2.30
                      User deploy
                      ProxyJump bastion
                    """,
                    directory: "/Users/me/.ssh",
                    home: "/Users/me",
                    localUser: "me"
                )
            }
        )
        for site in SavedSite.previews {
            library.add(site)
        }
        return library
    }
}

extension SavedSite {
    static let previews = [
        SavedSite(
            name: "prod-web",
            endpoint: SFTPEndpoint(host: "203.0.113.10", username: "deploy"),
            authentication: .defaultKeys,
            proxyJump: ["bastion"],
            tag: .prod,
            startPath: "/var/www/site"
        ),
        SavedSite(
            name: "dev-api",
            endpoint: SFTPEndpoint(host: "dev-api.internal", username: "deploy"),
            authentication: .keyFile(path: "~/.ssh/id_ed25519"),
            proxyJump: ["bastion"],
            tag: .dev,
            startPath: "~/api"
        ),
        SavedSite(
            name: "home-nas",
            endpoint: SFTPEndpoint(host: "nas.local", port: 2222, username: "admin"),
            authentication: .password,
            tag: .personal,
            startPath: "/volume1/photos"
        ),
        SavedSite(
            name: "backup-01",
            endpoint: SFTPEndpoint(host: "10.0.9.5", username: "backup"),
            authentication: .keyFile(path: "~/.ssh/backup_ed25519"),
            proxyJump: ["bastion"],
            readOnly: true
        ),
        SavedSite(
            name: "Google Drive",
            endpoint: SFTPEndpoint(host: "", username: ""),
            authentication: .password,
            tag: .personal,
            kind: .googleDrive({
                var drive = SavedSite.DriveSettings()
                drive.clientID = "1234567890-bottari.apps.googleusercontent.com"
                drive.account = "me@example.com"
                return drive
            }())
        ),
        SavedSite(
            name: "s3-assets",
            endpoint: SFTPEndpoint(host: "", username: ""),
            authentication: .password,
            kind: .s3({
                var s3 = SavedSite.S3Settings()
                s3.bucket = "bottari-assets"
                s3.region = "ap-northeast-2"
                s3.accessKey = "AKIAEXAMPLE"
                return s3
            }())
        ),
    ]
}

/// A local folder posing as a server with slow reads, so previews can show
/// transfers in flight.
struct PreviewServer: FileProvider {
    let displayName: String
    var bytesPerSecond = 1_000_000
    /// Where the server's "/" is on this Mac, so it shows server paths such as
    /// /var/www/site; nil shows the Mac's own paths.
    var root: URL?
    private let local = LocalFileProvider()

    init(_ name: String, bytesPerSecond: Int = 1_000_000, root: URL? = nil) {
        displayName = name
        self.bytesPerSecond = bytesPerSecond
        self.root = root
    }

    var locationID: String { "preview://\(displayName)" }
    var capabilities: ProviderCapabilities { [.rangeRead] }
    var home: RemotePath { root == nil ? local.home : .root }

    func list(_ path: RemotePath) async throws -> [FileItem] { try await local.list(onDisk(path)).map(shown) }
    func stat(_ path: RemotePath) async throws -> FileItem { shown(try await local.stat(onDisk(path))) }
    func write(_ path: RemotePath, from data: AsyncThrowingStream<Data, any Error>) async throws { try await local.write(onDisk(path), from: data) }
    func makeDirectory(_ path: RemotePath) async throws { try await local.makeDirectory(onDisk(path)) }
    func move(_ from: RemotePath, to: RemotePath) async throws { try await local.move(onDisk(from), to: onDisk(to)) }
    func delete(_ path: RemotePath) async throws { try await local.delete(onDisk(path)) }

    private func onDisk(_ path: RemotePath) -> RemotePath {
        guard let root else { return path }
        return path == .root ? RemotePath(root.path) : RemotePath(root.path + path.string)
    }

    /// An item as the server would list it: its path there, owned by the login.
    private func shown(_ item: FileItem) -> FileItem {
        guard let root else { return item }
        let inside = String(item.path.string.dropFirst(root.path.count))
        return FileItem(
            path: RemotePath(inside.isEmpty ? "/" : inside), kind: item.kind, isSymbolicLink: item.isSymbolicLink,
            size: item.size, modified: item.modified, permissions: item.permissions, owner: "deploy"
        )
    }

    func read(_ path: RemotePath, range: Range<Int64>?) -> AsyncThrowingStream<Data, any Error> {
        let source = Chunks(local.read(onDisk(path), range: range))
        let rate = Double(bytesPerSecond)
        return AsyncThrowingStream(unfolding: {
            guard let chunk = try await source.next() else { return nil }
            try await Task.sleep(for: .seconds(Double(chunk.count) / rate))
            return chunk
        })
    }

    /// The stream asks from one task at a time, which makes sharing the iterator safe.
    private final class Chunks: @unchecked Sendable {
        private var iterator: AsyncThrowingStream<Data, any Error>.Iterator

        init(_ stream: AsyncThrowingStream<Data, any Error>) {
            iterator = stream.makeAsyncIterator()
        }

        func next() async throws -> Data? {
            try await iterator.next()
        }
    }
}
#endif
