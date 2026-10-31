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
        var status = String(localized: "여는 중…")
        /// The server changed its copy; uploading waits for the user.
        var blockedByServerChange = false
        /// Saved on the Mac but not on the server yet.
        var hasUnsentChanges = false

        @ObservationIgnored var remoteModified: Date?
        @ObservationIgnored var localModified: Date?
        @ObservationIgnored var folderWatcher: DispatchSourceFileSystemObject?
        @ObservationIgnored var fileWatcher: DispatchSourceFileSystemObject?
        /// The file `fileWatcher` follows; an editor that saves by renaming
        /// a new file over the old one leaves a different file at the path.
        @ObservationIgnored var watchedFile: UInt64?
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
            alert.messageText = String(localized: "‘\(site?.name ?? "")’의 파일을 외부 에디터로 열겠습니까?")
            alert.informativeText = String(localized: "외부 에디터에서 저장할 때마다 서버에 바로 업로드됩니다.")
            alert.addButton(withTitle: String(localized: "열기"))
            alert.addButton(withTitle: String(localized: "취소"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let localURL = folder.appending(path: UUID().uuidString).appending(path: item.name)
        let session = Session(item: item, provider: provider, site: site, localURL: localURL)
        sessions.append(session)
        Task { await open(session) }
    }

    /// Sessions with saves the server has not received yet.
    var unsent: [Session] {
        sessions.filter(\.hasUnsentChanges)
    }

    /// Stops watching and deletes the local copy, asking first if it holds
    /// changes the server has not received.
    func stop(_ session: Session) {
        if session.hasUnsentChanges {
            let alert = NSAlert()
            alert.messageText = String(localized: "‘\(session.item.name)’의 변경 사항이 아직 서버에 올라가지 않았습니다")
            alert.informativeText = String(localized: "그냥 중단하면 Mac에서 편집한 내용이 지워집니다.")
            alert.addButton(withTitle: String(localized: "업로드하고 중단"))
            alert.addButton(withTitle: String(localized: "취소"))
            alert.addButton(withTitle: String(localized: "버리고 중단"))
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                Task {
                    await upload(session, force: false)
                    if !session.hasUnsentChanges { finish(session) }
                }
                return
            case .alertThirdButtonReturn:
                break
            default:
                return
            }
        }
        finish(session)
    }

    private func finish(_ session: Session) {
        session.folderWatcher?.cancel()
        session.fileWatcher?.cancel()
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
            session.status = session.site?.readOnly == true ? String(localized: "읽기 전용 · 업로드 안 함") : String(localized: "편집 중 · 저장 시 업로드")
            NSWorkspace.shared.open(session.localURL)
        } catch {
            session.status = String(localized: "열 수 없음: \(error.localizedDescription)")
        }
    }

    /// Editors save one of two ways: by writing a new file and renaming it
    /// over the old one, which changes the folder, or by rewriting the file
    /// in place (VS Code, nano), which changes only the file. Both are watched.
    private func watch(_ session: Session) {
        session.folderWatcher = watcher(for: session.localURL.deletingLastPathComponent(), mask: [.write, .rename, .delete], session: session)
        watchFile(session)
    }

    private func watchFile(_ session: Session) {
        session.fileWatcher?.cancel()
        session.fileWatcher = watcher(for: session.localURL, mask: [.write, .extend, .attrib, .rename, .delete], session: session)
        session.watchedFile = fileNumber(of: session.localURL)
    }

    private func watcher(for url: URL, mask: DispatchSource.FileSystemEvent, session: Session) -> DispatchSourceFileSystemObject? {
        let descriptor = Darwin.open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: mask, queue: .main)
        source.setEventHandler { [weak self, weak session] in
            MainActor.assumeIsolated {
                guard let self, let session else { return }
                self.localFileChanged(session)
            }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        return source
    }

    private func localFileChanged(_ session: Session) {
        if let file = fileNumber(of: session.localURL), file != session.watchedFile {
            watchFile(session)
        }
        guard let modified = modificationDate(of: session.localURL), modified != session.localModified else { return }
        session.localModified = modified
        if session.site?.readOnly != true { session.hasUnsentChanges = true }
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
            session.status = String(localized: "읽기 전용 · 업로드 안 함")
            return
        }
        do {
            if !force {
                let current = try await session.provider.stat(session.item.path)
                if current.modified != session.remoteModified {
                    session.blockedByServerChange = true
                    session.status = String(localized: "서버 파일이 변경되어 업로드 보류")
                    return
                }
            }
            session.status = String(localized: "업로드 중…")
            let sending = session.localModified
            let data = try Data(contentsOf: session.localURL)
            try await session.provider.write(session.item.path, data: data)
            session.remoteModified = try? await session.provider.stat(session.item.path).modified
            // A save that landed during the upload goes up next time.
            if session.localModified == sending { session.hasUnsentChanges = false }
            session.status = String(localized: "업로드됨 \(Date().formatted(date: .omitted, time: .shortened))")
        } catch {
            session.status = String(localized: "업로드 실패: \(error.localizedDescription)")
        }
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func fileNumber(of url: URL) -> UInt64? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.systemFileNumber] as? NSNumber)?.uint64Value
    }
}
