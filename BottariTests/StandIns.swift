@testable import Bottari
import BottariCore
import BottariSFTP
import Foundation

/// A folder of its own in the temporary folder, removed by `remove()`.
struct ScratchFolder {
    let url = FileManager.default.temporaryDirectory.appending(path: "BottariTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    init() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func folder(_ name: String) throws -> URL {
        let folder = url.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Saved sites kept in this folder, secrets in memory, no ~/.ssh/config.
    func siteLibrary() -> SiteLibrary {
        SiteLibrary(
            store: SiteStore(fileURL: url.appending(path: "sites.json")),
            secrets: InMemorySecretStore(),
            loadSSHConfig: { SSHConfig(text: "", directory: "") }
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// A server, played by a folder on the Mac.
nonisolated struct StandInServer: FileProvider {
    let name: String
    let folder: URL
    private let files = LocalFileProvider()

    init(_ name: String, folder: URL) {
        self.name = name
        self.folder = folder
    }

    var displayName: String { name }
    var locationID: String { "stand-in://\(name)" }
    var capabilities: ProviderCapabilities { files.capabilities }
    var home: RemotePath { RemotePath(folder.path) }

    func list(_ path: RemotePath) async throws -> [FileItem] { try await files.list(path) }
    func stat(_ path: RemotePath) async throws -> FileItem { try await files.stat(path) }
    func read(_ path: RemotePath, range: Range<Int64>?) -> AsyncThrowingStream<Data, any Error> { files.read(path, range: range) }
    func write(_ path: RemotePath, from data: AsyncThrowingStream<Data, any Error>) async throws { try await files.write(path, from: data) }
    func makeDirectory(_ path: RemotePath) async throws { try await files.makeDirectory(path) }
    func move(_ from: RemotePath, to: RemotePath) async throws { try await files.move(from, to: to) }
    func delete(_ path: RemotePath) async throws { try await files.delete(path) }
}
