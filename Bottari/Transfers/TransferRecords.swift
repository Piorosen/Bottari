import BottariCore
import BottariSFTP
import BottariTransfer
import Foundation
import Observation

/// Transfers that had not finished when the app quit, kept in a JSON file so
/// they can carry on: files already sent are left alone, and a file cut off
/// midway continues from what reached the server.
@MainActor
@Observable
final class TransferRecords {
    /// Saved jobs not picked up again yet, oldest first.
    private(set) var interrupted: [TransferRecord] = []
    /// Why the last try to carry on with a record failed.
    private(set) var problems: [TransferRecord.ID: String] = [:]
    private(set) var resuming: Set<TransferRecord.ID> = []

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let queue: TransferQueue
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    /// Off while snapshots render, which must not touch the user's files.
    @ObservationIgnored private let saves: Bool

    init(fileURL: URL, queue: TransferQueue, saves: Bool = true) {
        self.fileURL = fileURL
        self.queue = queue
        self.saves = saves
        if saves, let data = try? Data(contentsOf: fileURL),
           let records = try? JSONDecoder().decode([TransferRecord].self, from: data) {
            interrupted = records.sorted { $0.savedAt < $1.savedAt }
        }
    }

    /// What to save `provider` as, so it can be opened again: the saved site
    /// it belongs to, or the Mac. Nil for anything else.
    static func place(for provider: any FileProvider, site: SavedSite?) -> String? {
        if let site { return "site:\(site.id.uuidString)" }
        return provider.isLocal ? "local" : nil
    }

    /// Saves soon; many files finishing at once make one write.
    func checkpoint() {
        guard saves, pendingSave == nil else { return }
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            self?.pendingSave = nil
            self?.saveNow()
        }
    }

    func saveNow() {
        guard saves else { return }
        pendingSave?.cancel()
        pendingSave = nil
        let live = queue.jobs.compactMap(\.record)
        let records = interrupted.filter { record in !live.contains { $0.id == record.id } } + live
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if records.isEmpty {
                try? FileManager.default.removeItem(at: fileURL)
            } else {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(records).write(to: fileURL, options: .atomic)
            }
        } catch {
            // Losing the record only means starting the transfer over by hand.
        }
    }

    #if DEBUG
    /// Records for snapshots, which save nothing.
    func showForPreview(_ records: [TransferRecord]) {
        interrupted = records
    }
    #endif

    func forget(_ record: TransferRecord) {
        interrupted.removeAll { $0.id == record.id }
        problems[record.id] = nil
        saveNow()
    }

    /// Opens both places again and hands the job back to the queue.
    func resume(_ record: TransferRecord) async {
        guard !resuming.contains(record.id) else { return }
        resuming.insert(record.id)
        problems[record.id] = nil
        defer { resuming.remove(record.id) }
        var opened: [any FileProvider] = []
        do {
            let source = try await endpoint(for: record.source, opened: &opened)
            let destination = try await endpoint(for: record.destination, opened: &opened)
            interrupted.removeAll { $0.id == record.id }
            await queue.resume(record, from: source, to: destination)
            saveNow()
        } catch {
            problems[record.id] = error.localizedDescription
        }
        // Closed once the job no longer needs them, or now if it never started.
        opened.forEach(AppServices.connections.adopt)
    }

    /// `opened` collects connections made just for this, as opposed to ones a
    /// pane or another job already had.
    private func endpoint(for place: TransferRecord.Place, opened: inout [any FileProvider]) async throws -> TransferEndpoint {
        if place.place == "local" {
            return TransferEndpoint(LocalFileProvider(), name: place.name, place: place.place)
        }
        guard place.place.hasPrefix("site:"), let id = UUID(uuidString: String(place.place.dropFirst(5))) else {
            throw ProviderError.io(String(localized: "알 수 없는 위치입니다: \(place.name)"))
        }
        guard let site = AppServices.sites.site(id) else {
            throw ProviderError.io(String(localized: "‘\(place.name)’ 연결이 삭제되어 이어서 보낼 수 없습니다."))
        }
        // A connection a pane or another job already has will do.
        let open = queue.jobs.lazy.flatMap { [$0.source, $0.destination] }.first { $0.place == place.place }
        if let open, (open.provider as? SFTPFileProvider)?.isConnected ?? true {
            return TransferEndpoint(open.provider, name: site.name, place: place.place)
        }
        let provider = try await AppServices.sites.connect(site)
        opened.append(provider)
        return TransferEndpoint(provider, name: site.name, place: place.place)
    }
}
