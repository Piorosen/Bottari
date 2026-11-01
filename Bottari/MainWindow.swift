import BottariCore
import BottariSFTP
import SwiftUI

/// The sidebar; two panes as cards, each browsing the Mac, a server or a cloud;
/// the preview column; and the transfer strip along the bottom.
struct MainWindow: View {
    @State private var workspace: Workspace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.controlActiveState) private var activeState

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
                        .transition(.opacity)
                    CommandPalette(workspace: workspace) { workspace.showsPalette = false }
                        .padding(.top, 60)
                        .pops()
                }
            }
        }
        .motion(value: workspace.showsPalette)
        .focusedSceneValue(\.workspace, workspace)
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
        .sheet(item: $workspace.passwordRequest) { request in
            PasswordSheet(request: request, retry: { workspace.retry(request) }) { secret, keep in
                workspace.answer(request, with: secret, keeping: keep)
            }
        }
        .sheet(item: $workspace.keySetupRequest) { request in
            KeySetupSheet(request: request)
        }
        .sheet(item: $workspace.siteManager) { request in
            SiteManagerSheet(library: AppServices.sites, initialSelection: request.selection, initialError: request.error) { provider, site in
                Task { await workspace.pane(workspace.activeSide).switchProvider(to: provider, site: site) }
            }
        }
        .alert(
            String(localized: "작업을 완료할 수 없습니다"),
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
        .onChange(of: activeState, initial: true) {
            if activeState == .key { Workspace.lastActive = workspace }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openOnMac)) { notification in
            // Only the window used last, not every window that is open.
            guard Workspace.lastActive === workspace, let path = notification.object as? String else { return }
            workspace.openOnMac(RemotePath(path))
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
                // No Spacer here: a toolbar drops an item whose content can grow.
                HStack(spacing: 8) {
                    Glyph("bt.search", size: 14)
                    Text("폴더, 연결, 명령 찾기")
                }
                .frame(width: 440, alignment: .leading)
                .overlay(alignment: .trailing) {
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
                Label("SSH 터미널", glyph: "bt.terminal", size: 17)
            }
            .disabled(!(workspace.pane(workspace.activeSide).provider is SFTPFileProvider))
            .help("SSH 터미널")
            Button {
                openWindow(id: "transfers")
            } label: {
                Label(activeTransfers > 0 ? String(localized: "전송 \(activeTransfers)") : String(localized: "전송"), glyph: "bt.transfer", size: 17)
                    .labelStyle(.titleAndIcon)
            }
            .help("전송 센터")
            Button {
                workspace.siteManager = SiteManagerRequest()
            } label: {
                Label("새 연결", glyph: "bt.plus", size: 17)
            }
            .help("새 연결")
            Button {
                workspace.showsInspector.toggle()
            } label: {
                Label("미리보기", glyph: "bt.inspector", size: 17)
            }
            .help(workspace.showsInspector ? String(localized: "미리보기 닫기") : String(localized: "미리보기 열기"))
            Button {
                openSettings()
            } label: {
                Label("설정", glyph: "bt.settings", size: 17)
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
                PaneSplit(ratio: $workspace.paneRatio, swap: workspace.swapPanes) {
                    PaneView(workspace: workspace, side: .left)
                } right: {
                    PaneView(workspace: workspace, side: .right)
                }
                if workspace.showsInspector {
                    InspectorPanel(workspace: workspace)
                        .frame(width: 280)
                        .slides(from: .trailing)
                }
            }
            .motion(value: workspace.showsInspector)
            .padding(12)
            TransferBar(workspace: workspace)
        }
        .background(Palette.background)
    }
}

/// Two views side by side with a gap that drags to resize them, and shows
/// a button to swap them while the pointer is over it.
struct PaneSplit<Left: View, Right: View>: View {
    @Binding var ratio: CGFloat
    var swap: (() -> Void)?
    @ViewBuilder let left: Left
    @ViewBuilder let right: Right
    @State private var start: CGFloat?
    @State private var hoveringGap = false

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
                        hoveringGap = inside
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
                    .onTapGesture(count: 2) { withMotion { ratio = 0.5 } }
                    .overlay {
                        if let swap, hoveringGap || hoveringSwap {
                            Button(action: { withMotion { swap() } }) {
                                Image(systemName: "arrow.left.arrow.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .frame(width: 22, height: 22)
                                    .background(Palette.panel, in: .circle)
                                    .overlay(Circle().strokeBorder(Palette.line))
                                    .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                                    .contentShape(.circle)
                            }
                            .buttonStyle(.plain)
                            .onHover { hoveringSwap = $0 }
                            .help("두 패인 바꾸기 (⌥⌘U)")
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                        }
                    }
                    .motion(Motion.quick, value: hoveringGap || hoveringSwap)
                right
                    .frame(maxWidth: .infinity)
            }
        }
    }

    @State private var hoveringSwap = false
}
