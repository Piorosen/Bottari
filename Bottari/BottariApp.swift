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
