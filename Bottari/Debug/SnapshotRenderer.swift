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
                size: CGSize(width: 880, height: 1060), appearance: appearance,
                to: directory.appending(path: "sites-prod-\(name).png")
            )
            await render(
                SiteManagerSheet(library: library, initialSelection: library.sites[4].id) { (_: any FileProvider, _: SavedSite) in },
                size: CGSize(width: 880, height: 760), appearance: appearance,
                to: directory.appending(path: "sites-drive-\(name).png")
            )
            await render(
                SiteManagerSheet(library: library, initialSelection: nas.id, initialError: SiteConnectError.passwordMissing(site: nas.name)) { (_: any FileProvider, _: SavedSite) in },
                size: CGSize(width: 880, height: 640), appearance: appearance,
                to: directory.appending(path: "sites-password-\(name).png")
            )
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
        workspace.showsTransfers = true
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            await render(
                VStack(spacing: 0) {
                    TransferPanel(workspace: workspace)
                    Divider()
                    TransferBar(workspace: workspace)
                },
                size: CGSize(width: 1180, height: 430), appearance: appearance,
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
            states: [proxy.id: .on("SOCKS5 :1080 · HTTP :8118 · 시스템 프록시에 PAC 적용"), office.id: .off, gpu.id: .on("Bottari 연결이 dev-api을(를) 거쳐요")],
            connections: [proxy.id: [
                .init(id: UUID(), host: "photos.home.arpa", port: 443, kind: "SOCKS", opened: Date()),
                .init(id: UUID(), host: "192.168.0.20", port: 5000, kind: "HTTP", opened: Date()),
            ]]
        )
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            await render(TunnelWindow(), size: CGSize(width: 1100, height: 1500), appearance: appearance,
                         to: directory.appending(path: "tunnels-\(name).png"))
        }
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
