import AppKit
import BottariCore
import BottariPlayer
import BottariSFTP
import Observation
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

/// Videos of one folder, played by libmpv straight from where they are.
@Observable
final class PlayerModel {
    struct Read: Identifiable {
        let id = UUID()
        let offset: Int64
        let at: Date
    }

    let provider: any FileProvider
    let site: SavedSite?
    let items: [FileItem]
    private let siblings: [FileItem]
    private(set) var index: Int
    private(set) var state = PlayerState()
    /// Where FFmpeg asked to read from, newest first.
    private(set) var reads: [Read] = []
    var showsSidebar = false
    private(set) var failure: String?

    @ObservationIgnored private var player: MPVPlayer?

    init(context: ViewerContext) {
        provider = context.provider
        site = context.site
        siblings = context.siblings
        items = context.siblings.filter { FileKind($0) == .video }
        index = items.firstIndex(of: context.item) ?? 0
    }

    var current: FileItem? { items.indices.contains(index) ? items[index] : nil }

    func attach(to layer: CAMetalLayer) {
        guard player == nil else { return }
        do {
            let player = try MPVPlayer(layer: layer)
            player.onChange = { [weak self] state in self?.state = state }
            player.onRead = { [weak self] offset in
                Task { @MainActor in
                    self?.reads.insert(Read(offset: offset, at: Date()), at: 0)
                    if (self?.reads.count ?? 0) > 30 { self?.reads.removeLast() }
                }
            }
            self.player = player
            playCurrent()
        } catch {
            failure = error.localizedDescription
        }
    }

    func show(_ newIndex: Int) {
        guard items.indices.contains(newIndex) else { return }
        index = newIndex
        playCurrent()
    }

    private func playCurrent() {
        guard let player, let item = current else { return }
        reads = []
        player.play(item, from: provider)
        player.setPaused(false)
        loadMatchingSubtitles(for: item)
    }

    /// "movie.srt" or "movie.ko.ass" next to "movie.mkv" loads by itself.
    private func loadMatchingSubtitles(for item: FileItem) {
        let stem = (item.name as NSString).deletingPathExtension
        let subtitles = siblings.filter { sibling in
            ["srt", "ass", "ssa", "vtt", "sub"].contains(sibling.path.pathExtension.lowercased())
                && sibling.name.hasPrefix(stem)
        }
        for subtitle in subtitles {
            Task {
                guard let url = try? await AppServices.fileCache.localURL(for: subtitle, from: provider), current == item else { return }
                player?.addSubtitle(url)
            }
        }
    }

    func togglePause() { player?.togglePause() }
    func seek(to seconds: Double) { player?.seek(to: seconds) }
    func seek(by seconds: Double) { player?.seek(by: seconds) }
    func setVolume(_ volume: Double) { player?.setVolume(volume) }
    func select(_ kind: PlayerState.Track.Kind, id: Int?) { player?.select(kind, id: id) }

    func chooseSubtitleFile() {
        let panel = NSOpenPanel()
        panel.title = "자막 파일 불러오기"
        panel.allowedContentTypes = ["srt", "ass", "ssa", "vtt", "sub"].compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK, let url = panel.url {
            player?.addSubtitle(url)
        }
    }

    func close() {
        player?.shutDown()
        player = nil
    }
}

struct PlayerWindow: View {
    let contextID: UUID
    @State private var model: PlayerModel?

    var body: some View {
        Group {
            if let model {
                PlayerView(model: model)
            } else {
                ContentUnavailableView("영상을 열 수 없어요", systemImage: "film")
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .onAppear {
            guard model == nil, let context = Viewers.context(contextID) else { return }
            model = PlayerModel(context: context)
        }
        .onDisappear {
            model?.close()
            Viewers.close(contextID)
        }
    }
}

private struct PlayerView: View {
    @Bindable var model: PlayerModel
    @State private var scrubbing: Double?
    @State private var showsControls = true

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ZStack {
                    MPVVideoView { model.attach(to: $0) }
                    overlay
                }
                .background(.black)
                controls
            }
            if model.showsSidebar {
                Divider()
                sidebar
                    .frame(width: 280)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) { model.togglePause(); return .handled }
        .onKeyPress(.leftArrow) { model.seek(by: -10); return .handled }
        .onKeyPress(.rightArrow) { model.seek(by: 10); return .handled }
        .onKeyPress(.upArrow) { model.setVolume(min(130, model.state.volume + 5)); return .handled }
        .onKeyPress(.downArrow) { model.setVolume(max(0, model.state.volume - 5)); return .handled }
        .onKeyPress(characters: ["f"]) { _ in
            NSApp.keyWindow?.toggleFullScreen(nil)
            return .handled
        }
        .navigationTitle(model.current?.name ?? "영상")
    }

