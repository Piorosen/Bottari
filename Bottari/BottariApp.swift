import AppKit
import SwiftUI

@main
struct BottariApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        WindowGroup {
            // Rendering snapshots lists no real folders at all.
            if !AppDelegate.isRenderingSnapshots {
                MainWindow()
            }
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            FileCommands()
        }

        WindowGroup("이미지", id: "gallery", for: UUID.self) { $id in
            if let id {
                GalleryWindow(contextID: id)
            }
        }
        .defaultSize(width: 1100, height: 760)

        WindowGroup("영상", id: "player", for: UUID.self) { $id in
            if let id {
                PlayerWindow(contextID: id)
            }
        }
        .defaultSize(width: 1100, height: 700)

        WindowGroup("터미널", id: "terminal", for: UUID.self) { $id in
            if let id {
                TerminalWindow(contextID: id)
            }
        }
        .defaultSize(width: 1000, height: 640)

        WindowGroup("원격 화면", id: "screen", for: UUID.self) { $id in
            if let id {
                ScreenWindow(contextID: id)
            }
        }
        .defaultSize(width: 1280, height: 820)

        WindowGroup("편집기", id: "editor", for: UUID.self) { $id in
            if let id {
                EditorWindow(contextID: id)
            }
        }
        .defaultSize(width: 960, height: 720)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var isRenderingSnapshots: Bool {
        #if DEBUG
        SnapshotRenderer.outputDirectory != nil
        #else
        false
        #endif
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let directory = SnapshotRenderer.outputDirectory {
            Task { await SnapshotRenderer.run(into: directory) }
        }
        #endif
    }
}
