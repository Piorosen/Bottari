import BottariCore
import BottariSFTP
import BottariTransfer
import QuickLook
import SwiftUI

/// One folder in a card: history, the place's name and tag, a clickable path,
/// and the files as a list or a grid.
struct PaneView: View {
    let workspace: Workspace
    let side: PaneSide
    @Bindable var model: PaneModel

    @FocusState private var listFocused: Bool
    @AppStorage("panes.showsCloudBadges") private var showsCloudBadges = true
    @State private var siteManager: SiteManagerRequest?
    @State private var isDropTarget = false
    @State private var permissions: PermissionsRequest?

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
            if let message = model.errorMessage {
                ErrorBanner(message: message, dismiss: model.dismissError)
            }
            Group {
                switch model.viewMode {
                case .list: fileTable
                case .grid: fileGrid
                }
            }
            .onDrop(of: [.utf8PlainText, .fileURL], isTargeted: $isDropTarget) { providers in
                workspace.drop(providers, onto: side)
            }
            .overlay {
                if model.showsSearchResults {
                    if model.shownItems.isEmpty && !model.isSearching {
                        ContentUnavailableView("찾은 항목 없음", systemImage: "magnifyingglass")
                    }
                } else if model.visibleItems.isEmpty && !model.isLoading && model.errorMessage == nil {
                    ContentUnavailableView("빈 폴더", systemImage: "folder")
                }
            }
            Rectangle().fill(Palette.line).frame(height: 1)
            footer
        }
        .overlay(alignment: .top) {
            // A PROD pane keeps its warning band even when it is not the active one.
            if isProd {
                Rectangle()
                    .fill(SavedSite.Tag.prod.color)
                    .frame(height: 3)
            }
        }
        .card(highlighted: isActive)
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.themeAccent, lineWidth: 2)
                    .background(Color.themeAccent.opacity(0.06), in: .rect(cornerRadius: 10))
                    .allowsHitTesting(false)
            }
        }
        .frame(minWidth: 340)
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
        .sheet(item: $permissions) { request in
            PermissionsSheet(items: request.items) { mode, scope in
                Task { await model.setPermissions(mode, on: request.items, scope: scope) }
            }
        }
        .onChange(of: workspace.searchRequest) {
            guard workspace.searchRequest == side else { return }
            model.beginSearch()
            workspace.searchRequest = nil
        }
    }

    private var isProd: Bool { model.site?.tag == .prod }

    private func open(_ site: SavedSite) {
        workspace.connect(site, in: side, failed: { error in
            // Show the site's settings with the reason, where it can be fixed.
            siteManager = SiteManagerRequest(selection: site.id, error: error)
        })
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    Button { Task { await model.goBack() } } label: {
                        Image(systemName: "chevron.left").frame(width: 20, height: 20)
                    }
                    .disabled(!model.canGoBack)
                    .iconHelp(String(localized: "뒤로 (⌫)"))
                    Button { Task { await model.goForward() } } label: {
                        Image(systemName: "chevron.right").frame(width: 20, height: 20)
                    }
                    .disabled(!model.canGoForward)
                    .iconHelp(String(localized: "앞으로"))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)

                placeMenu

                if let site = model.site {
                    if let tag = site.tag {
                        if tag == .prod { TagChip(tag: tag) } else { TagChip.outlined(tag) }
                    }
                    if site.readOnly {
                        Image(systemName: "lock.fill")
                            .font(.ui(.caption))
                            .foregroundStyle(.secondary)
                            .help("읽기 전용")
                    }
                }
                Text(model.provider.kindLabel)
                    .font(.themeMono(.caption))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 6)

                if let site = model.connectingSite {
                    ProgressView().controlSize(.small)
                    Text("\(site.name)에 연결하는 중…")
                        .font(.ui(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if model.isLoading {
                    ProgressView().controlSize(.small)
                }
                tools
            }
            PathBar(path: model.path) { target in
                Task { await model.open(target) }
            }
            .padding(.leading, 4)
            if model.searchQuery != nil {
                SearchField(model: model) { listFocused = true }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    /// The place's name, which is also where another place is chosen.
    private var placeMenu: some View {
        Menu {
            Button {
                Task { await model.switchProvider(to: LocalFileProvider()) }
            } label: {
                Label("이 Mac", glyph: "bt.mac")
            }
            let sites = model.library.sites
            if !sites.isEmpty {
                Section("저장된 연결") {
                    ForEach(sites) { site in
                        Button {
                            open(site)
                        } label: {
                            Label(site.tag.map { "\(site.name)  ·  \($0.label)" } ?? site.name, glyph: site.symbol)
                        }
                    }
                }
            }
            Divider()
            Button("연결 관리…", systemImage: "list.bullet.rectangle") {
                siteManager = SiteManagerRequest(selection: model.site?.id)
            }
        } label: {
            HStack(spacing: 6) {
                Glyph(model.provider.symbol, size: 16)
                    .foregroundStyle(isProd ? SavedSite.Tag.prod.color : .secondary)
                Text(model.provider.displayName)
                    .font(.ui(.body, weight: .semibold))
                    .foregroundStyle(isProd ? SavedSite.Tag.prod.color : Palette.text)
                    .lineLimit(1)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("위치 선택")
        .disabled(model.connectingSite != nil)
    }

    private var tools: some View {
        HStack(spacing: 6) {
            if model.provider is SFTPFileProvider {
                Button { workspace.openTerminal(in: side) } label: { Glyph("bt.terminal", size: 15) }
                    .iconHelp(String(localized: "SSH 터미널 (⌃`)"))
                if model.site?.remoteScreen != nil {
                    Button { workspace.openScreen(in: side) } label: { Glyph("bt.screen", size: 15) }
                        .iconHelp(String(localized: "원격 화면"))
                }
            }
            Button { model.searchQuery == nil ? model.beginSearch() : model.endSearch() } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(IconButtonStyle(isOn: model.searchQuery != nil))
            .iconHelp(String(localized: "이 폴더에서 찾기 (⌘F)"))
            Button { model.showsHiddenFiles.toggle() } label: {
                Image(systemName: model.showsHiddenFiles ? "eye" : "eye.slash")
            }
            .buttonStyle(IconButtonStyle(isOn: model.showsHiddenFiles))
            .iconHelp(String(localized: "숨김 파일 보기"))
            Button { Task { await model.reload() } } label: { Image(systemName: "arrow.clockwise") }
                .iconHelp(String(localized: "새로고침"))
            HStack(spacing: 0) {
                ForEach(PaneModel.ViewMode.allCases, id: \.self) { mode in
                    Button { model.viewMode = mode } label: {
                        Image(systemName: mode == .list ? "list.bullet" : "square.grid.2x2")
                    }
                    .buttonStyle(IconButtonStyle(isOn: model.viewMode == mode))
                    .iconHelp(mode == .list ? String(localized: "목록으로 보기") : String(localized: "격자로 보기"))
                }
            }
        }
        .buttonStyle(IconButtonStyle())
    }

    // MARK: - Files

    private var fileTable: some View {
        Table(of: FileItem.self, selection: $model.selection) {
            TableColumn(String(localized: "이름")) { item in
                HStack(spacing: 8) {
                    FileGlyph(item: item, isLocal: model.isLocal)
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
                        if model.showsSearchResults, case let location = model.searchLocation(of: item), !location.isEmpty {
                            Text(location)
                                .font(.themeMono(.caption))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        if item.looksSecret {
                            Badge(String(localized: "비밀값")).fixedSize()
                        }
                        if showsCloudBadges, let cloud = item.cloud, cloud != .downloaded {
                            Image(systemName: cloud == .downloading ? "icloud.and.arrow.down" : "icloud")
                                .foregroundStyle(.secondary)
                                .help(cloud == .downloading ? String(localized: "받는 중") : String(localized: "iCloud에만 있음"))
                        }
                    }
                }
                .padding(.vertical, ThemeStore.shared.rowPadding)
            }
            .width(min: 120, ideal: 170)
            TableColumn(String(localized: "크기")) { item in
                Text(item.formattedSize)
                    .font(.ui(.callout))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 50, ideal: 64, max: 110)
            TableColumn(String(localized: "수정")) { item in
                Text(item.shortModified)
                    .font(.ui(.callout))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 76, ideal: 88, max: 140)
            TableColumn(String(localized: "권한")) { item in
                Text(item.permissionString ?? "—")
                    .font(.themeMono(.caption))
                    .foregroundStyle(.secondary)
            }
            .width(min: 68, ideal: 76, max: 110)
        } rows: {
            ForEach(model.shownItems) { item in
                TableRow(item)
                    .itemProvider { workspace.dragProvider(for: item, from: side) }
            }
        }
        .contextMenu(forSelectionType: FileItem.ID.self) { ids in
            contextMenu(for: model.items(withIDs: ids))
        } primaryAction: { ids in
            guard ids.count == 1, let item = model.items(withIDs: ids).first else { return }
            workspace.open(item, in: side)
        }
        .alternatingRowBackgrounds(.disabled)
        .background(PlainTableRows())
        .scrollContentBackground(.hidden)
        .background(Palette.panel)
        .focused($listFocused)
        .onKeyPress(phases: .down, action: handleKey)
        .quickLookPreview($model.quickLookURL, in: model.quickLookURLs)
    }

    /// Big icons, for folders of pictures and the like.
    private var fileGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 120), spacing: 8)], spacing: 8) {
                ForEach(model.shownItems) { item in
                    let selected = model.selection.contains(item.id)
                    VStack(spacing: 6) {
                        FileGlyph(item: item, isLocal: model.isLocal, size: 34)
                            .frame(height: 40)
                        Text(item.name)
                            .font(.ui(.caption))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .truncationMode(.middle)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, minHeight: 92)
                    .background(selected ? Palette.selection : .clear, in: .rect(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.themeAccent.opacity(0.5) : .clear))
                    .contentShape(.rect)
                    .onTapGesture(count: 2) { workspace.open(item, in: side) }
                    .simultaneousGesture(TapGesture().onEnded {
                        if NSEvent.modifierFlags.contains(.command) {
                            if selected { model.selection.remove(item.id) } else { model.selection.insert(item.id) }
                        } else {
                            model.selection = [item.id]
                        }
                        listFocused = true
                    })
                    .contextMenu { contextMenu(for: selected ? model.selectedItems : [item]) }
                    .onDrag { workspace.dragProvider(for: item, from: side) }
                }
            }
            .padding(10)
        }
        .background(Palette.panel)
        .focusable()
        .focusEffectDisabled()
        .focused($listFocused)
        .onKeyPress(phases: .down, action: handleKey)
        .quickLookPreview($model.quickLookURL, in: model.quickLookURLs)
    }

    /// Keys the keymap gives the list (plain ones like Space, ↵ and ⇥; the rest
    /// are menu shortcuts). While a name is being edited, keys belong to the text field.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
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
                Button(count.map { String(localized: "붙여넣기 (\($0)개)") } ?? String(localized: "붙여넣기")) { workspace.paste(into: side, kind: .copy) }
                    .disabled(count == nil)
                Button("여기로 항목 이동") { workspace.paste(into: side, kind: .move) }
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
                Button(item.isDirectory ? String(localized: "열기") : FileKind(item) == .image ? String(localized: "이미지 뷰어로 열기") : String(localized: "열기")) {
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
            if model.showsSearchResults, items.count == 1, let item = items.first {
                Button("포함된 폴더 열기") { Task { await model.reveal(item) } }
                Divider()
            }
            if items.count == 1, let item = items.first, !readOnlyHere, !model.showsSearchResults {
                Button("이름 바꾸기") {
                    model.selection = [item.id]
                    workspace.beginRenaming(in: side)
                }
            }
            if !readOnlyHere, model.provider.capabilities.contains(.permissions) {
                Button("권한 변경…") { permissions = PermissionsRequest(items: items) }
            }
            if items.count == 1, let item = items.first, !readOnlyHere, model.provider.capabilities.contains(.symbolicLinks) {
                Button("링크 만들기") { Task { await model.makeLink(to: item) } }
            }
            if model.canRunCommands, !readOnlyHere {
                Button(items.count == 1 ? String(localized: "서버에서 압축 (tar.gz)") : String(localized: "\(items.count)개를 서버에서 압축")) {
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
                Button(model.provider.capabilities.contains(.trash) ? String(localized: "휴지통으로 이동") : String(localized: "삭제…"), role: .destructive) {
                    workspace.delete(items, in: side)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(model.downloadStatus ?? summary)
            Spacer()
            // The path is already in the header; a server's address is not.
            if let address = model.remoteAddress {
                Text(address)
                    .font(.themeMono(.caption))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .font(.ui(.caption))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Palette.panel)
    }

    private var summary: String {
        let count = !model.showsSearchResults
            ? String(localized: "\(model.visibleItems.count)개 항목")
            : String(localized: "찾은 항목 \(model.shownItems.count)개") + (model.searchResults.count >= PaneModel.searchLimit ? String(localized: " (처음 \(PaneModel.searchLimit)개)") : "")
        let selected = model.selectedItems
        guard !selected.isEmpty else { return count }
        let bytes = selected.compactMap(\.size).reduce(0, +)
        let size = bytes > 0 ? " (\(ByteFormat.string(bytes)))" : ""
        return String(localized: "\(count) · \(selected.count)개 선택\(size)")
    }
}

/// Takes the grid lines off the table SwiftUI draws, so rows sit on the card
/// like the design's.
private struct PlainTableRows: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { Self.tidy(from: view) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { Self.tidy(from: view) }
    }

    /// The table this view sits behind: the one under its centre.
    private static func tidy(from view: NSView) {
        guard let root = view.window?.contentView else { return }
        let frame = view.convert(view.bounds, to: nil)
        let center = CGPoint(x: frame.midX, y: frame.midY)
        guard let table = tables(in: root).first(where: { table in
            let scroll = table.enclosingScrollView ?? table
            return scroll.convert(scroll.bounds, to: nil).contains(center)
        }) else { return }
        table.gridStyleMask = []
        table.intercellSpacing = NSSize(width: 8, height: table.intercellSpacing.height)
        if table.numberOfRows > 0, let row = table.rowView(atRow: 0, makeIfNecessary: true) {
            TableRowLook.hideSeparators(in: type(of: row))
            TableRowLook.useFaintSelection(in: type(of: row))
        }
        // The name column takes what the pane gains or loses.
        if table.columnAutoresizingStyle != .firstColumnOnlyAutoresizingStyle {
            table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
            table.sizeToFit()
        }
    }

    private static func tables(in view: NSView) -> [NSTableView] {
        if let table = view as? NSTableView { return [table] }
        return view.subviews.flatMap(tables)
    }
}

/// "Find in this folder": what to look for, how the search is going, and the
/// way back to the folder.
private struct SearchField: View {
    let model: PaneModel
    let done: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("이 폴더 아래에서 찾을 이름 (*.log 같은 패턴도 됨)", text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onChange(of: text) { model.search(text) }
                .onSubmit(done)
                .onKeyPress(.escape) {
                    model.endSearch()
                    done()
                    return .handled
                }
            if model.isSearching {
                ProgressView().controlSize(.small)
            }
            Button("닫기") {
                model.endSearch()
                done()
            }
            .buttonStyle(.borderless)
            .font(.ui(.caption))
        }
        .font(.ui(.callout))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Palette.panel2, in: .rect(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.line))
        .onAppear {
            text = model.searchQuery ?? ""
            focused = true
        }
    }
}

/// The current folder in mono, each part clickable.
private struct PathBar: View {
    let path: RemotePath
    let open: (RemotePath) -> Void

    var body: some View {
        // Reads from the left like a path; a long one scrolls to keep its end in view.
        ViewThatFits(in: .horizontal) {
            crumbs
                .frame(maxWidth: .infinity, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                crumbs
            }
            .defaultScrollAnchor(.trailing)
        }
    }

    private var crumbs: some View {
        HStack(spacing: 0) {
            ForEach(path.lineage, id: \.self) { crumb in
                if !crumb.isRoot, crumb.parent?.isRoot == false {
                    Text("/").foregroundStyle(.tertiary)
                }
                Button(crumb.isRoot ? "/" : crumb.name) { open(crumb) }
                    .buttonStyle(.plain)
                    .foregroundStyle(crumb == path ? AnyShapeStyle(Palette.text) : AnyShapeStyle(.secondary))
            }
        }
        .font(.themeMono(.callout))
        .fixedSize()
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
        .font(.ui(.callout))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.orange.opacity(0.1))
    }
}

/// Opens the connection manager, optionally on one site with why it failed to open.
struct SiteManagerRequest: Identifiable {
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