    @ViewBuilder
    private var overlay: some View {
        if let failure = model.failure ?? model.state.error {
            ContentUnavailableView("재생할 수 없어요", systemImage: "exclamationmark.triangle", description: Text(failure))
                .foregroundStyle(.white)
        } else if model.state.isBuffering || model.state.duration == 0 {
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.large)
                Text(model.state.duration == 0 ? "여는 중…" : "버퍼링 · 새 위치부터 읽는 중")
                    .font(.callout)
            }
            .padding(16)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 10))
            .environment(\.colorScheme, .dark)
        }
    }

    private var controls: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Text(timeText(scrubbing ?? model.state.position))
                    .monospacedDigit()
                Slider(
                    value: Binding(get: { scrubbing ?? model.state.position }, set: { scrubbing = $0 }),
                    in: 0...max(model.state.duration, 1)
                ) { editing in
                    if !editing, let target = scrubbing {
                        model.seek(to: target)
                        scrubbing = nil
                    }
                }
                Text(timeText(model.state.duration))
                    .monospacedDigit()
            }
            HStack(spacing: 14) {
                Button { model.show(model.index - 1) } label: { Image(systemName: "backward.end.fill") }
                    .disabled(model.index == 0)
                Button { model.seek(by: -10) } label: { Image(systemName: "gobackward.10") }
                Button { model.togglePause() } label: {
                    Image(systemName: model.state.isPaused ? "play.fill" : "pause.fill")
                        .font(.title2)
                        .frame(width: 28)
                }
                Button { model.seek(by: 10) } label: { Image(systemName: "goforward.10") }
                Button { model.show(model.index + 1) } label: { Image(systemName: "forward.end.fill") }
                    .disabled(model.index >= model.items.count - 1)
                Spacer()
                engineBadge
                trackMenu(.sub, title: "자막", symbol: "captions.bubble")
                trackMenu(.audio, title: "오디오", symbol: "speaker.wave.2")
                Image(systemName: "speaker.fill")
                    .foregroundStyle(.secondary)
                Slider(value: Binding(get: { model.state.volume }, set: { model.setVolume($0) }), in: 0...130)
                    .frame(width: 90)
                Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .help("전체 화면 (F)")
                Toggle(isOn: $model.showsSidebar) { Image(systemName: "sidebar.right") }
                    .toggleStyle(.button)
                    .help("재생 목록과 읽기 요청")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var engineBadge: some View {
        let hardware = model.state.hardwareDecoder.map { $0 != "no" && !$0.isEmpty } ?? false
        return HStack(spacing: 4) {
            Text("libmpv · FFmpeg")
            if let codec = model.state.videoCodec {
                Text("· \(codec.components(separatedBy: " ").first ?? codec)")
            }
            if model.state.hardwareDecoder != nil {
                Text(hardware ? "· 하드웨어" : "· CPU")
                    .foregroundStyle(hardware ? .green : .orange)
                    .help(hardware ? "Mac 하드웨어(VideoToolbox)로 풀어요" : "이 코덱은 Mac 하드웨어가 못 풀어서 CPU로 풀어요")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func trackMenu(_ kind: PlayerState.Track.Kind, title: String, symbol: String) -> some View {
        let tracks = model.state.tracks.filter { $0.kind == kind }
        return Menu {
            if kind == .sub {
                Button("끄기") { model.select(.sub, id: nil) }
                Divider()
            }
            if tracks.isEmpty {
                Text(kind == .sub ? "내장 자막 없음" : "오디오 트랙 없음")
            }
            ForEach(tracks) { track in
                Button {
                    model.select(kind, id: track.id)
                } label: {
                    if track.isSelected {
                        Label(track.label, systemImage: "checkmark")
                    } else {
                        Text(track.label)
                    }
                }
            }
            if kind == .sub {
                Divider()
                Button("자막 파일 불러오기…") { model.chooseSubtitleFile() }
            }
        } label: {
            Image(systemName: symbol)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help(title)
    }

    private var sidebar: some View {
        List {
            Section("재생 목록") {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                    Button {
                        model.show(index)
                    } label: {
                        HStack {
                            Image(systemName: index == model.index ? "play.fill" : "film")
                                .foregroundStyle(index == model.index ? Color.accentColor : .secondary)
                            Text(item.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(item.formattedSize)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Section {
                if model.reads.isEmpty {
                    Text("재생하면 FFmpeg가 요청하는 위치가 여기에 나타나요")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.reads) { read in
                    HStack {
                        Text("Range: bytes=\(read.offset)-")
                            .font(.caption.monospaced())
                        Spacer()
                        Text(read.at.formatted(date: .omitted, time: .standard))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("최근 읽기 요청")
            } footer: {
                Text("파일을 받지 않고, FFmpeg가 필요한 위치만 \(model.provider.isLocal ? "디스크에서" : "SFTP로") 읽어요. 임시 파일도 없어요.")
            }
        }
        .listStyle(.sidebar)
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(seconds)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// A view backed by a Metal layer for mpv to draw into.
private struct MPVVideoView: NSViewRepresentable {
    let attach: (CAMetalLayer) -> Void

    func makeNSView(context: Context) -> VideoHostView {
        let view = VideoHostView()
        attach(view.metalLayer)
        return view
    }

    func updateNSView(_ view: VideoHostView, context: Context) {}

    final class VideoHostView: NSView {
        let metalLayer = FlickerFreeMetalLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            metalLayer.framebufferOnly = true
            metalLayer.backgroundColor = NSColor.black.cgColor
            layer = metalLayer
            wantsLayer = true
        }

        required init?(coder: NSCoder) {
            fatalError("not used")
        }

        override func layout() {
            super.layout()
            let scale = window?.backingScaleFactor ?? 2
            metalLayer.contentsScale = scale
            metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        }
    }
}

/// MoltenVK sometimes sets the drawable to 1×1 to finish a frame, which
/// flickers; ignore that (mpv-player/mpv#13651).
private nonisolated final class FlickerFreeMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }
}
