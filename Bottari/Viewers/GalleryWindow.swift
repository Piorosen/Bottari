import AppKit
import BottariCore
import BottariSFTP
import ImageIO
import Observation
import SwiftUI

/// Images of one folder, one at a time: the thumbnail first, then the original.
@Observable
final class GalleryModel {
    let provider: any FileProvider
    let site: SavedSite?
    let items: [FileItem]
    private(set) var index: Int
    private(set) var image: NSImage?
    private(set) var pixelSize: CGSize?
    /// "원본 받는 중 · 2 MB / 5 MB", or why the image could not be shown.
    private(set) var status: String?
    private(set) var thumbnails: [RemotePath: NSImage] = [:]
    var actualSize = false
    var showsInfo = false

    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var thumbnailing: Task<Void, Never>?

    init(context: ViewerContext) {
        provider = context.provider
        site = context.site
        items = context.siblings.filter { FileKind($0) == .image }
        index = items.firstIndex(of: context.item) ?? 0
    }

    var current: FileItem? { items.indices.contains(index) ? items[index] : nil }

    func show(_ newIndex: Int) {
        guard items.indices.contains(newIndex) else { return }
        index = newIndex
        load()
    }

    func step(_ delta: Int) {
        show(min(max(index + delta, 0), items.count - 1))
    }

    func load() {
        guard let item = current else { return }
        loading?.cancel()
        image = thumbnails[item.path]
        pixelSize = nil
        status = provider.isLocal ? nil : "원본 받는 중…"
        let total = item.size.map { ByteFormat.string($0) }
        loading = Task {
            do {
                let url = try await AppServices.fileCache.localURL(for: item, from: provider) { received in
                    let text = "원본 받는 중 · \(ByteFormat.string(received))" + (total.map { " / \($0)" } ?? "")
                    Task { @MainActor in
                        if self.current == item, self.status != nil { self.status = text }
                    }
                }
                let decoded = await Task.detached { Self.decode(url) }.value
                guard !Task.isCancelled, current == item else { return }
                guard let decoded else {
                    status = "이미지를 열지 못했어요"
                    return
                }
                image = NSImage(cgImage: decoded, size: .zero)
                pixelSize = CGSize(width: decoded.width, height: decoded.height)
                status = nil
                prefetch()
            } catch is CancellationError {
            } catch {
                if current == item { status = error.localizedDescription }
            }
        }
        loadThumbnails()
    }

    /// Downloads the next two originals so stepping forward is instant.
    private func prefetch() {
        guard !provider.isLocal else { return }
        for next in items.dropFirst(index + 1).prefix(2) {
            Task { _ = try? await AppServices.fileCache.localURL(for: next, from: provider) }
        }
    }

    /// Thumbnails nearest the current image first.
    private func loadThumbnails() {
        thumbnailing?.cancel()
        let order = items.indices.sorted { abs($0 - index) < abs($1 - index) }.prefix(40).map { items[$0] }
        thumbnailing = Task {
            for item in order where thumbnails[item.path] == nil {
                guard !Task.isCancelled else { return }
                if let thumbnail = await Thumbnails.make(for: item, from: provider) {
                    thumbnails[item.path] = NSImage(cgImage: thumbnail, size: .zero)
                    if current == item, image == nil { image = thumbnails[item.path] }
                }
            }
        }
    }

    func close() {
        loading?.cancel()
        thumbnailing?.cancel()
    }

    nonisolated private static func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        // Apply the EXIF orientation, as Preview does.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 16_384,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Small images for the filmstrip.
enum Thumbnails {
    nonisolated static let maxPixels = 240

    /// From the file on the Mac; for a server, the thumbnail embedded in the
    /// first 256 KB (cameras put one there), or the whole file when it is small.
    static func make(for item: FileItem, from provider: any FileProvider) async -> CGImage? {
        if provider.isLocal {
            let url = URL(fileURLWithPath: item.path.string)
            return await Task.detached { fromSource(CGImageSourceCreateWithURL(url as CFURL, nil), embeddedOnly: false) }.value
        }
        if provider.capabilities.contains(.rangeRead), let size = item.size, size > 512 * 1024,
           let head = try? await provider.readData(item.path, range: 0..<min(size, 256 * 1024)) {
            if let embedded = await Task.detached(operation: { fromSource(CGImageSourceCreateWithData(head as CFData, nil), embeddedOnly: true) }).value {
                return embedded
            }
            guard size <= 4 * 1024 * 1024 else { return nil }
        }
        guard let url = try? await AppServices.fileCache.localURL(for: item, from: provider) else { return nil }
        return await Task.detached { fromSource(CGImageSourceCreateWithURL(url as CFURL, nil), embeddedOnly: false) }.value
    }

    nonisolated private static func fromSource(_ source: CGImageSource?, embeddedOnly: Bool) -> CGImage? {
        guard let source else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: !embeddedOnly,
            kCGImageSourceCreateThumbnailFromImageAlways: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

struct GalleryWindow: View {
    let contextID: UUID
    @State private var model: GalleryModel?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let model {
                GalleryView(model: model) { dismiss() }
            } else {
                ContentUnavailableView("이미지를 열 수 없어요", systemImage: "photo")
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .onAppear {
            guard model == nil, let context = Viewers.context(contextID) else { return }
            let gallery = GalleryModel(context: context)
            model = gallery
            gallery.load()
        }
        .onDisappear {
            model?.close()
            Viewers.close(contextID)
        }
    }
}

private struct GalleryView: View {
    @Bindable var model: GalleryModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(Palette.line).frame(height: 1)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    imageArea
                    filmstrip
                }
                if model.showsInfo, let item = model.current {
                    Rectangle().fill(Palette.line).frame(width: 1)
                    info(item)
                        .frame(width: 290)
                }
            }
        }
        .background(Palette.background)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { model.step(-1); return .handled }
        .onKeyPress(.rightArrow) { model.step(1); return .handled }
        .onKeyPress(.space) { close(); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
        .navigationTitle(model.current?.name ?? "이미지")
    }

