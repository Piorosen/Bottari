import AppKit
import BottariCore
import BottariSFTP
import Observation
import SystemConfiguration

/// Settings shared between the user's Macs as JSON files in
/// `iCloud Drive/Bottari/`. Off until turned on. Secrets never go there: they
/// stay in the Keychain.
@Observable
final class SettingsSync {
    static let shared = SettingsSync(
        folder: { LocalFileProvider.iCloudDrive.map { URL(filePath: $0.string).appending(path: "Bottari", directoryHint: .isDirectory) } },
        baseFolder: URL.applicationSupportDirectory.appending(path: "Bottari/sync-base", directoryHint: .isDirectory),
        sources: .app,
        device: .thisMac,
        defaults: .standard
    )

    enum Item: String, CaseIterable, Identifiable, Sendable {
        case sites, favorites, themes, keymap, presets

        var id: Self { self }

        var title: String {
            switch self {
            case .sites: String(localized: "연결 목록")
            case .favorites: String(localized: "사이드바 즐겨찾기")
            case .themes: String(localized: "테마")
            case .keymap: String(localized: "단축키")
            case .presets: String(localized: "보따리 프리셋")
            }
        }

        /// With its subject particle: "연결 목록이", "테마가".
        var subject: String {
            switch self {
            case .sites: String(localized: "연결 목록이")
            case .favorites: String(localized: "사이드바 즐겨찾기가")
            case .themes: String(localized: "테마가")
            case .keymap: String(localized: "단축키가")
            case .presets: String(localized: "보따리 프리셋이")
            }
        }

        var subtitle: String {
            switch self {
            case .sites: String(localized: "서버 주소, 사용자, 태그, 점프 호스트 (비밀번호 제외)")
            case .favorites: String(localized: "사이드바에 추가한 폴더")
            case .themes: String(localized: "사용 중인 테마와 저장된 테마")
            case .keymap: String(localized: "선택한 배열과 사용자 지정 키")
            case .presets: String(localized: "자주 쓰는 파일 묶음")
            }
        }

        /// What it is called in the shared folder.
        var files: [String] {
            switch self {
            case .sites: ["sites.json"]
            case .favorites: ["favorites.json"]
            case .themes: ["theme.json", "themes/"]
            case .keymap: ["keymap.json"]
            case .presets: ["bottari-presets.json"]
            }
        }
    }

    /// A Mac that syncs here, as it last wrote in `devices/`.
    nonisolated struct Device: Codable, Identifiable, Hashable, Sendable {
        var id: String
        var name: String
        /// "MacBookPro18,3", "Mac14,3": tells a laptop from a desktop.
        var model: String
        var lastSync: Date

        var isLaptop: Bool { model.contains("Book") }

        static var thisMac: Device {
            let key = "sync.deviceID"
            let id = UserDefaults.standard.string(forKey: key) ?? {
                let id = UUID().uuidString
                UserDefaults.standard.set(id, forKey: key)
                return id
            }()
            let name = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? String(localized: "이 Mac")
            var size = 0
            sysctlbyname("hw.model", nil, &size, nil, 0)
            var model = [UInt8](repeating: 0, count: max(size, 1))
            sysctlbyname("hw.model", &model, &size, nil, 0)
            return Device(id: id, name: name, model: String(decoding: model.prefix { $0 != 0 }, as: UTF8.self), lastSync: .distantPast)
        }
    }

    /// Two Macs changed the same thing differently since they last agreed.
    struct Conflict: Identifiable {
        enum Choice {
            case keepMine, useTheirs, keepBoth
        }

        let id: String
        let item: Item
        /// "dev-api"
        let title: String
        /// "포트 · 이 Mac: 22 · Mac mini: 2222"
        let detail: String
        let canKeepBoth: Bool
        fileprivate let resolve: (Choice) -> String
    }

