#if DEBUG
import AppKit
import AVFoundation
import BottariCore
import BottariSFTP
import BottariTransfer
import SwiftUI

/// Draws screens with sample data into PNG files without showing anything or
/// taking focus, to check the UI from the command line:
///
///     open -n -g -j -W Bottari.app --args -renderSnapshots /path/to/folder
enum SnapshotRenderer {
    static var outputDirectory: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-renderSnapshots"), arguments.indices.contains(flag + 1) else {
            return nil
        }
        return URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
    }

    static func run(into directory: URL) async {
        NSApp.setActivationPolicy(.prohibited)
        for window in NSApp.windows {
            window.close()
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let library = SiteLibrary.preview()
        let prod = library.sites[0]
        let nas = library.sites[2]
        let folder = sampleFolder()
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            await render(
                SiteManagerSheet(library: library, initialSelection: prod.id) { (_: any FileProvider, _: SavedSite) in },
                size: CGSize(width: 1100, height: 1180), appearance: appearance,
                to: directory.appending(path: "sites-prod-\(name).png")
            )
            await render(
                SiteManagerSheet(library: library, initialSelection: library.sites[4].id) { (_: any FileProvider, _: SavedSite) in },
                size: CGSize(width: 1100, height: 900), appearance: appearance,
                to: directory.appending(path: "sites-drive-\(name).png")
            )
            await render(
                SiteManagerSheet(library: library, initialSelection: nas.id, initialError: SiteConnectError.passwordMissing(site: nas.name, key: nas.passwordKey)) { (_: any FileProvider, _: SavedSite) in },
                size: CGSize(width: 1100, height: 820), appearance: appearance,
                to: directory.appending(path: "sites-password-\(name).png")
            )
            // Asked on connecting: no password saved, and keys the server refused.
            for (file, error) in [("password-missing", SiteConnectError.passwordMissing(site: nas.name, key: nas.passwordKey) as any Error),
                                  ("password-keys", SFTPConnectError.authenticationFailed)] {
                if let request = PasswordRequest(site: file == "password-keys" ? prod : nas, side: .left, error: error, typed: [:], sites: library.sites, failed: nil, then: nil) {
                    await render(
                        PasswordSheet(request: request) { _, _ in }.background(Palette.panel),
                        size: CGSize(width: 400, height: 260), appearance: appearance,
                        to: directory.appending(path: "\(file)-\(name).png")
                    )
                }
            }
            // A pane showing a PROD site; local sample files stand in for the server.
            let pane = PaneModel(provider: LocalFileProvider(), library: library)
            var site = prod
            site.startPath = folder.path
            await pane.switchProvider(to: LocalFileProvider(), site: site)
            let right = PaneModel(provider: LocalFileProvider(), start: RemotePath(folder.path), library: library)
            await right.start()
            let renamed = RemotePath(folder.path).appending("nginx.conf")
            right.selection = [renamed]
            right.renaming = renamed
            let workspace = Workspace(left: pane, right: right)
            workspace.activeSide = .right
            await render(
                HStack(spacing: 0) {
                    PaneView(workspace: workspace, side: .left)
                    Divider()
                    PaneView(workspace: workspace, side: .right)
                },
                size: CGSize(width: 1100, height: 360), appearance: appearance,
                to: directory.appending(path: "pane-prod-\(name).png")
            )
            await render(
                DeleteConfirmationSheet(
                    deletion: DeletionRequest(items: right.items, side: .left, site: prod, folder: "/var/www/site")
                ) {},
                size: CGSize(width: 460, height: 420), appearance: appearance,
                to: directory.appending(path: "delete-\(name).png")
            )
        }
        await renderTransfers(into: directory)
        await renderGallery(into: directory)
        await renderEditor(into: directory)
        await renderPlayer(into: directory)
        await checkScreen(into: directory)
        await renderTunnels(into: directory, library: library)
        await renderSidebar(into: directory, folder: folder)
        await renderMain(into: directory, library: library)
        await renderSettings(into: directory, folder: folder)
        await checkSync(into: directory)
        try? FileManager.default.removeItem(at: folder)
        exit(0)
    }

    /// The transfer bar and list with one job each: in flight between two servers,
    /// waiting on a name clash, failed, and finished.
    private static func renderTransfers(into directory: URL) async {
        let base = FileManager.default.temporaryDirectory.appending(path: "bottari-transfers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default
        for folder in ["src/site/img", "src/clash", "src/logs", "dst-server", "dst-mac", "dst-nas"] {
            try? fm.createDirectory(at: base.appending(path: folder), withIntermediateDirectories: true)
        }
        for index in 0..<40 {
            try? Data(count: 200_000).write(to: base.appending(path: "src/site/img/photo-\(index).jpg"))
        }
        try? "new".write(to: base.appending(path: "src/clash/index.html"), atomically: true, encoding: .utf8)
        try? "old".write(to: base.appending(path: "dst-mac/index.html"), atomically: true, encoding: .utf8)
        try? Data(count: 64_000).write(to: base.appending(path: "src/logs/app.log"))
        try? Data(count: 38_000_000).write(to: base.appending(path: "src/Bottari.app.zip"))

        let mac = LocalFileProvider()
        let prod = PreviewServer("prod-web", bytesPerSecond: 250_000)
        let dev = PreviewServer("dev-api")
        let nas = PreviewServer("home-nas", bytesPerSecond: .max)
        let queue = AppServices.transfers
        queue.maxConcurrentTransfers = 6
        func item(_ path: String) async -> [FileItem] {
            (try? await mac.stat(RemotePath(base.appending(path: path).path))).map { [$0] } ?? []
        }
        func folder(_ path: String) -> RemotePath { RemotePath(base.appending(path: path).path) }

        queue.enqueue(.move, await item("src/logs"), from: TransferEndpoint(dev), to: TransferEndpoint(mac), into: folder("missing"))
        let done = queue.enqueue(.copy, await item("src/Bottari.app.zip"), from: TransferEndpoint(mac), to: TransferEndpoint(nas), into: folder("dst-nas"))
        queue.enqueue(.copy, await item("src/site"), from: TransferEndpoint(prod), to: TransferEndpoint(dev), into: folder("dst-server"))
        queue.enqueue(.copy, await item("src/clash/index.html"), from: TransferEndpoint(prod), to: TransferEndpoint(mac), into: folder("dst-mac"))
        try? await Task.sleep(for: .milliseconds(1500))
        _ = done

        let workspace = Workspace()
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            await render(
                VStack(spacing: 0) {
                    TransferCenter()
                    TransferBar(workspace: workspace)
                },
                size: CGSize(width: 1440, height: 860), appearance: appearance,
                to: directory.appending(path: "transfers-\(name).png")
            )
        }
        queue.jobs.forEach(queue.cancel)
    }

    /// The image viewer on a folder of generated pictures.
    private static func renderGallery(into directory: URL) async {
        let folder = FileManager.default.temporaryDirectory.appending(path: "bottari-gallery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let colors: [(NSColor, NSColor)] = [(.systemTeal, .systemIndigo), (.systemOrange, .systemPink), (.systemGreen, .systemBlue), (.systemPurple, .systemRed), (.systemYellow, .systemOrange), (.systemMint, .systemTeal)]
        for (index, pair) in colors.enumerated() {
            let image = NSImage(size: NSSize(width: 1600, height: 1000), flipped: false) { rect in
                NSGradient(starting: pair.0, ending: pair.1)?.draw(in: rect, angle: 35)
                return true
            }
            if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: folder.appending(path: "photo-\(index + 1).png"))
            }
        }
        let local = LocalFileProvider()
        guard let items = try? await local.list(RemotePath(folder.path)), items.count > 2 else { return }
        let id = Viewers.register(ViewerContext(provider: local, site: nil, item: items[2], siblings: items))
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            await render(GalleryWindow(contextID: id), size: CGSize(width: 1000, height: 640), appearance: appearance,
                         to: directory.appending(path: "gallery-\(name).png"))
        }
    }

    /// The editor on an nginx config, and a check of the save, clash and merge flow
    /// written to editor-check.txt.
    private static func renderEditor(into directory: URL) async {
        let folder = FileManager.default.temporaryDirectory.appending(path: "bottari-editor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "nginx.conf")
        let original = "server {\n    listen 80;\n    server_name example.com;\n\n    location / {\n        root /var/www/site;\n        index index.html;\n    }\n}\n"
        try? original.write(to: file, atomically: true, encoding: .utf8)
        let local = LocalFileProvider()
        guard let item = try? await local.stat(RemotePath(file.path)) else { return }
        let context = ViewerContext(provider: local, site: nil, item: item, siblings: [item])

        let id = Viewers.register(context)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            await render(EditorWindow(contextID: id), size: CGSize(width: 820, height: 420), appearance: appearance,
                         to: directory.appending(path: "editor-\(name).png"))
        }

        var report: [String] = []
        func check(_ name: String, _ passed: Bool) { report.append((passed ? "PASS " : "FAIL ") + name) }
        let model = EditorModel(context: context)
        await model.load()
        check("loads", model.phase == .ready && model.text == original)
        model.text = model.text.replacingOccurrences(of: "listen 80;", with: "listen 8080;")
        model.markEdited()
        try? await Task.sleep(for: .seconds(1.1))
        let theirs = original.replacingOccurrences(of: "index index.html;", with: "index index.php;")
        try? theirs.write(to: file, atomically: true, encoding: .utf8)
        await model.save()
        check("notices the server changed", model.conflict != nil)
        check("offers a merge", model.conflict?.merged != nil)
        await model.saveMerged()
        let saved = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        check("keeps both edits", saved.contains("listen 8080;") && saved.contains("index index.php;"))
        check("clean afterwards", !model.isDirty && model.conflict == nil)
        model.text += "# more\n"
        model.markEdited()
        await model.save()
        check("saves again without a clash", model.conflict == nil && ((try? String(contentsOf: file, encoding: .utf8)) ?? "").hasSuffix("# more\n"))
        try? report.joined(separator: "\n").write(to: directory.appending(path: "editor-check.txt"), atomically: true, encoding: .utf8)
    }

    /// The player on a generated movie, plus player-check.txt with what mpv reported
    /// while drawing into an off-screen Metal layer.
    private static func renderPlayer(into directory: URL) async {
        let folder = FileManager.default.temporaryDirectory.appending(path: "bottari-player-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let movie = folder.appending(path: "sample.mp4")
        await makeMovie(at: movie)
        try? "1\n00:00:00,000 --> 00:00:02,000\n안녕하세요\n".write(to: folder.appending(path: "sample.srt"), atomically: true, encoding: .utf8)
        let server = PreviewServer("nas", bytesPerSecond: 50_000_000)
        guard let items = try? await server.list(RemotePath(folder.path)), let item = items.first(where: { $0.name == "sample.mp4" }) else { return }
        let context = ViewerContext(provider: server, site: nil, item: item, siblings: items)

        let model = PlayerModel(context: context)
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 640, height: 360), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
        let layer = CAMetalLayer()
        layer.drawableSize = CGSize(width: 1280, height: 720)
        host.layer = layer
        host.wantsLayer = true
        window.contentView = host
        window.orderFrontRegardless()
        model.attach(to: layer)
        try? await Task.sleep(for: .seconds(2.5))
        let state = model.state
        let lines = [
            "duration \(state.duration)",
            "position \(state.position)",
            "paused \(state.isPaused)",
            "hwdec \(state.hardwareDecoder ?? "nil")",
            "codec \(state.videoCodec ?? "nil")",
            "size \(state.videoSize.map { "\(Int($0.width))x\(Int($0.height))" } ?? "nil")",
            "tracks \(state.tracks.map { "\($0.kind.rawValue):\($0.label)\($0.isSelected ? "*" : "")" })",
            "reads \(model.reads.map(\.offset))",
            "error \(state.error ?? model.failure ?? "none")",
        ]
        try? lines.joined(separator: "\n").write(to: directory.appending(path: "player-check.txt"), atomically: true, encoding: .utf8)
        model.close()
        window.close()

        let id = Viewers.register(context)
        await render(PlayerWindow(contextID: id), size: CGSize(width: 900, height: 520), appearance: .darkAqua,
                     to: directory.appending(path: "player-dark.png"))
    }

    /// The remote screen against a tiny local VNC server: does RoyalVNC get
    /// through the handshake and hand over a framebuffer? Written to screen-check.txt.
    private static func checkScreen(into directory: URL) async {
        guard let server = try? FakeVNCServer() else { return }
        let port = await server.start()
        defer { server.stop() }
        let site = SavedSite(
            name: "test-vnc",
            endpoint: SFTPEndpoint(host: "127.0.0.1", username: "me"),
            authentication: .agent(socket: nil),
            remoteScreen: .init(kind: .vnc, port: Int(port), throughTunnel: false)
        )
        let model = ScreenModel(provider: nil, site: site, screen: site.remoteScreen!)
        await model.connect()
        let deadline = Date().addingTimeInterval(8)
        while model.framebufferView == nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let lines = [
            "connected \(model.isConnected)",
            "status \(model.status)",
            "framebuffer \(model.framebufferView.map { "\(Int($0.framebufferSize.width))x\(Int($0.framebufferSize.height))" } ?? "none")",
        ]
        try? lines.joined(separator: "\n").write(to: directory.appending(path: "screen-check.txt"), atomically: true, encoding: .utf8)
        await render(ScreenView(model: model).themed(), size: CGSize(width: 1400, height: 820), appearance: .aqua,
                     to: directory.appending(path: "screen-light.png"))
        model.disconnect()
    }

    /// The tunnel window with three sample tunnels.
    private static func renderTunnels(into directory: URL, library: SiteLibrary) async {
        let nas = library.sites[2]
        var proxy = TunnelProfile(name: "집 NAS", siteID: nas.id, mode: .proxy, routes: "192.168.0.0/16\n*.home.arpa")
        proxy.appliesSystemProxy = true
        let office = TunnelProfile(name: "사내망", siteID: library.sites[0].id, mode: .wholeMac, routes: "10.0.0.0/8\n172.16.0.0/12")
        let gpu = TunnelProfile(name: "GPU 클러스터", siteID: library.sites[1].id, mode: .bottariOnly, routes: "10.0.4.0/24")
        TunnelStore.shared.showPreview(
            [proxy, office, gpu],
            states: [proxy.id: .on("SOCKS5 :1080 · HTTP :8118 · 시스템 프록시에 PAC 적용"), office.id: .off, gpu.id: .on("Bottari 연결만 dev-api 경유")],
            connections: [proxy.id: [
                .init(id: UUID(), host: "photos.home.arpa", port: 443, kind: "SOCKS", opened: Date()),
                .init(id: UUID(), host: "192.168.0.20", port: 5000, kind: "HTTP", opened: Date()),
            ]]
        )
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            await render(TunnelWindow().themed(), size: CGSize(width: 1440, height: 1100), appearance: appearance,
                         to: directory.appending(path: "tunnels-\(name).png"))
        }
    }

    /// The whole main window as the design shows it: a PROD server on the left
    /// with nginx.conf selected, a backup folder on the right, two things in the bundle.
    private static func renderMain(into directory: URL, library: SiteLibrary) async {
        let root = FileManager.default.temporaryDirectory.appending(path: "bottari-main-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let site = root.appending(path: "site"), backup = root.appending(path: "백업")
        for folder in [site.appending(path: "assets"), site.appending(path: "releases"), backup.appending(path: "2026-10")] {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let nginx = """
        server {
            listen 443 ssl http2;
            server_name example.com;
            root /var/www/site;

            location /assets/ {
                expires 30d;
                add_header Cache-Control "public";
            }

            location / {
                try_files $uri /index.html;
            }
        }
        """
        for (name, text) in [("index.html", String(repeating: "<p>hello</p>\n", count: 300)), ("nginx.conf", nginx), ("app.env", "DATABASE_URL=postgres://…\n")] {
            try? text.write(to: site.appending(path: name), atomically: true, encoding: .utf8)
        }
        try? Data(count: 480_000).write(to: site.appending(path: "promo.mp4"))
        try? Data(count: 1_200_000).write(to: site.appending(path: "db-2026-10-21.sql.gz"))
        try? Data(count: 1_100_000).write(to: backup.appending(path: "db-2026-09-30.sql.gz"))
        try? Data(count: 840_000).write(to: backup.appending(path: "site-assets.zip"))

        var prod = library.sites[0]
        prod.startPath = site.path
        let left = PaneModel(provider: LocalFileProvider(), library: library)
        await left.switchProvider(to: PreviewServer(prod.name), site: prod)
        left.selection = [RemotePath(site.path).appending("nginx.conf")]
        let right = PaneModel(provider: LocalFileProvider(), start: RemotePath(backup.path), library: library)
        await right.start()
        let workspace = Workspace(left: left, right: right)
        let local = LocalFileProvider()
        if let items = try? await local.list(RemotePath(site.path)) {
            BottariBundle.shared.add(items.filter { $0.name == "nginx.conf" || $0.name == "index.html" }, from: local, site: nil)
        }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            // The split view's sidebar does not draw off-screen; lay the two side by side instead.
            await render(HStack(spacing: 0) {
                Sidebar(workspace: workspace).frame(width: 240)
                Rectangle().fill(Palette.line).frame(width: 1)
                MainContent(workspace: workspace)
            }.themed(), size: CGSize(width: 1440, height: 860), appearance: appearance,
                         to: directory.appending(path: "main-\(name).png"))
        }
        BottariBundle.shared.clear()
    }

    /// The sidebar with a few things in the bundle.
    private static func renderSidebar(into directory: URL, folder: URL) async {
        let local = LocalFileProvider()
        if let items = try? await local.list(RemotePath(folder.path)) {
            BottariBundle.shared.add(Array(items.prefix(3)), from: local, site: nil)
        }
        let workspace = Workspace()
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            await render(Sidebar(workspace: workspace), size: CGSize(width: 260, height: 620), appearance: appearance,
                         to: directory.appending(path: "sidebar-\(name).png"))
        }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            await render(CommandPalette(workspace: workspace) {}.padding(20), size: CGSize(width: 680, height: 520), appearance: appearance,
                         to: directory.appending(path: "palette-\(name).png"))
        }
        BottariBundle.shared.clear()
    }

    /// The settings tabs; a pane in a dark custom theme; Commander keys, and
    /// whether the menus took them (settings-check.txt). Nothing is saved:
    /// in snapshot mode the theme and keymap stay in memory.
    private static func renderSettings(into directory: URL, folder: URL) async {
        let themes = ThemeStore.shared, keymap = Keymap.shared
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            await render(GeneralSettings().padding(12).background(Palette.background).themed(), size: CGSize(width: 960, height: 560), appearance: appearance,
                         to: directory.appending(path: "settings-general-\(name).png"))
            await render(SettingsView(), size: CGSize(width: 1180, height: 780), appearance: appearance,
                         to: directory.appending(path: "settings-look-\(name).png"))
        }

        themes.choose(preset: Theme.presets[3].theme)
        themes.current.colors.accent = "#0F7C78"
        themes.current.density = .compact
        themes.current.tags["PROD"] = "#B42318"
        await render(SettingsView(), size: CGSize(width: 1180, height: 780), appearance: .darkAqua,
                     to: directory.appending(path: "settings-look-night.png"))
        let left = PaneModel(provider: LocalFileProvider(), start: RemotePath(folder.path))
        let right = PaneModel(provider: LocalFileProvider(), start: RemotePath(folder.path))
        await left.start()
        await right.start()
        left.selection = [RemotePath(folder.path).appending("nginx.conf")]
        let workspace = Workspace(left: left, right: right)
        await render(
            HStack(spacing: 0) {
                PaneView(workspace: workspace, side: .left)
                Divider()
                PaneView(workspace: workspace, side: .right)
            }
            .background(Palette.background)
            .themed(),
            size: CGSize(width: 1100, height: 300), appearance: .darkAqua,
            to: directory.appending(path: "pane-night.png")
        )
        themes.current = Theme.presets[0].theme

        var report: [String] = []
        func check(_ name: String, _ passed: Bool) { report.append((passed ? "PASS " : "FAIL ") + name) }
        keymap.layout = .commander
        keymap.set(KeyCombo("c", command: true), for: .bundle)
        await render(KeySettings().padding(12).background(Palette.background).themed(), size: CGSize(width: 960, height: 760), appearance: .aqua,
                     to: directory.appending(path: "settings-keys.png"))
        check("custom key is flagged as taken", keymap.clash(for: .bundle) == "복사 (클립보드)")
        check("F5 copies across, from the list or the menu", keymap.combo(for: .copyToOther).description == "F5" && keymap.shortcut(for: .copyToOther) != nil)
        check("Tab stays with the file list", keymap.listAction(for: KeyCombo("tab")) == .switchPane && keymap.shortcut(for: .switchPane) == nil)
        check("combos survive a round trip", KeyCombo(parsing: "⌃⌥⇧⌘F12") == KeyCombo("f12", control: true, option: true, shift: true, command: true))
        try? await Task.sleep(for: .milliseconds(300))
        let item = menuItem(titled: "반대편 패인에 복사")
        check("menu shows F5 (\(item.map { "\($0.keyEquivalent.unicodeScalars.map { String($0.value, radix: 16) }) \($0.keyEquivalentModifierMask.rawValue)" } ?? "no item"))",
              item?.keyEquivalent == "\u{F708}" && item?.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]) == [])
        keymap.layout = .finder
        try? await Task.sleep(for: .milliseconds(300))
        let finder = menuItem(titled: "반대편 패인에 복사")
        check("menu goes back to ⇧⌘C", finder?.keyEquivalent.lowercased() == "c" && finder?.keyEquivalentModifierMask.contains([.command, .shift]) == true)
        try? report.joined(separator: "\n").write(to: directory.appending(path: "settings-check.txt"), atomically: true, encoding: .utf8)
    }

    private static func menuItem(titled title: String, in menu: NSMenu? = NSApp.mainMenu) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            if item.title == title { return item }
            if let found = menuItem(titled: title, in: item.submenu) { return found }
        }
        return nil
    }

    /// Two Macs syncing through a temporary folder, with lists kept in memory:
    /// never the real iCloud Drive or the user's own lists. Renders the sync
    /// tab with a conflict and writes sync-check.txt.
    private static func checkSync(into directory: URL) async {
        let root = FileManager.default.temporaryDirectory.appending(path: "bottari-sync-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cloud = root.appending(path: "iCloud/Bottari")
        let suite = "bottari-snapshot-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        final class Box<Value> {
            var value: Value
            init(_ value: Value) { self.value = value }
        }
        func source<Value>(_ box: Box<Value>) -> SettingsSync.Source<Value> {
            .init(get: { box.value }, set: { box.value = $0 })
        }
        let devAPI = SavedSite(name: "dev-api", endpoint: SFTPEndpoint(host: "10.0.4.12", username: "deploy"), authentication: .agent(socket: nil), tag: .dev)
        let prodWeb = SavedSite(name: "prod-web", endpoint: SFTPEndpoint(host: "web.example.com", username: "deploy"), authentication: .agent(socket: nil), tag: .prod)
        let sites = Box([devAPI, prodWeb]), favorites = Box([Favorites.Favorite]()), presets = Box([BottariBundle.Preset]())
        let keys = Box(Keymap.Saved()), theme = Box(Theme.presets[1].theme), themes = Box([Theme]())
        let sync = SettingsSync(
            folder: { cloud },
            baseFolder: root.appending(path: "this-mac"),
            sources: .init(sites: source(sites), favorites: source(favorites), presets: source(presets), keymap: source(keys), theme: source(theme), themes: source(themes)),
            device: .init(id: "this-mac", name: "MacBook Pro", model: "MacBookPro18,3", lastSync: .distantPast),
            defaults: defaults
        )
        func settle() async {
            try? await Task.sleep(for: .milliseconds(50))
            while sync.isSyncing { try? await Task.sleep(for: .milliseconds(50)) }
        }
        var report: [String] = []
        func check(_ name: String, _ passed: Bool) { report.append((passed ? "PASS " : "FAIL ") + name) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        sync.setEnabled(true)
        await settle()
        check("first sync writes the lists", FileManager.default.fileExists(atPath: cloud.appending(path: "sites.json").path) && sync.errors.isEmpty)
        let written = (try? String(contentsOf: cloud.appending(path: "sites.json"), encoding: .utf8)) ?? ""
        check("no secrets in sites.json", !written.contains("password\"") && written.contains("10.0.4.12"))

        // The Mac mini changes dev-api's port, adds a site and picks Commander keys.
        var theirs = devAPI
        theirs.endpoint.port = 2222
        let staging = SavedSite(name: "staging-db", endpoint: SFTPEndpoint(host: "db.staging", username: "admin"), authentication: .password, tag: .staging)
        try? encoder.encode([theirs, prodWeb, staging]).write(to: cloud.appending(path: "sites.json"))
        try? encoder.encode(Keymap.Saved(layout: .commander)).write(to: cloud.appending(path: "keymap.json"))
        let today = Calendar.current.date(bySettingHour: 13, minute: 52, second: 0, of: .now)!
        try? encoder.encode(SettingsSync.Device(id: "mac-mini", name: "Mac mini", model: "Macmini9,1", lastSync: today))
            .write(to: cloud.appending(path: "devices/mac-mini.json"))
        // Meanwhile this Mac changes dev-api's user.
        sites.value[0].endpoint.username = "ubuntu"
        sync.syncNow()
        await settle()
        check("a site added there arrives", sites.value.map(\.name) == ["dev-api", "prod-web", "staging-db"])
        check("keys changed there arrive", keys.value.layout == .commander)
        check("dev-api is a conflict: \(sync.conflicts.first?.detail ?? "none")", sync.conflicts.count == 1 && sync.conflicts.first?.detail == "포트 · 이 Mac: 22 · Mac mini: 2222")
        check("this Mac keeps its version meanwhile", sites.value[0].endpoint.username == "ubuntu")
        check("devices list both Macs", sync.devices.map(\.name) == ["Mac mini", "MacBook Pro"])
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            await render(SyncSettings(sync: sync, height: 1200).padding(12).background(Palette.background).themed(), size: CGSize(width: 980, height: 1224), appearance: appearance,
                         to: directory.appending(path: "settings-sync-\(name).png"))
        }

        if let conflict = sync.conflicts.first {
            sync.resolve(conflict, .keepBoth)
            await settle()
        }
        let cloudSites = (try? JSONDecoder().decode([SavedSite].self, from: Data(contentsOf: cloud.appending(path: "sites.json")))) ?? []
        check("keeping both: this Mac's stays, theirs comes as a copy", sites.value.map(\.name) == ["dev-api", "prod-web", "staging-db", "dev-api (Mac mini)"]
              && sites.value[0].endpoint.username == "ubuntu" && sites.value[3].endpoint.port == 2222)
        check("and the shared file gets both", cloudSites.map(\.name) == sites.value.map(\.name) && cloudSites[0].endpoint.username == "ubuntu")
        check("no conflict left: \(sync.resolution ?? "")", sync.conflicts.isEmpty)

        try? FileManager.default.removeItem(at: cloud.appending(path: "sites.json"))
        sync.syncNow()
        await settle()
        check("a deleted file is written again", sites.value.count == 4 && FileManager.default.fileExists(atPath: cloud.appending(path: "sites.json").path))
        try? report.joined(separator: "\n").write(to: directory.appending(path: "sync-check.txt"), atomically: true, encoding: .utf8)
    }

    /// A short H.264 movie, so the player has something to open.
    private static func makeMovie(at url: URL) async {
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 360,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<90 {
            while !input.isReadyForMoreMediaData { try? await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool else { break }
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(frame * 3 % 255), CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
    }

    private static func sampleFolder() -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "bottari-snapshot-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder.appending(path: "assets"), withIntermediateDirectories: true)
        for (name, text) in [("index.html", "<h1>hi</h1>"), ("nginx.conf", "server {}"), ("docker-compose.yml", "services: {}")] {
            try? text.write(to: folder.appending(path: name), atomically: true, encoding: .utf8)
        }
        return folder
    }

    private static func render(_ view: some View, size: CGSize, appearance: NSAppearance.Name, to url: URL) async {
        // cacheDisplay draws views only, not the window behind them.
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(.windowBackground))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.contentView = host
        window.setFrameOrigin(CGPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        // Let SwiftUI lay out, run onAppear and fill its lists.
        try? await Task.sleep(for: .milliseconds(800))
        host.layoutSubtreeIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }
        window.close()
    }
}
#endif