    private var placeName: String {
        model.site?.name ?? (model.provider.isLocal ? "Mac" : model.provider.displayName)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            BackButton(title: "목록으로", action: close)
                .buttonStyle(PanelButtonStyle())
                .fixedSize()
            if let tag = model.site?.tag {
                if tag == .prod { TagChip(tag: tag) } else { TagChip.outlined(tag) }
            }
            Text("\(placeName):\(model.current?.path.parent?.string ?? "")")
                .font(.themeMono(.callout))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Text("\(model.index + 1) / \(model.items.count)")
                .font(.themeMono(.callout))
                .foregroundStyle(.secondary)
            Spacer()
            if let status = model.status {
                Text(status)
                    .font(.ui(.caption))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 0) {
                Button("맞춤") { model.actualSize = false }
                    .buttonStyle(ChoiceButtonStyle(isOn: !model.actualSize))
                Button("100%") { model.actualSize = true }
                    .buttonStyle(ChoiceButtonStyle(isOn: model.actualSize))
            }
            .fixedSize()
            Button("정보") { model.showsInfo.toggle() }
                .buttonStyle(ChoiceButtonStyle(isOn: model.showsInfo))
                .fixedSize()
            if let item = model.current {
                Button("보따리에 담기") {
                    BottariBundle.shared.add([item], from: model.provider, site: model.site)
                }
                .buttonStyle(PanelButtonStyle(prominent: true))
                .fixedSize()
                .disabled(BottariBundle.shared.entries.contains { $0.item.path == item.path && $0.provider.locationID == model.provider.locationID })
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Palette.panel2)
    }

    private var imageArea: some View {
        ZStack {
            Color(light: 0x0E1014, dark: 0x0A0C10)
            if let image = model.image {
                if model.actualSize, let pixels = model.pixelSize {
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: pixels.width / (NSScreen.main?.backingScaleFactor ?? 2), height: pixels.height / (NSScreen.main?.backingScaleFactor ?? 2))
                    }
                } else {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .padding(40)
                }
            } else {
                ProgressView()
                    .controlSize(.large)
            }
            HStack {
                arrow("chevron.left", enabled: model.index > 0) { model.step(-1) }
                Spacer()
                arrow("chevron.right", enabled: model.index < model.items.count - 1) { model.step(1) }
            }
            .padding(16)
            Text("← → 넘기기 · Space 닫기")
                .font(.ui(.caption))
                .foregroundStyle(.white.opacity(0.55))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
    }

    private func arrow(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.1), in: .circle)
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0)
        .disabled(!enabled)
    }

    private func info(_ item: FileItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name).font(.ui(.title3, weight: .semibold))
                    Text([item.formattedSize, item.path.pathExtension.uppercased()].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.themeMono(.caption))
                        .foregroundStyle(.secondary)
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    if let pixels = model.pixelSize {
                        row("해상도", "\(Int(pixels.width)) × \(Int(pixels.height))")
                    }
                    row("수정", item.formattedModified)
                    if let permissions = item.permissionString {
                        row("권한", [permissions, item.owner].compactMap { $0 }.joined(separator: " "))
                    }
                    row("경로", item.path.string)
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("불러오는 방식")
                    loadRow("썸네일", "\(model.thumbnails.count) / \(model.items.count)장", done: model.thumbnails[item.path] != nil)
                    loadRow("원본", model.provider.isLocal ? "이 Mac의 파일" : model.status == nil && model.image != nil ? "받음 · \(item.formattedSize)" : "받는 중", done: model.status == nil && model.image != nil)
                    if !model.provider.isLocal {
                        Text("캐시 키는 경로 + 수정 시각 + 크기라서, 서버에서 파일이 바뀌면 자동으로 새로 받아요.")
                            .font(.ui(.caption))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .well()
            }
            .padding(16)
        }
        .background(Palette.panel)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).font(.ui(.caption)).foregroundStyle(.secondary)
            Text(value).font(.themeMono(.caption)).textSelection(.enabled).lineLimit(3)
        }
    }

    private func loadRow(_ label: String, _ value: String, done: Bool) -> some View {
        HStack {
            Text(label).font(.ui(.callout))
            Spacer()
            Text(value)
                .font(.themeMono(.caption))
                .foregroundStyle(done ? Color(light: 0x0F7C5A, dark: 0x3CC48E) : .secondary)
        }
    }

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        Button {
                            model.show(index)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Group {
                                    if let thumbnail = model.thumbnails[item.path] {
                                        Image(nsImage: thumbnail)
                                            .resizable()
                                            .scaledToFill()
                                    } else {
                                        Image(systemName: "photo")
                                            .foregroundStyle(.tertiary)
                                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                                            .background(Palette.panel2)
                                    }
                                }
                                .frame(width: 96, height: 62)
                                .clipShape(.rect(cornerRadius: 5))
                                Text(item.name)
                                    .font(.ui(.caption))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(width: 96, alignment: .leading)
                            }
                            .padding(6)
                            .background(Palette.panel, in: .rect(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(index == model.index ? Color.themeAccent : Palette.line, lineWidth: index == model.index ? 2 : 1)
                            }
                        }
                        .buttonStyle(.plain)
                        .help(item.name)
                        .id(index)
                    }
                }
                .padding(12)
            }
            .frame(height: 112)
            .background(Palette.background)
            .onChange(of: model.index) {
                withAnimation { proxy.scrollTo(model.index, anchor: .center) }
            }
        }
    }
}
