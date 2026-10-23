import BottariCore
import BottariSFTP
import BottariTransfer
import QuickLook
import SwiftUI

/// A Finder-style list of one folder, with history buttons and a clickable path.
struct PaneView: View {
    let workspace: Workspace
    let side: PaneSide
    @Bindable var model: PaneModel

    @FocusState private var listFocused: Bool
    @AppStorage("panes.showsCloudBadges") private var showsCloudBadges = true
    @State private var siteManager: SiteManagerRequest?
    @State private var isDropTarget = false

    init(workspace: Workspace, side: PaneSide) {
        self.workspace = workspace
        self.side = side
        self.model = workspace.pane(side)
    }

    private var isActive: Bool { workspace.activeSide == side }
    private var otherPane: PaneModel { workspace.pane(side.other) }

    var body: some View {
        VStack(spacing: 0) {
            header
                .background(ThemeStore.shared.panel2 ?? .clear)
            if let message = model.errorMessage {
                ErrorBanner(message: message, dismiss: model.dismissError)
            }
            Divider()
            fileTable
            Divider()
            footer
                .background(ThemeStore.shared.panel2 ?? .clear)
        }
        .overlay(alignment: .top) {
            // A PROD pane keeps its warning band even when it is not the active one.
            Rectangle()
                .fill(isProd ? SavedSite.Tag.prod.color : isActive ? Color.themeAccent : .clear)
                .frame(height: isProd ? 3 : 2)
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.themeAccent, lineWidth: 2)
                    .background(Color.themeAccent.opacity(0.06))
                    .allowsHitTesting(false)
            }
        }
        .frame(minWidth: 360)
        .task { await model.start() }
        .onDisappear {
            Task { await model.disconnect() }
        }
        .onChange(of: listFocused) { _, focused in
            if focused { workspace.activeSide = side }
        }
        .onChange(of: workspace.focusRequest) {
            guard workspace.focusRequest == side else { return }
            listFocused = true
            workspace.focusRequest = nil
        }
        .focusedValue(\.paneFocus, PaneFocus(workspace: workspace, side: side))
        .onReceive(NotificationCenter.default.publisher(for: .transfersChanged)) { _ in
            model.refreshAfterTransfers(AppServices.transfers.jobs)
        }
        .sheet(item: $siteManager) { request in
            SiteManagerSheet(library: model.library, initialSelection: request.selection, initialError: request.error) { provider, site in
                Task { await model.switchProvider(to: provider, site: site) }
            }
        }
    }

    private var isProd: Bool { model.site?.tag == .prod }

    private func open(_ site: SavedSite) async {
        do {
            try await model.connect(to: site)
        } catch {
            // Show the site's settings with the reason, where it can be fixed.
            siteManager = SiteManagerRequest(selection: site.id, error: error)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button { Task { await model.goBack() } } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!model.canGoBack)
            .help("뒤로 (⌫)")

            Button { Task { await model.goForward() } } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!model.canGoForward)
            .help("앞으로")

            Menu {
                Button("이 Mac", systemImage: "laptopcomputer") {
                    Task { await model.switchProvider(to: LocalFileProvider()) }
                }
                let sites = model.library.sites
                if !sites.isEmpty {
                    Section("저장된 연결") {
                        ForEach(sites) { site in
                            Button {
                                Task { await open(site) }
                            } label: {
                                Label(site.tag.map { "\(site.name)  ·  \($0.label)" } ?? site.name, systemImage: site.symbol)
                            }
                        }
                    }
                }
                if model.provider is SFTPFileProvider {
                    Section("이 서버") {
                        Button("SSH 터미널 열기", systemImage: "terminal") { workspace.openTerminal(in: side) }
                        if model.site?.remoteScreen != nil {
                            Button("원격 화면 열기", systemImage: "display") { workspace.openScreen(in: side) }
                        }
                    }
                }
                Divider()
                Button("연결 관리…", systemImage: "list.bullet.rectangle") {
                    siteManager = SiteManagerRequest(selection: model.site?.id)
                }
            } label: {
                Label(model.provider.displayName, systemImage: model.isLocal ? "laptopcomputer" : "server.rack")
                    .font(.headline)
                    .foregroundStyle(isProd ? SavedSite.Tag.prod.color : .primary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("이 패인에서 열 위치")
            .padding(.leading, 4)
            .disabled(model.connectingSite != nil)

            if let site = model.site {
                if let tag = site.tag {
                    TagChip(tag: tag)
                }
                if site.readOnly {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                        .help("읽기 전용으로 열었어요")
                }
            }

            PathBar(path: model.path) { target in
                Task { await model.open(target) }
            }

            Spacer(minLength: 8)

            if let site = model.connectingSite {
                ProgressView().controlSize(.small)
                Text("\(site.name)에 연결하는 중…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if model.isLoading {
                ProgressView().controlSize(.small)
            }

            Toggle(isOn: $model.showsHiddenFiles) {
                Image(systemName: model.showsHiddenFiles ? "eye" : "eye.slash")
            }
            .toggleStyle(.button)
            .help("숨김 파일 보기")

            Button { Task { await model.reload() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("새로고침")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var fileTable: some View {
        Table(of: FileItem.self, selection: $model.selection) {
            TableColumn("이름") { item in
                HStack(spacing: 6) {
                    FileIcon.image(for: item, isLocal: model.isLocal)
                        .resizable()
                        .frame(width: 16, height: 16)
                    if model.renaming == item.id {
                        RenameField(original: item.name, isDirectory: item.isDirectory) { name in
                            Task { await model.rename(item, to: name) }
                        } cancel: {
                            model.renaming = nil
                        }
                    } else {
                        Text(item.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if showsCloudBadges, let cloud = item.cloud, cloud != .downloaded {
                            Image(systemName: cloud == .downloading ? "icloud.and.arrow.down" : "icloud")
                                .foregroundStyle(.secondary)
                                .help(cloud == .downloading ? "받는 중" : "iCloud에만 있어요 · 열면 받아요")
                        }
                    }
                }
                .padding(.vertical, ThemeStore.shared.rowPadding)
            }
            TableColumn("크기") { item in
                Text(item.formattedSize)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 80, max: 120)
            TableColumn("수정한 날짜") { item in
                Text(item.formattedModified)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 140, max: 200)
            TableColumn("권한") { item in
                Text(item.permissionString ?? "—")
                    .font(.themeMono(.caption))
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 90, max: 110)
        } rows: {
            ForEach(model.visibleItems) { item in
                TableRow(item)
                    .itemProvider { workspace.dragProvider(for: item, from: side) }
            }
        }
        .contextMenu(forSelectionType: FileItem.ID.self) { ids in
            contextMenu(for: model.items.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            guard ids.count == 1, let item = model.items.first(where: { ids.contains($0.id) }) else { return }
            workspace.open(item, in: side)
        }
        .focused($listFocused)
        // Keys the keymap gives the list (plain ones like Space, ↵ and ⇥; the rest
        // are menu shortcuts). While a name is being edited, keys belong to the text field.
        .onKeyPress(phases: .down) { press in
            guard model.renaming == nil else { return .ignored }
            let combo = KeyCombo(press)
            if let action = Keymap.shared.listAction(for: combo) {
                workspace.perform(action, in: side)
                return .handled
            }
            switch combo {
            case KeyCombo("delete"):
                Task { await model.goBack() }
                return .handled
            case KeyCombo("return"):
                // Commander layouts rename with F2; Return opens instead.
                guard model.selectedItems.count == 1, let item = model.selectedItems.first else { return .ignored }
                workspace.open(item, in: side)
                return .handled
            default:
                return .ignored
            }
        }
        .quickLookPreview($model.quickLookURL, in: model.quickLookURLs)
        // A theme's own panel colour shows through, without the system's stripes.
        .scrollContentBackground(ThemeStore.shared.panel == nil ? .automatic : .hidden)
        .alternatingRowBackgrounds(ThemeStore.shared.panel == nil ? .enabled : .disabled)
        .background(ThemeStore.shared.panel ?? .clear)
        .onDrop(of: [.utf8PlainText, .fileURL], isTargeted: $isDropTarget) { providers in
            workspace.drop(providers, onto: side)
        }
        .overlay {
            if model.visibleItems.isEmpty && !model.isLoading && model.errorMessage == nil {
                ContentUnavailableView("비어 있어요", systemImage: "folder")
            }
        }
    }

    /// Copy and move toward the other pane, the clipboard, and paste. Actions that
    /// would write to a read-only site are left out.
    @ViewBuilder
    private func contextMenu(for items: [FileItem]) -> some View {
        let readOnlyHere = model.site?.readOnly == true
        let readOnlyThere = otherPane.site?.readOnly == true
        let otherName = otherPane.provider.displayName
        if items.isEmpty {
            let count = AppServices.clipboard.content?.items.count
            if !readOnlyHere {
                Button("새 폴더") { workspace.makeFolder(in: side) }
                Divider()
                Button(count.map { "붙여넣기 (\($0)개)" } ?? "붙여넣기") { workspace.paste(into: side, kind: .copy) }
                    .disabled(count == nil)
                Button("이동해서 붙여넣기") { workspace.paste(into: side, kind: .move) }
                    .disabled(count == nil)
                Divider()
            }
            if model.provider is SFTPFileProvider {
                Divider()
                Button("여기서 터미널 열기") { workspace.openTerminal(in: side) }
                if model.site?.remoteScreen != nil {
                    Button("원격 화면 열기") { workspace.openScreen(in: side) }
                }
            }
            Divider()
            Button("새로고침") { Task { await model.reload() } }
        } else {
            if items.count == 1, let item = items.first {
                Button(item.isDirectory ? "열기" : FileKind(item) == .image ? "이미지 뷰어로 열기" : "열기") {
                    workspace.open(item, in: side)
                }
                if !item.isDirectory {
                    if FileKind(item) != .image {
                        Button("편집기로 열기") { workspace.openInEditor(item, in: side) }
                    }
                    Button("외부 에디터로 열기") {
                        ExternalEdits.shared.start(item: item, provider: model.provider, site: model.site)
                    }
                    Button("빠른 미리보기") {
                        model.selection = [item.id]
                        model.toggleQuickLook()
                    }
                }
                Divider()
            }
            if !readOnlyThere {
                Button("\(otherName)에 복사") { workspace.send(items, from: side, kind: .copy) }
                if !readOnlyHere {
                    Button("\(otherName)(으)로 이동") { workspace.send(items, from: side, kind: .move) }
                }
                Divider()
            }
            if items.count == 1, let item = items.first, !readOnlyHere {
                Button("이름 바꾸기") {
                    model.selection = [item.id]
                    workspace.beginRenaming(in: side)
                }
            }
            if model.canRunCommands, !readOnlyHere {
                Button(items.count == 1 ? "서버에서 압축 (tar.gz)" : "\(items.count)개를 서버에서 압축") {
                    Task { await model.compressOnServer(items) }
                }
                if items.count == 1, let item = items.first, PaneModel.isArchive(item) {
                    Button("서버에서 압축 풀기") { Task { await model.extractOnServer(item) } }
                }
                Divider()
            }
            Button("보따리에 담기") { workspace.addToBundle(from: side, items: items) }
            if items.count == 1, let item = items.first, item.isDirectory {
                Button("사이드바에 추가") { workspace.addFavorite(item, in: side) }
            }
            if let local = model.provider as? LocalFileProvider {
                let inCloud = items.filter { $0.cloud == .inCloud }
                let downloaded = items.filter { $0.cloud == .downloaded }
                if !inCloud.isEmpty {
                    Button("지금 다운로드") {
                        inCloud.forEach { try? local.downloadFromICloud($0.path) }
                        Task { await model.reload() }
                    }
                }
                if !downloaded.isEmpty {
                    Button("로컬 사본 제거") {
                        downloaded.forEach { try? local.removeLocalCopy($0.path) }
                        Task { await model.reload() }
                    }
                }
            }
            Divider()
            Button("복사") { AppServices.clipboard.copy(items, from: model.provider, site: model.site) }
            Button("경로 복사") {
                model.selection = Set(items.map(\.id))
                workspace.copyPaths(from: side)
            }
            if !readOnlyHere {
                Divider()
                Button(model.provider.capabilities.contains(.trash) ? "휴지통으로 이동" : "삭제…", role: .destructive) {
                    workspace.delete(items, in: side)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(model.downloadStatus ?? summary)
            Spacer()
            Text(model.remoteAddress.map { "\($0):\(model.path.string)" } ?? model.path.string)
                .font(.themeMono(.caption))
                .lineLimit(1)
                .truncationMode(.head)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private var summary: String {
        let count = "\(model.visibleItems.count)개 항목"
        let selected = model.selectedItems
        guard !selected.isEmpty else { return count }
        let bytes = selected.compactMap(\.size).reduce(0, +)
        let size = bytes > 0 ? " (\(bytes.formatted(.byteCount(style: .file))))" : ""
        return "\(count) · \(selected.count)개 선택\(size)"
    }
}

/// Clickable breadcrumbs for the current folder.
private struct PathBar: View {
    let path: RemotePath
    let open: (RemotePath) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(path.lineage, id: \.self) { crumb in
                    if !crumb.isRoot {
                        Image(systemName: "chevron.compact.right")
                            .foregroundStyle(.tertiary)
                    }
                    Button(crumb.name) { open(crumb) }
                        .buttonStyle(.plain)
                        .foregroundStyle(crumb == path ? .primary : .secondary)
                }
            }
            .font(.themeMono(.callout))
        }
        .defaultScrollAnchor(.trailing)
    }
}

private struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .lineLimit(2)
            Spacer()
            Button("닫기", action: dismiss)
                .buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.orange.opacity(0.1))
    }
}

/// Opens the connection manager, optionally on one site with why it failed to open.
private struct SiteManagerRequest: Identifiable {
    let id = UUID()
    var selection: SavedSite.ID?
    var error: (any Error)?
}

/// Edits a name in place, with the part before the extension selected like
/// Finder. Return or clicking elsewhere keeps the new name; Escape cancels.
private struct RenameField: View {
    let original: String
    let isDirectory: Bool
    let commit: (String) -> Void
    let cancel: () -> Void

    @State private var text: String
    @State private var selection: TextSelection?
    @State private var finished = false
    @FocusState private var focused: Bool

    init(original: String, isDirectory: Bool, commit: @escaping (String) -> Void, cancel: @escaping () -> Void) {
        self.original = original
        self.isDirectory = isDirectory
        self.commit = commit
        self.cancel = cancel
        _text = State(initialValue: original)
    }

    var body: some View {
        TextField("이름", text: $text, selection: $selection)
            .textFieldStyle(.plain)
            .padding(.horizontal, 2)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.themeAccent))
            .focused($focused)
            .onAppear {
                focused = true
                let ext = isDirectory ? "" : RemotePath("/" + original).pathExtension
                let end = ext.isEmpty ? text.endIndex : text.index(text.endIndex, offsetBy: -(ext.count + 1))
                selection = TextSelection(range: text.startIndex..<end)
            }
            .onSubmit { finish(keeping: true) }
            .onExitCommand { finish(keeping: false) }
            .onChange(of: focused) {
                if !focused { finish(keeping: true) }
            }
    }

    private func finish(keeping: Bool) {
        guard !finished else { return }
        finished = true
        if keeping {
            commit(text)
        } else {
            cancel()
        }
    }
}
