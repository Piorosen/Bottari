#if DEBUG
import AppKit
import BottariCore
import BottariSFTP
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
            await render(
                HStack(spacing: 0) {
                    PaneView(model: pane, isActive: false) {}
                    Divider()
                    PaneView(model: PaneModel(provider: LocalFileProvider(), start: RemotePath(folder.path), library: library), isActive: true) {}
                },
                size: CGSize(width: 1100, height: 360), appearance: appearance,
                to: directory.appending(path: "pane-prod-\(name).png")
            )
        }
        try? FileManager.default.removeItem(at: folder)
        exit(0)
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
