#if DEBUG
import AppKit
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
                SiteManagerSheet(library: library, initialSelection: prod.id) { _, _ in },
                size: CGSize(width: 880, height: 1060), appearance: appearance,
                to: directory.appending(path: "sites-prod-\(name).png")
            )
            await render(
                SiteManagerSheet(library: library, initialSelection: nas.id, initialError: SiteConnectError.passwordMissing(site: nas.name)) { _, _ in },
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
