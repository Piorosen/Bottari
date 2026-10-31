import AppKit
import BottariCore
import SwiftUI

@main
struct BottariApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    init() {
        // Folders allowed in an earlier run (App Store edition), before any pane lists one.
        FolderAccess.shared.restore()
        BundledFonts.register()
        TableRowLook.hideSeparators()
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            #if DEBUG
            if SnapshotRenderer.isShowcase {
                ShowcaseWindow()
                    .themed()
            }
            #endif
            // Rendering snapshots lists no real folders at all.
            if !AppDelegate.isRenderingSnapshots {
                MainWindow()
                    .themed()
            }
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            FileCommands()
            CommandGroup(after: .help) {
                Button("진단 정보 저장…") { Diagnostics.save() }
                Button("로그 폴더 열기") {
                    NSWorkspace.shared.open(Diagnostics.logFile.deletingLastPathComponent())
                }
            }
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
            String(localized: "Bottari 터널"),
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
    /// Snapshots or the showcase: sample data only, and nothing saved.
    static var isRenderingSnapshots: Bool {
        #if DEBUG
        SnapshotRenderer.outputDirectory != nil || SnapshotRenderer.isShowcase
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
        if SnapshotRenderer.isShowcase {
            ThemeStore.shared.applyAppearance()
            return
        }
        #endif
        Diagnostics.startLogging()
        ThemeStore.shared.applyAppearance()
        SettingsSync.shared.start()
        _ = Updates.shared
        _ = AppServices.transferRecords
    }

    /// Edits not yet on their server would be lost, so quitting asks first.
    /// Quitting mid-transfer is fine, since the transfer carries on next time,
    /// but say so first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !Self.isRenderingSnapshots else { return .terminateNow }
        let unsaved = Viewers.unsavedEditors.map(\.item.name) + ExternalEdits.shared.unsent.map(\.item.name)
        if !unsaved.isEmpty {
            let alert = NSAlert()
            alert.messageText = String(localized: "저장하지 않은 파일 \(unsaved.count)개가 있습니다")
            alert.informativeText = unsaved.sorted().joined(separator: ", ") + "\n\n" + String(localized: "지금 종료하면 이 변경 사항은 서버에 올라가지 않습니다.")
            alert.addButton(withTitle: String(localized: "취소"))
            alert.addButton(withTitle: String(localized: "저장하지 않고 종료"))
            alert.buttons[1].hasDestructiveAction = true
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        let active = AppServices.transfers.jobs.filter(\.isActive)
        if !active.isEmpty {
            let alert = NSAlert()
            alert.messageText = String(localized: "전송 \(active.count)개가 진행 중입니다")
            let resumable = active.allSatisfy { $0.record != nil }
            alert.informativeText = resumable
                ? String(localized: "지금 종료하면 다음에 Bottari를 열 때 전송 센터에서 이어서 보낼 수 있습니다.")
                : String(localized: "지금 종료하면 일부 전송은 처음부터 다시 시작해야 합니다.")
            alert.addButton(withTitle: String(localized: "종료"))
            alert.addButton(withTitle: String(localized: "취소"))
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        // A proxy setting left pointing at a tunnel that is gone would cut
        // the Mac off from the web.
        guard TunnelStore.shared.changedSystemProxy else { return .terminateNow }
        Task {
            await TunnelStore.shared.restoreSystemProxies()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !Self.isRenderingSnapshots else { return }
        AppServices.transferRecords.saveNow()
    }
}
