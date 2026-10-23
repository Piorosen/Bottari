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
        let total = item.size.map { $0.formatted(.byteCount(style: .file)) }
        loading = Task {
            do {
                let url = try await AppServices.fileCache.localURL(for: item, from: provider) { received in
                    let text = "원본 받는 중 · \(received.formatted(.byteCount(style: .file)))" + (total.map { " / \($0)" } ?? "")
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
            Divider()
            HStack(spacing: 0) {
                imageArea
                if model.showsInfo, let item = model.current {
                    Divider()
                    info(item)
                        .frame(width: 240)
                }
            }
            Divider()
            filmstrip
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { model.step(-1); return .handled }
        .onKeyPress(.rightArrow) { model.step(1); return .handled }
        .onKeyPress(.space) { close(); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
        .navigationTitle(model.current?.name ?? "이미지")
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: model.provider.isLocal ? "laptopcomputer" : "server.rack")
                .foregroundStyle(model.site?.tag == .prod ? SavedSite.Tag.prod.color : .secondary)
            Text(model.provider.displayName)
                .font(.headline)
            if let tag = model.site?.tag {
                TagChip(tag: tag)
            }
            Text(model.current?.path.parent?.string ?? "")
                .font(.themeMono(.callout))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
            if let status = model.status {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("\(model.index + 1) / \(model.items.count)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Picker("크기", selection: $model.actualSize) {
                Text("맞춤").tag(false)
                Text("100%").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Toggle(isOn: $model.showsInfo) {
                Image(systemName: "info.circle")
            }
            .toggleStyle(.button)
            .help("정보")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var imageArea: some View {
        ZStack {
            Color.black.opacity(0.92)
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
                        .padding(12)
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
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
    }

    private func arrow(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title2.weight(.semibold))
                .frame(width: 36, height: 36)
                .background(.ultraThinMaterial, in: .circle)
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0)
        .disabled(!enabled)
    }

    private func info(_ item: FileItem) -> some View {
        Form {
            LabeledContent("이름", value: item.name)
            if let pixels = model.pixelSize {
                LabeledContent("크기", value: "\(Int(pixels.width)) × \(Int(pixels.height))")
            }
            LabeledContent("용량", value: item.formattedSize)
            LabeledContent("수정한 날짜", value: item.formattedModified)
            LabeledContent("위치", value: item.path.parent?.string ?? "/")
        }
        .formStyle(.grouped)
    }

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        Button {
                            model.show(index)
                        } label: {
                            Group {
                                if let thumbnail = model.thumbnails[item.path] {
                                    Image(nsImage: thumbnail)
                                        .resizable()
                                        .scaledToFill()
                                } else {
                                    Image(systemName: "photo")
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .frame(width: 64, height: 48)
                            .clipShape(.rect(cornerRadius: 4))
                            .overlay {
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(index == model.index ? Color.themeAccent : .clear, lineWidth: 2)
                            }
                        }
                        .buttonStyle(.plain)
                        .help(item.name)
                        .id(index)
                    }
                }
                .padding(8)
            }
            .frame(height: 64)
            .onChange(of: model.index) {
                withAnimation { proxy.scrollTo(model.index, anchor: .center) }
            }
        }
    }
}
