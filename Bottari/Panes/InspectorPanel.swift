import AppKit
import BottariCore
import BottariSFTP
import BottariTransfer
import ImageIO
import SwiftUI

/// The column right of the panes: the selected file's first lines or picture,
/// its details, and what can be done with it from here.
struct InspectorPanel: View {
    let workspace: Workspace
    @State private var preview = Preview.none

    enum Preview {
        case none, loading, text(String), image(NSImage), message(String)
    }

    private var side: PaneSide { workspace.activeSide }
    private var pane: PaneModel { workspace.pane(side) }
    private var other: PaneModel { workspace.pane(side.other) }
    private var selected: [FileItem] { pane.selectedItems }
    private var item: FileItem? { selected.count == 1 ? selected.first : nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("미리보기")
                previewBox
                if let item {
                    details(item)
                    actions(for: [item])
                } else if !selected.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(selected.count)개 선택").font(.ui(.title3, weight: .semibold))
                        Text(selectionSize).font(.themeMono(.caption)).foregroundStyle(.secondary)
                    }
                    actions(for: selected)
                } else {
                    Text("파일을 고르면 여기에 보여요")
                        .font(.ui(.callout))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
        }
        .scrollIndicators(.never)
        .card()
        .task(id: previewKey) { await loadPreview() }
    }

    // MARK: - Preview

    private var previewKey: String {
        guard let item else { return "none" }
        return "\(pane.provider.locationID)\(item.path.string)\(item.modified?.timeIntervalSince1970 ?? 0)"
    }

    @ViewBuilder
    private var previewBox: some View {
        Group {
            switch preview {
            case .text(let text):
                Text(text)
                    .font(.themeMono(.caption))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(10)
            case .image(let image):
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(6)
            case .loading:
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .message(let text):
                placeholder(text)
            case .none:
                placeholder(nil)
            }
        }
        .frame(height: 230)
        .clipped()
        .well()
    }

    private func placeholder(_ text: String?) -> some View {
        VStack(spacing: 8) {
            if let item {
                FileGlyph(item: item, isLocal: pane.isLocal, size: 40)
            } else {
                Image(systemName: "doc.viewfinder").font(.system(size: 30)).foregroundStyle(.tertiary)
            }
            if let text {
                Text(text).font(.ui(.caption)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Text files show their first lines; pictures a thumbnail. From a server
    /// only small files come down, and only a part of text files.
    private func loadPreview() async {
        guard let item, !item.isDirectory else {
            preview = .none
            return
        }
        let provider = pane.provider
        let size = item.size ?? 0
        switch FileKind(item) {
        case .text:
            preview = .loading
            let limit: Int64 = 16 * 1024
            let range: Range<Int64>? = provider.capabilities.contains(.rangeRead) || provider.isLocal ? 0..<min(max(size, 1), limit) : nil
            guard range != nil || size <= 256 * 1024 else {
                preview = .message("크기가 커서 미리 받지 않았어요")
                return
            }
            do {
                let data = try await provider.readData(item.path, range: range)
                guard !Task.isCancelled else { return }
                let text = String(decoding: data.prefix(Int(limit)), as: UTF8.self)
                preview = .text(text.split(separator: "\n", omittingEmptySubsequences: false).prefix(40).joined(separator: "\n"))
            } catch {
                if !Task.isCancelled { preview = .message("미리 보지 못했어요") }
            }
        case .image:
            if provider.isLocal {
                preview = Self.thumbnail(CGImageSourceCreateWithURL(URL(fileURLWithPath: item.path.string) as CFURL, nil)).map(Preview.image) ?? .none
                return
            }
            guard size <= 5_000_000 else {
                preview = .message("크기가 커서 미리 받지 않았어요 · 열면 받아요")
                return
            }
            preview = .loading
            do {
                let data = try await provider.readData(item.path)
                guard !Task.isCancelled else { return }
                preview = Self.thumbnail(CGImageSourceCreateWithData(data as CFData, nil)).map(Preview.image) ?? .none
            } catch {
                if !Task.isCancelled { preview = .message("미리 보지 못했어요") }
            }
        case .video, .other:
            preview = .none
        }
    }

    private static func thumbnail(_ source: CGImageSource?) -> NSImage? {
        guard let source, let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 600,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    // MARK: - Details

    private func details(_ item: FileItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.ui(.title3, weight: .semibold))
                    .lineLimit(2)
                Text("\(placeName(pane)):\(item.path.string)")
                    .font(.themeMono(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                row("크기", item.isDirectory ? "폴더" : item.formattedSize)
                row("수정", item.formattedModified)
                if let permissions = item.permissionString { row("권한", permissions) }
                if let owner = item.owner { row("소유자", owner) }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).font(.ui(.caption)).foregroundStyle(.secondary)
            Text(value).font(.themeMono(.caption)).textSelection(.enabled)
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private func actions(for items: [FileItem]) -> some View {
        VStack(spacing: 8) {
            if let item = items.count == 1 ? items.first : nil {
                Button(primaryTitle(item)) { primaryAction(item) }
                    .buttonStyle(PanelButtonStyle(prominent: true))
            }
            Button {
                workspace.send(items, from: side, kind: .copy)
            } label: {
                Label("\(other.provider.displayName)에 복사", systemImage: "arrow.right")
            }
            .buttonStyle(PanelButtonStyle())
            .disabled(other.site?.readOnly == true)
            route
            let bundled = items.allSatisfy { item in
                BottariBundle.shared.entries.contains { $0.item.path == item.path && $0.provider.locationID == pane.provider.locationID }
            }
            Button {
                workspace.addToBundle(from: side, items: items)
            } label: {
                Label(bundled ? "보따리에 담겨 있어요" : "보따리에 담기", systemImage: "shippingbox")
            }
            .buttonStyle(PanelButtonStyle(dashed: true))
            .disabled(bundled)
        }
    }

    private func primaryTitle(_ item: FileItem) -> String {
        if item.isDirectory { return "열기" }
        return switch FileKind(item) {
        case .text: "편집하기"
        case .image: "이미지 뷰어로 열기"
        case .video: "재생하기"
        case .other: "빠른 미리보기"
        }
    }

    private func primaryAction(_ item: FileItem) {
        if FileKind(item) == .text {
            workspace.openInEditor(item, in: side)
        } else {
            workspace.open(item, in: side)
        }
    }

    /// Where the copy would go and how: `prod-web → Mac → Google Drive`.
    private var route: some View {
        let route = TransferQueue.route(.copy, from: pane.provider, to: other.provider)
        let from = placeName(pane), to = placeName(other)
        let (stops, note): ([RouteStop], String) = switch route {
        case .viaMac: ([RouteStop(name: from), RouteStop(name: "Mac", passingThrough: true), RouteStop(name: to)], "Mac 경유 복사 · 읽기 → 쓰기 스트림 연결 · 임시 파일 없음")
        case .withinLocation: ([RouteStop(name: from)], pane.provider.isLocal ? "Mac 안에서 복사" : "서버 안에서 복사 · 내려받지 않아요")
        case .upload: ([RouteStop(name: from), RouteStop(name: to)], "업로드 · 임시 이름으로 쓰고 끝나면 이름 바꾸기")
        case .download: ([RouteStop(name: from), RouteStop(name: to)], "다운로드 · 임시 이름으로 쓰고 끝나면 이름 바꾸기")
        case .local: ([RouteStop(name: from), RouteStop(name: to)], "Mac 안에서 복사")
        }
        return VStack(alignment: .leading, spacing: 6) {
            RouteChips(stops: stops)
            Text(note)
                .font(.ui(.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .well()
    }

    private func placeName(_ pane: PaneModel) -> String {
        pane.site?.name ?? (pane.isLocal ? "Mac" : pane.provider.displayName)
    }

    private var selectionSize: String {
        let bytes = selected.compactMap(\.size).reduce(0, +)
        return bytes > 0 ? ByteFormat.string(bytes) : ""
    }
}
