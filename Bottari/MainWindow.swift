import BottariCore
import SwiftUI

/// Two panes side by side, each browsing the Mac or a server, with transfers below.
struct MainWindow: View {
    @State private var workspace = Workspace()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            Sidebar(workspace: workspace)
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 320)
        } detail: {
            VStack(spacing: 0) {
                HSplitView {
                    PaneView(workspace: workspace, side: .left)
                    PaneView(workspace: workspace, side: .right)
                }
                .background(ThemeStore.shared.background ?? .clear)
                if workspace.showsTransfers {
                    Divider()
                    TransferPanel(workspace: workspace)
                }
                Divider()
                TransferBar(workspace: workspace)
            }
        }
        .frame(minWidth: 1000, minHeight: 520)
        .overlay(alignment: .top) {
            if workspace.showsPalette {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.15)
                        .onTapGesture { workspace.showsPalette = false }
                    CommandPalette(workspace: workspace) { workspace.showsPalette = false }
                        .padding(.top, 60)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button {
                    workspace.showsPalette.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                        Text("폴더 이동, 서버 연결, 명령 실행…")
                        Text(Keymap.shared.combo(for: .palette).description)
                            .font(.themeMono(.caption))
                            .padding(.horizontal, 4)
                            .background(.quaternary, in: .rect(cornerRadius: 3))
                    }
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 320)
                }
                .keyboardShortcut(Keymap.shared.shortcut(for: .palette))
                .help("명령 팔레트 (\(Keymap.shared.combo(for: .palette)))")
            }
            ToolbarItem(placement: .primaryAction) {
                TunnelStatusButton()
            }
        }
        .sheet(item: $workspace.pendingConfirmation) { request in
            WriteConfirmationSheet(request: request) {
                workspace.confirm(request)
            }
        }
        .sheet(item: $workspace.pendingDeletion) { deletion in
            DeleteConfirmationSheet(deletion: deletion) {
                workspace.confirm(deletion)
            }
        }
        .alert(
            "할 수 없어요",
            isPresented: Binding(get: { workspace.refusal != nil }, set: { if !$0 { workspace.refusal = nil } })
        ) {
            Button("확인") {}
        } message: {
            Text(workspace.refusal ?? "")
        }
        .onAppear {
            workspace.viewerOpener = ViewerOpener { windowID, context in
                openWindow(id: windowID, value: context)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openOnMac)) { notification in
            if let path = notification.object as? String { workspace.openOnMac(RemotePath(path)) }
        }
        .onChange(of: hasPendingConflict) {
            // A clash needs an answer; show where to give it.
            if hasPendingConflict { workspace.showsTransfers = true }
        }
    }

    private var hasPendingConflict: Bool {
        AppServices.transfers.jobs.contains { $0.pendingConflict != nil }
    }
}
