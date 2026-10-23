import AppKit
import SwiftUI

@main
struct BottariApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    init() {
        BundledFonts.register()
        TableRowLook.hideSeparators()
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            // Rendering snapshots lists no real folders at all.
            if !AppDelegate.isRenderingSnapshots {
                MainWindow()
                    .themed()
            }
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            FileCommands()
            if Updates.shared.isAvailable {
                CommandGroup(after: .appInfo) {
                    Button("업데이트 확인…") { Updates.shared.checkForUpdates() }
                }
            }
        }

        WindowGroup("이미지", id: "gallery", for: UUID.self) { $id in
            if let id {
                GalleryWindow(contextID: id)
                    .themed()
            }
        }
        .defaultSize(width: 1100, height: 760)

        WindowGroup("영상", id: "player", for: UUID.self) { $id in
            if let id {
                PlayerWindow(contextID: id)
                    .themed()
            }
        }
        .defaultSize(width: 1100, height: 700)

        Window("전송 센터", id: "transfers") {
            TransferCenter()
        }
        .defaultSize(width: 1280, height: 760)

        Window("터널", id: "tunnels") {
            TunnelWindow()
                .themed()
        }
        .defaultSize(width: 1000, height: 720)

        // Only once there is a tunnel to switch.
        MenuBarExtra(
            "Bottari 터널",
            systemImage: TunnelStore.shared.activeCount > 0 ? "point.3.filled.connected.trianglepath.dotted" : "point.3.connected.trianglepath.dotted",
            isInserted: Binding(get: { !AppDelegate.isRenderingSnapshots && !TunnelStore.shared.profiles.isEmpty }, set: { _ in })
        ) {
            TunnelMenu()
        }

        WindowGroup("터미널", id: "terminal", for: UUID.self) { $id in
            if let id {
                TerminalWindow(contextID: id)
                    .themed()
            }
        }
        .defaultSize(width: 1000, height: 640)

        WindowGroup("원격 화면", id: "screen", for: UUID.self) { $id in
            if let id {
                ScreenWindow(contextID: id)
                    .themed()
            }
        }
        .defaultSize(width: 1280, height: 820)

        WindowGroup("편집기", id: "editor", for: UUID.self) { $id in
            if let id {
                EditorWindow(contextID: id)
                    .themed()
            }
        }
        .defaultSize(width: 960, height: 720)

        Settings {
            SettingsView()
        }
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
            return
        }
        #endif
        ThemeStore.shared.applyAppearance()
        SettingsSync.shared.start()
        _ = Updates.shared
    }
}
