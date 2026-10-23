import BottariCore
import BottariSFTP
import BottariTransfer
import Foundation
import Observation

/// The bundle the app is named after: files gathered from anywhere (the Mac,
/// servers, clouds) to send somewhere together. Bundles used often are kept
/// as presets.
@Observable
final class BottariBundle {
    static let shared = BottariBundle()

    struct Entry: Identifiable {
        let id = UUID()
        let item: FileItem
        let provider: any FileProvider
        let site: SavedSite?

        var sourceName: String { site?.name ?? provider.displayName }
    }

    /// A saved bundle: where each item lives, to gather again later.
    nonisolated struct Preset: Codable, Identifiable, Hashable, Sendable {
        nonisolated struct Place: Codable, Hashable, Sendable {
            /// Nil for the Mac.
            var siteID: SavedSite.ID?
            var path: RemotePath
        }

        var id = UUID()
        var name: String
        var places: [Place]
    }

    private(set) var entries: [Entry] = []
    private(set) var presets: [Preset] = []
    @ObservationIgnored private let file = URL.applicationSupportDirectory.appending(path: "Bottari/bundles.json")

    private init() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([Preset].self, from: data) {
            presets = saved
        }
    }

    func add(_ items: [FileItem], from provider: any FileProvider, site: SavedSite?) {
        for item in items where !entries.contains(where: { $0.item.path == item.path && $0.provider.locationID == provider.locationID }) {
            entries.append(Entry(item: item, provider: provider, site: site))
        }
    }

    func remove(_ id: Entry.ID) {
        entries.removeAll { $0.id == id }
        AppServices.connections.closeUnused()
    }

    func clear() {
        entries = []
        AppServices.connections.closeUnused()
    }

    func uses(_ server: SFTPFileProvider) -> Bool {
        entries.contains { ($0.provider as? SFTPFileProvider)?.connectionID == server.connectionID }
    }

    /// Copies everything into the folder `pane` shows, one transfer per source.
    func send(to side: PaneSide, in workspace: Workspace) {
        let destination = workspace.pane(side)
        var groups: [(provider: any FileProvider, site: SavedSite?, items: [FileItem])] = []
        for entry in entries {
            if let index = groups.firstIndex(where: { Self.same($0.provider, entry.provider) }) {
                groups[index].items.append(entry.item)
            } else {
                groups.append((entry.provider, entry.site, [entry.item]))
            }
        }
        for group in groups {
            workspace.request(TransferRequest(
                kind: .copy,
                items: group.items,
                source: group.provider,
                sourceSite: group.site,
                destination: destination.provider,
                destinationSite: destination.site,
                folder: destination.path
            ))
        }
    }

    private static func same(_ a: any FileProvider, _ b: any FileProvider) -> Bool {
        if let a = a as? SFTPFileProvider, let b = b as? SFTPFileProvider { return a.connectionID == b.connectionID }
        return a.locationID == b.locationID
    }

    // MARK: - Presets

    func saveAsPreset(named name: String) {
        let places = entries.map { Preset.Place(siteID: $0.site?.id, path: $0.item.path) }
        presets.append(Preset(name: name, places: places))
        save()
    }

    func deletePreset(_ id: Preset.ID) {
        presets.removeAll { $0.id == id }
        save()
    }

    /// Gathers a preset's items again, connecting to their sites as needed.
    /// Returns what could not be found.
    func load(_ preset: Preset) async -> [String] {
        var missing: [String] = []
        var providers: [SavedSite.ID: any FileProvider] = [:]
        let local = LocalFileProvider()
        for place in preset.places {
            do {
                let provider: any FileProvider
                var site: SavedSite?
                if let id = place.siteID {
                    guard let saved = AppServices.sites.site(id) else { throw ProviderError.notFound(place.path) }
                    site = saved
                    if let open = providers[id] {
                        provider = open
                    } else {
                        provider = try await AppServices.sites.connect(saved)
                        providers[id] = provider
                    }
                } else {
                    provider = local
                }
                add([try await provider.stat(place.path)], from: provider, site: site)
            } catch {
                missing.append(place.path.name)
            }
        }
        return missing
    }

    /// The presets as another Mac left them.
    func replacePresets(with presets: [Preset]) {
        self.presets = presets
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(presets).write(to: file, options: .atomic)
        settingsChanged()
    }
}

/// Folders pinned to the sidebar, on the Mac or on a saved site.
@Observable
final class Favorites {
    static let shared = Favorites()

    nonisolated struct Favorite: Codable, Identifiable, Hashable, Sendable {
        var id = UUID()
        var name: String
        var siteID: SavedSite.ID?
        var path: RemotePath
    }

    private(set) var items: [Favorite] = []
    private let key = "sidebar.favorites"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key), let saved = try? JSONDecoder().decode([Favorite].self, from: data) {
            items = saved
        }
    }

    func add(_ path: RemotePath, site: SavedSite?) {
        guard !items.contains(where: { $0.path == path && $0.siteID == site?.id }) else { return }
        items.append(Favorite(name: path.name, siteID: site?.id, path: path))
        save()
    }

    func remove(_ id: Favorite.ID) {
        items.removeAll { $0.id == id }
        save()
    }

    /// The favorites as another Mac left them.
    func replaceAll(with items: [Favorite]) {
        self.items = items
        save()
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(items), forKey: key)
        settingsChanged()
    }
}
