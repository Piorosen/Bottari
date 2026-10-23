import BottariCore
import SwiftUI

/// A Finder-style list of one folder, with history buttons and a clickable path.
struct PaneView: View {
    @Bindable var model: PaneModel
    let isActive: Bool
    let becomeActive: () -> Void

    @FocusState private var listFocused: Bool

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
            Rectangle()
                .fill(isActive ? Color.accentColor : .clear)
                .frame(height: 2)
        }
        .frame(minWidth: 360)
        .task { await model.start() }
        .onChange(of: listFocused) { _, focused in
            if focused { becomeActive() }
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

            Label(model.provider.displayName, systemImage: model.isLocal ? "laptopcomputer" : "server.rack")
                .font(.headline)
                .labelStyle(.titleAndIcon)
                .padding(.leading, 4)

            PathBar(path: model.path) { target in
                Task { await model.open(target) }
            }

            Spacer(minLength: 8)

            if model.isLoading {
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
        Table(model.visibleItems, selection: $model.selection) {
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
        }
        .contextMenu(forSelectionType: FileItem.ID.self) { _ in
            EmptyView()
        } primaryAction: { ids in
            guard ids.count == 1, let item = model.items.first(where: { ids.contains($0.id) }) else { return }
            Task { await model.activate(item) }
        }
        .focused($listFocused)
        .onKeyPress(.delete) {
            Task { await model.goBack() }
            return .handled
        }
        .overlay {
            if model.visibleItems.isEmpty && !model.isLoading && model.errorMessage == nil {
                ContentUnavailableView("비어 있어요", systemImage: "folder")
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(summary)
            Spacer()
            Text(model.path.string)
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
