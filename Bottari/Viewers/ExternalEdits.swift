import AppKit
import BottariCore
import BottariSFTP
import Foundation
import Observation

/// Server files opened in another app: downloaded to a private folder,
/// watched, and uploaded again each time the other app saves them.
@Observable
final class ExternalEdits {
    static let shared = ExternalEdits()

    @Observable
    final class Session: Identifiable {
        let id = UUID()
        let item: FileItem
        let provider: any FileProvider
        let site: SavedSite?
        let localURL: URL
        var status = "여는 중…"
        /// The server changed its copy; uploading waits for the user.
        var blockedByServerChange = false

        @ObservationIgnored var remoteModified: Date?
        @ObservationIgnored var localModified: Date?
        @ObservationIgnored var watcher: DispatchSourceFileSystemObject?
        @ObservationIgnored var pendingUpload: Task<Void, Never>?

        init(item: FileItem, provider: any FileProvider, site: SavedSite?, localURL: URL) {
            self.item = item
            self.provider = provider
            self.site = site
            self.localURL = localURL
        }
    }

    private(set) var sessions: [Session] = []
    private let folder = URL.cachesDirectory.appending(path: "io.github.piorosen.bottari/editing")

    func uses(_ provider: any FileProvider) -> Bool {
        guard let server = provider as? SFTPFileProvider else { return false }
        return sessions.contains { ($0.provider as? SFTPFileProvider)?.connectionID == server.connectionID }
    }

    /// Opens the file in its default app. Files on the Mac open in place; a
    /// read-only site's files open without uploading; PROD asks once first.
    func start(item: FileItem, provider: any FileProvider, site: SavedSite?) {
        if provider.isLocal {
            NSWorkspace.shared.open(URL(fileURLWithPath: item.path.string))
            return
        }
        if let existing = sessions.first(where: { $0.item.path == item.path && $0.provider.locationID == provider.locationID }) {
            NSWorkspace.shared.open(existing.localURL)
            return
        }
        if site?.confirmsWrites == true, site?.readOnly != true {
            let alert = NSAlert()
            alert.messageText = "‘\(site?.name ?? "")’의 파일을 외부 에디터로 열까요?"
            alert.informativeText = "외부 에디터에서 저장할 때마다 바로 서버에 올려요."
            alert.addButton(withTitle: "열기")
            alert.addButton(withTitle: "취소")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let localURL = folder.appending(path: UUID().uuidString).appending(path: item.name)
        let session = Session(item: item, provider: provider, site: site, localURL: localURL)
        sessions.append(session)
        Task { await open(session) }
    }

    func stop(_ session: Session) {
        session.watcher?.cancel()
        session.pendingUpload?.cancel()
        sessions.removeAll { $0 === session }
        try? FileManager.default.removeItem(at: session.localURL.deletingLastPathComponent())
        AppServices.connections.closeUnused()
    }

    /// Uploads despite the server's copy having changed.
    func uploadAnyway(_ session: Session) {
        session.blockedByServerChange = false
        Task { await upload(session, force: true) }
    }

    private func open(_ session: Session) async {
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: session.localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let current = try await session.provider.stat(session.item.path)
            let data = try await session.provider.readData(session.item.path)
            try data.write(to: session.localURL)
            session.remoteModified = current.modified
            session.localModified = modificationDate(of: session.localURL)
            watch(session)
            session.status = session.site?.readOnly == true ? "읽기 전용 · 저장해도 올리지 않아요" : "편집 중 · 저장하면 올려요"
            NSWorkspace.shared.open(session.localURL)
        } catch {
            session.status = "열지 못했어요: \(error.localizedDescription)"
        }
    }

    /// Editors often save by writing a new file and renaming it over the old
    /// one, so the folder is watched rather than the file.
    private func watch(_ session: Session) {
        let descriptor = Darwin.open(session.localURL.deletingLastPathComponent().path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self, weak session] in
            MainActor.assumeIsolated {
                guard let self, let session else { return }
                self.localFileChanged(session)
            }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        session.watcher = source
    }

    private func localFileChanged(_ session: Session) {
        guard let modified = modificationDate(of: session.localURL), modified != session.localModified else { return }
        session.localModified = modified
        // Let the editor finish writing before reading the file.
        session.pendingUpload?.cancel()
        session.pendingUpload = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await upload(session, force: false)
        }
    }

    private func upload(_ session: Session, force: Bool) async {
        guard session.site?.readOnly != true else {
            session.status = "읽기 전용이라 올리지 않았어요"
            return
        }
        do {
            if !force {
                let current = try await session.provider.stat(session.item.path)
                if current.modified != session.remoteModified {
                    session.blockedByServerChange = true
                    session.status = "서버 파일이 바뀌어서 올리지 않았어요"
                    return
                }
            }
            session.status = "올리는 중…"
            let data = try Data(contentsOf: session.localURL)
            try await session.provider.write(session.item.path, data: data)
            session.remoteModified = try? await session.provider.stat(session.item.path).modified
            session.status = "올림 \(Date().formatted(date: .omitted, time: .shortened))"
        } catch {
            session.status = "올리지 못했어요: \(error.localizedDescription)"
        }
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
