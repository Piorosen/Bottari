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
                if workspace.showsTransfers {
                    Divider()
                    TransferPanel(workspace: workspace)
                }
                Divider()
                TransferBar(workspace: workspace)
            }
        }
        .frame(minWidth: 1000, minHeight: 520)
        .toolbar {
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
        .onChange(of: hasPendingConflict) {
            // A clash needs an answer; show where to give it.
            if hasPendingConflict { workspace.showsTransfers = true }
        }
    }

    private var hasPendingConflict: Bool {
        AppServices.transfers.jobs.contains { $0.pendingConflict != nil }
    }
}
