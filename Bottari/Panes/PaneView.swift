import BottariCore
import BottariSFTP
import BottariTransfer
import SwiftUI

/// A Finder-style list of one folder, with history buttons and a clickable path.
struct PaneView: View {
    let workspace: Workspace
    let side: PaneSide
    @Bindable var model: PaneModel

    @FocusState private var listFocused: Bool
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
            if let message = model.errorMessage {
                ErrorBanner(message: message, dismiss: model.dismissError)
            }
            Divider()
            fileTable
            Divider()
            footer
        }
        .overlay(alignment: .top) {
            // A PROD pane keeps its warning band even when it is not the active one.
            Rectangle()
                .fill(isProd ? SavedSite.Tag.prod.color : isActive ? Color.accentColor : .clear)
                .frame(height: isProd ? 3 : 2)
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .background(Color.accentColor.opacity(0.06))
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
                                Label(site.tag.map { "\(site.name)  ·  \($0.label)" } ?? site.name, systemImage: "server.rack")
                            }
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
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
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
                    .font(.system(.caption, design: .monospaced))
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
            Task { await model.activate(item) }
        }
        .focused($listFocused)
        .onKeyPress(.delete) {
            Task { await model.goBack() }
            return .handled
        }
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
                Button(count.map { "붙여넣기 (\($0)개)" } ?? "붙여넣기") { workspace.paste(into: side, kind: .copy) }
                    .disabled(count == nil)
                Button("이동해서 붙여넣기") { workspace.paste(into: side, kind: .move) }
                    .disabled(count == nil)
                Divider()
            }
            Button("새로고침") { Task { await model.reload() } }
        } else {
            if items.count == 1, let item = items.first, item.isDirectory {
                Button("열기") { Task { await model.activate(item) } }
                Divider()
            }
            if !readOnlyThere {
                Button("\(otherName)에 복사") { workspace.send(items, from: side, kind: .copy) }
                if !readOnlyHere {
                    Button("\(otherName)(으)로 이동") { workspace.send(items, from: side, kind: .move) }
                }
                Divider()
            }
            Button("복사") { AppServices.clipboard.copy(items, from: model.provider, site: model.site) }
        }
    }

    private var footer: some View {
        HStack {
            Text(summary)
            Spacer()
            Text(model.remoteAddress.map { "\($0):\(model.path.string)" } ?? model.path.string)
                .font(.system(.caption, design: .monospaced))
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
            .font(.system(.callout, design: .monospaced))
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
