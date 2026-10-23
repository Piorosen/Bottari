import BottariCore
import BottariSFTP
import SwiftUI

/// The sidebar; two panes as cards, each browsing the Mac, a server or a cloud;
/// the preview column; and the transfer strip along the bottom.
struct MainWindow: View {
    @State private var workspace: Workspace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    init(workspace: Workspace = Workspace()) {
        _workspace = State(initialValue: workspace)
    }

    var body: some View {
        NavigationSplitView {
            Sidebar(workspace: workspace)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            MainContent(workspace: workspace)
        }
        .frame(minWidth: 1100, minHeight: 560)
        .navigationTitle("Bottari")
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
        .toolbar { toolbar }
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
        .sheet(item: $workspace.siteManager) { request in
            SiteManagerSheet(library: AppServices.sites, initialSelection: request.selection, initialError: request.error) { provider, site in
                Task { await workspace.pane(workspace.activeSide).switchProvider(to: provider, site: site) }
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
            if hasPendingConflict { openWindow(id: "transfers") }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Button {
                workspace.showsPalette.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                    Text("폴더 이동, 서버 연결, 명령 실행…")
                    Spacer()
                    Text(Keymap.shared.combo(for: .palette).description)
                        .font(.themeMono(.caption2))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.line))
                }
                .font(.ui(.callout))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(width: 460)
                .background(Palette.panel, in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(Keymap.shared.shortcut(for: .palette))
            .help("명령 팔레트 (\(Keymap.shared.combo(for: .palette).description))")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            TunnelStatusButton()
            Button {
                workspace.openTerminal(in: workspace.activeSide)
            } label: {
                Label("SSH 터미널", systemImage: "terminal")
            }
            .disabled(!(workspace.pane(workspace.activeSide).provider is SFTPFileProvider))
            .help("지금 패인의 서버에서 SSH 터미널 열기")
            Button {
                openWindow(id: "transfers")
            } label: {
                Label(activeTransfers > 0 ? "전송 \(activeTransfers)" : "전송", systemImage: "arrow.up.arrow.down")
                    .labelStyle(.titleAndIcon)
            }
            .help("전송 센터")
            Button {
                workspace.siteManager = SiteManagerRequest()
            } label: {
                Label("새 연결", systemImage: "plus")
            }
            .help("새 연결 추가")
            Button {
                workspace.showsInspector.toggle()
            } label: {
                Label("미리보기", systemImage: "sidebar.right")
            }
            .help(workspace.showsInspector ? "미리보기 닫기" : "미리보기 열기")
            Button {
                openSettings()
            } label: {
                Label("설정", systemImage: "slider.horizontal.3")
            }
            .help("설정 (⌘,)")
        }
    }

    private var activeTransfers: Int {
        AppServices.transfers.jobs.filter(\.isActive).count
    }

    private var hasPendingConflict: Bool {
        AppServices.transfers.jobs.contains { $0.pendingConflict != nil }
    }
}

/// Right of the sidebar: the panes, the preview column and the transfer strip.
struct MainContent: View {
    @Bindable var workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                PaneSplit(ratio: $workspace.paneRatio) {
                    PaneView(workspace: workspace, side: .left)
                } right: {
                    PaneView(workspace: workspace, side: .right)
                }
                if workspace.showsInspector {
                    InspectorPanel(workspace: workspace)
                        .frame(width: 280)
                }
            }
            .padding(12)
            TransferBar(workspace: workspace)
        }
        .background(Palette.background)
    }
}

/// Two views side by side with a gap that drags to resize them.
struct PaneSplit<Left: View, Right: View>: View {
    @Binding var ratio: CGFloat
    @ViewBuilder let left: Left
    @ViewBuilder let right: Right
    @State private var start: CGFloat?

    private let gap: CGFloat = 12

    var body: some View {
        GeometryReader { geometry in
            let width = max(0, geometry.size.width - gap)
            HStack(spacing: 0) {
                left
                    .frame(width: width * ratio)
                Color.clear
                    .frame(width: gap)
                    .contentShape(.rect)
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { drag in
                                let base = start ?? ratio
                                start = base
                                ratio = min(0.75, max(0.25, base + drag.translation.width / max(width, 1)))
                            }
                            .onEnded { _ in start = nil }
                    )
                    .onTapGesture(count: 2) { ratio = 0.5 }
                right
                    .frame(maxWidth: .infinity)
            }
        }
    }
}