    /// Where each synced thing lives on this Mac.
    struct Sources {
        var sites: Source<[SavedSite]>
        var favorites: Source<[Favorites.Favorite]>
        var presets: Source<[BottariBundle.Preset]>
        var keymap: Source<Keymap.Saved>
        var theme: Source<Theme>
        var themes: Source<[Theme]>
    }

    struct Source<Value> {
        let get: () -> Value
        let set: (Value) -> Void
    }

    private(set) var isEnabled: Bool
    private(set) var items: Set<Item>
    private(set) var isSyncing = false
    private(set) var lastSync: Date?
    private(set) var errors: [String] = []
    private(set) var conflicts: [Conflict] = []
    /// Other Macs first seen in `devices/`, most recent first; this one last.
    private(set) var devices: [Device] = []
    /// What the last answer to a conflict did.
    private(set) var resolution: String?

    @ObservationIgnored private let folderURL: () -> URL?
    @ObservationIgnored private let baseFolder: URL
    @ObservationIgnored private let sources: Sources
    @ObservationIgnored private let device: Device
    @ObservationIgnored private let defaults: UserDefaults
    /// Set while synced data is being put in place, so that is not taken for a local change.
    @ObservationIgnored private var isApplying = false
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var syncAgain = false

    init(folder: @escaping () -> URL?, baseFolder: URL, sources: Sources, device: Device, defaults: UserDefaults) {
        self.folderURL = folder
        self.baseFolder = baseFolder
        self.sources = sources
        self.device = device
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: "sync.enabled")
        let off = Set(defaults.stringArray(forKey: "sync.off") ?? [])
        items = Set(Item.allCases.filter { !off.contains($0.rawValue) })
        lastSync = defaults.object(forKey: "sync.last") as? Date
    }

    var folder: URL? { folderURL() }

    var otherMacName: String {
        devices.first { $0.id != device.id }?.name ?? String(localized: "다른 Mac")
    }

    /// Starts watching for changes: on this Mac, when the app comes back to the
    /// front, and every few minutes.
    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .settingsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.localChange() }
        })
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncNow() }
        })
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncNow() }
        }
        syncNow()
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: "sync.enabled")
        if enabled {
            syncNow()
        } else {
            conflicts = []
            errors = []
        }
    }

    func set(_ item: Item, on: Bool) {
        if on { items.insert(item) } else { items.remove(item) }
        defaults.set(Item.allCases.filter { !items.contains($0) }.map(\.rawValue), forKey: "sync.off")
        if on { syncNow() } else { conflicts.removeAll { $0.item == item } }
    }

    private func localChange() {
        guard isEnabled, !isApplying else { return }
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { syncNow() }
        }
    }

    // MARK: - Syncing

    private struct Snapshot: Sendable {
        var items: Set<Item>
        var sites: [SavedSite]
        var favorites: [Favorites.Favorite]
        var presets: [BottariBundle.Preset]
        var keymap: Keymap.Saved
        var theme: Theme
        var themes: [Theme]
        var device: Device
    }

    private struct Outcome: Sendable {
        var sites: SyncFolder.Outcome<SavedSite>?
        var favorites: SyncFolder.Outcome<Favorites.Favorite>?
        var presets: SyncFolder.Outcome<BottariBundle.Preset>?
        var keymap: (value: Keymap.Saved, conflict: (local: Keymap.Saved, remote: Keymap.Saved)?)?
        var theme: (value: Theme, conflict: (local: Theme, remote: Theme)?)?
        var themes: SyncFolder.Outcome<Theme>?
        var devices: [Device] = []
        var errors: [String] = []
    }

    /// Merges with the shared folder now, unless a sync is already running
    /// (then once more after it).
    func syncNow() {
        guard isEnabled else { return }
        guard let folder = folderURL() else {
            errors = [String(localized: "iCloud Drive가 꺼져 있습니다. 시스템 설정 › Apple 계정 › iCloud에서 iCloud Drive를 켜십시오.")]
            return
        }
        guard !isSyncing else {
            syncAgain = true
            return
        }
        isSyncing = true
        let snapshot = Snapshot(
            items: items, sites: sources.sites.get(), favorites: sources.favorites.get(), presets: sources.presets.get(),
            keymap: sources.keymap.get(), theme: sources.theme.get(), themes: sources.themes.get(), device: device
        )
        let shared = SyncFolder(folder: folder, baseFolder: baseFolder)
        Task {
            let outcome = await Task.detached { Self.run(shared, snapshot) }.value
            apply(outcome, mergedFrom: snapshot)
            isSyncing = false
            if syncAgain {
                syncAgain = false
                syncNow()
            }
        }
    }

    /// Off the main thread: iCloud Drive may have to download a file first.
    nonisolated private static func run(_ folder: SyncFolder, _ local: Snapshot) -> Outcome {
        var outcome = Outcome()
        func attempt(_ body: () throws -> Void) {
            do { try body() } catch { outcome.errors.append(error.localizedDescription) }
        }
        if local.items.contains(.sites) { attempt { outcome.sites = try folder.sync("sites.json", local: local.sites) } }
        if local.items.contains(.favorites) { attempt { outcome.favorites = try folder.sync("favorites.json", local: local.favorites) } }
        if local.items.contains(.presets) { attempt { outcome.presets = try folder.sync("bottari-presets.json", local: local.presets) } }
        if local.items.contains(.keymap) { attempt { outcome.keymap = try folder.sync("keymap.json", value: local.keymap) } }
        if local.items.contains(.themes) {
            attempt { outcome.theme = try folder.sync("theme.json", value: local.theme) }
            attempt { outcome.themes = try folder.sync(directory: "themes", local: local.themes) }
        }
        attempt { outcome.devices = try register(local.device, in: folder.folder) }
        return outcome
    }

    /// Writes this Mac into `devices/` and reads the others.
    nonisolated private static func register(_ device: Device, in folder: URL) throws -> [Device] {
        let directory = folder.appending(path: "devices", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var me = device
        me.lastSync = .now
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(me).write(to: directory.appending(path: "\(device.id).json"), options: .atomic)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let others = (try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles))
            .compactMap { try? decoder.decode(Device.self, from: Data(contentsOf: $0)) }
            .filter { $0.id != device.id }
            .sorted { $0.lastSync > $1.lastSync }
        return others + [me]
    }

    /// Puts the merged settings in place. Anything edited here while the merge
    /// ran (typing a host name, say) is left as it now is and merged again
    /// right after, rather than swapped for the older copy the merge started from.
    private func apply(_ outcome: Outcome, mergedFrom snapshot: Snapshot) {
        isApplying = true
        defer { isApplying = false }
        devices = outcome.devices
        errors = outcome.errors
        var found: [Conflict] = []
        let editedMeanwhile = sources.sites.get() != snapshot.sites || sources.favorites.get() != snapshot.favorites
            || sources.presets.get() != snapshot.presets || sources.keymap.get() != snapshot.keymap
            || sources.theme.get() != snapshot.theme || sources.themes.get() != snapshot.themes
        if editedMeanwhile {
            syncAgain = true
            return
        }

        if let sites = outcome.sites {
            if sites.items != sources.sites.get() { sources.sites.set(sites.items) }
            found += sites.conflicts.map { listConflict($0, item: .sites, file: "sites.json", source: sources.sites, title: \.name, detail: Self.siteDifference, copy: Self.copy) }
        }
        if let favorites = outcome.favorites {
            if favorites.items != sources.favorites.get() { sources.favorites.set(favorites.items) }
            found += favorites.conflicts.map { listConflict($0, item: .favorites, file: "favorites.json", source: sources.favorites, title: \.name, detail: { _, _, _ in String(localized: "위치가 다름") }, copy: { var c = $0; c.id = UUID(); c.name += " (\($1))"; return c }) }
        }
        if let presets = outcome.presets {
            if presets.items != sources.presets.get() { sources.presets.set(presets.items) }
            found += presets.conflicts.map { listConflict($0, item: .presets, file: "bottari-presets.json", source: sources.presets, title: \.name, detail: { _, _, _ in String(localized: "담긴 항목이 다름") }, copy: { var c = $0; c.id = UUID(); c.name += " (\($1))"; return c }) }
        }
        if let keymap = outcome.keymap {
            if keymap.value != sources.keymap.get() { sources.keymap.set(keymap.value) }
            if let conflict = keymap.conflict {
                found.append(valueConflict(conflict, item: .keymap, file: "keymap.json", source: sources.keymap, title: String(localized: "단축키"), detail: "\(conflict.local.layout.title) · \(conflict.remote.layout.title)"))
            }
        }
        if let theme = outcome.theme {
            if theme.value != sources.theme.get() { sources.theme.set(theme.value) }
            if let conflict = theme.conflict {
                found.append(valueConflict(conflict, item: .themes, file: "theme.json", source: sources.theme, title: String(localized: "사용 중인 테마"), detail: String(localized: "이 Mac: \(conflict.local.name) · \(otherMacName): \(conflict.remote.name)")))
            }
        }
        if let themes = outcome.themes {
            if themes.items != sources.themes.get() { sources.themes.set(themes.items) }
            found += themes.conflicts.map { listConflict($0, item: .themes, file: "themes.json", source: sources.themes, title: \.name, detail: { _, _, _ in String(localized: "색 또는 글꼴이 다름") }, copy: { var c = $0; c.name += " (\($1))"; return c }) }
        }
        conflicts = found
        if outcome.errors.isEmpty {
            lastSync = .now
            defaults.set(lastSync, forKey: "sync.last")
        }
    }

    /// Answers a conflict, then syncs so the other Macs get the answer.
    func resolve(_ conflict: Conflict, _ choice: Conflict.Choice) {
        isApplying = true
        resolution = conflict.resolve(choice)
        isApplying = false
        conflicts.removeAll { $0.id == conflict.id }
        syncNow()
    }

    // MARK: - Conflicts

    /// Answers work through the agreed state: agreeing on the other Mac's
    /// version makes this Mac's the one change, and the next sync settles it.
    private func listConflict<Item: Codable & Identifiable & Equatable>(
        _ conflict: ThreeWaySync.Conflict<Item>,
        item: SettingsSync.Item,
        file: String,
        source: Source<[Item]>,
        title: KeyPath<Item, String>,
        detail: @escaping (_ mine: Item, _ theirs: Item, _ otherMac: String) -> String,
        copy: @escaping (Item, _ otherMac: String) -> Item
    ) -> Conflict {
        let other = otherMacName
        let baseFolder = baseFolder
        let mine = conflict.local, theirs = conflict.remote
        let name = (mine ?? theirs)![keyPath: title]
        let description = switch (mine, theirs) {
        case (let mine?, let theirs?): detail(mine, theirs, other)
        case (nil, _): String(localized: "이 Mac에서 삭제됨, \(other)에서 수정됨")
        case (_, nil): String(localized: "이 Mac에서 수정됨, \(other)에서 삭제됨")
        }
        return Conflict(id: "\(item.rawValue)-\(conflict.id)", item: item, title: name, detail: description, canKeepBoth: mine != nil && theirs != nil) { choice in
            // Only the agreed state is touched here.
            let shared = SyncFolder(folder: baseFolder, baseFolder: baseFolder)
            var base: [Item] = shared.base(file)
            base.put(theirs, for: conflict.id)
            try? shared.setBase(file, base)
            var list = source.get()
            switch choice {
            case .keepMine:
                return String(localized: "이 Mac의 “\(name)” 유지, \(other)에도 반영")
            case .useTheirs:
                list.put(theirs, for: conflict.id)
                source.set(list)
                return theirs == nil ? String(localized: "\(other)에 맞춰 “\(name)” 삭제됨") : String(localized: "\(other)의 “\(name)” 적용됨")
            case .keepBoth:
                if let theirs {
                    let duplicate = copy(theirs, other)
                    list.append(duplicate)
                    source.set(list)
                    return String(localized: "사본 “\(duplicate[keyPath: title])” 생성됨")
                }
                return ""
            }
        }
    }

    private func valueConflict<Value: Codable & Equatable>(
        _ conflict: (local: Value, remote: Value),
        item: SettingsSync.Item,
        file: String,
        source: Source<Value>,
        title: String,
        detail: String
    ) -> Conflict {
        let other = otherMacName
        let baseFolder = baseFolder
        return Conflict(id: item.rawValue + file, item: item, title: title, detail: detail, canKeepBoth: false) { choice in
            try? SyncFolder(folder: baseFolder, baseFolder: baseFolder).setBase(file, value: conflict.remote)
            if choice == .useTheirs {
                source.set(conflict.remote)
                return String(localized: "\(other)의 \(title) 적용됨")
            }
            return String(localized: "이 Mac의 \(title) 유지, \(other)에도 반영")
        }
    }

    /// "포트 · 이 Mac: 22 · Mac mini: 2222"
    private static func siteDifference(_ mine: SavedSite, _ theirs: SavedSite, otherMac other: String) -> String {
        let fields: [(String, String, String)] = [
            (String(localized: "이름"), mine.name, theirs.name),
            (String(localized: "주소"), mine.endpoint.host, theirs.endpoint.host),
            (String(localized: "포트"), String(mine.endpoint.port), String(theirs.endpoint.port)),
            (String(localized: "사용자"), mine.endpoint.username, theirs.endpoint.username),
            (String(localized: "태그"), mine.tag?.label ?? String(localized: "없음"), theirs.tag?.label ?? String(localized: "없음")),
            (String(localized: "점프 호스트"), mine.proxyJump.joined(separator: ", "), theirs.proxyJump.joined(separator: ", ")),
            (String(localized: "시작 폴더"), mine.startPath ?? "", theirs.startPath ?? ""),
        ]
        guard let (label, here, there) = fields.first(where: { $0.1 != $0.2 }) else { return String(localized: "기타 설정이 다름") }
        return String(localized: "\(label) · 이 Mac: \(here.isEmpty ? String(localized: "없음") : here) · \(other): \(there.isEmpty ? String(localized: "없음") : there)")
    }

    private static func copy(_ site: SavedSite, otherMac: String) -> SavedSite {
        var copy = site
        copy.id = UUID()
        copy.name += " (\(otherMac))"
        copy.sshConfigAlias = nil
        return copy
    }
}

extension SettingsSync.Sources {
    /// The app's own stores.
    static var app: Self {
        Self(
            sites: .init(get: { AppServices.sites.sites }, set: { AppServices.sites.replaceAll(with: $0) }),
            favorites: .init(get: { Favorites.shared.items }, set: { Favorites.shared.replaceAll(with: $0) }),
            presets: .init(get: { BottariBundle.shared.presets }, set: { BottariBundle.shared.replacePresets(with: $0) }),
            keymap: .init(get: { Keymap.shared.saved }, set: { Keymap.shared.replace(with: $0) }),
            theme: .init(get: { ThemeStore.shared.current }, set: { ThemeStore.shared.current = $0 }),
            themes: .init(get: { ThemeStore.shared.saved }, set: { ThemeStore.shared.replaceSaved(with: $0) })
        )
    }
}

private extension Array where Element: Identifiable {
    /// Replaces the element with `id`, appends it, or removes it for nil.
    mutating func put(_ element: Element?, for id: Element.ID) {
        if let index = firstIndex(where: { $0.id == id }) {
            if let element { self[index] = element } else { remove(at: index) }
        } else if let element {
            append(element)
        }
    }
}
