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
    var showsSidebar = true
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
        VStack(spacing: 0) {
            header
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 12) {
                    ZStack(alignment: .bottom) {
                        MPVVideoView { model.attach(to: $0) }
                        overlay
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        controls
                    }
                    .background(.black)
                    .clipShape(.rect(cornerRadius: 12))
                    .environment(\.colorScheme, .dark)
                    pipeline
                }
                if model.showsSidebar {
                    sidebar
                        .frame(width: 320)
                }
            }
            .padding([.horizontal, .bottom], 12)
        }
        .background(Palette.background)
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

    private var placeName: String {
        model.site?.name ?? (model.provider.isLocal ? "Mac" : model.provider.displayName)
    }

    private var audioCodec: String? {
        model.state.tracks.first { $0.kind == .audio && $0.isSelected }?.codec
    }

    private var header: some View {
        HStack(spacing: 12) {
            BackButton(title: "목록으로") { NSApp.keyWindow?.performClose(nil) }
                .buttonStyle(PanelButtonStyle())
                .fixedSize()
            VStack(alignment: .leading, spacing: 1) {
                Text(model.current?.name ?? "").font(.ui(.body, weight: .semibold))
                Text("\(placeName):\(model.current?.path.string ?? "")")
                    .font(.themeMono(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            let formats = [model.current?.path.pathExtension.uppercased(), model.state.videoCodec?.components(separatedBy: " ").first?.uppercased(), audioCodec?.capitalized]
                .compactMap { $0 }.filter { !$0.isEmpty }
            if !formats.isEmpty {
                MonoChip(text: formats.joined(separator: " · "))
            }
            if let size = model.state.videoSize {
                MonoChip(text: "\(Int(size.width))×\(Int(size.height))")
            }
            MonoChip(text: "libmpv · FFmpeg", highlighted: true)
            Button { model.showsSidebar.toggle() } label: { Image(systemName: "sidebar.right") }
                .buttonStyle(IconButtonStyle(isOn: model.showsSidebar))
                .help("재생 목록")
        }
        .padding(12)
    }

    /// How the bytes get from where the file is to the screen.
    private var pipeline: some View {
        let hardware = model.state.hardwareDecoder.map { $0 != "no" && !$0.isEmpty } ?? false
        let codec = model.state.videoCodec?.components(separatedBy: " ").first ?? "…"
        let stages: [(String, String, String?)] = [
            (placeName, model.provider.isLocal ? "이 Mac의 파일" : "\(model.provider.kindLabel) 서버", "read"),
            ("bottari:// 스트림", "mpv 스트림 콜백", "demux"),
            ("FFmpeg", "\(model.current?.path.pathExtension.uppercased() ?? "") → \(codec)", "decode"),
            (hardware ? "VideoToolbox" : "CPU 디코더", hardware ? "Mac 하드웨어" : "소프트웨어로 풀기", "render"),
            ("Metal 화면", "자막도 여기서 그림", nil),
        ]
        let lastRead = model.reads.first?.offset ?? 0
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("FFmpeg 으로 바로 읽어서 재생").font(.ui(.body, weight: .semibold))
                Text("파일을 받지 않고, FFmpeg가 필요한 위치만 \(model.provider.isLocal ? "디스크에서" : "SFTP로") 읽어요. 임시 파일도 없어요.")
                    .font(.ui(.caption))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 0) {
                ForEach(Array(stages.enumerated()), id: \.offset) { index, stage in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(stage.0).font(.ui(.caption, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.75)
                        Text(stage.1).font(.themeMono(.caption2)).foregroundStyle(.secondary).lineLimit(2).minimumScaleFactor(0.8)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.panel, in: .rect(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(index == 1 ? Color.themeAccent.opacity(0.6) : Palette.line))
                    if let link = stage.2 {
                        VStack(spacing: 2) {
                            Text(link).font(.themeMono(.caption2)).foregroundStyle(.secondary)
                            Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                        }
                        .frame(width: 46)
                    }
                }
            }
            HStack(spacing: 8) {
                stat("읽은 위치 / 전체", "\(ByteFormat.string(lastRead)) / \(model.current?.formattedSize ?? "—")")
                stat("디코더", "\(codec) · \(model.state.hardwareDecoder == nil ? "…" : hardware ? "VideoToolbox" : "CPU")")
                stat("읽기 요청", "\(model.reads.count)번")
                stat("임시 파일", "없음")
            }
        }
        .padding(14)
        .card()
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.ui(.caption)).foregroundStyle(.secondary)
            Text(value).font(.themeMono(.callout)).fontWeight(.semibold).lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .well()
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
                    .font(.ui(.callout))
            }
            .padding(16)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 10))
            .environment(\.colorScheme, .dark)
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            Slider(
                value: Binding(get: { scrubbing ?? model.state.position }, set: { scrubbing = $0 }),
                in: 0...max(model.state.duration, 1)
            ) { editing in
                if !editing, let target = scrubbing {
                    model.seek(to: target)
                    scrubbing = nil
                }
            }
            .controlSize(.small)
            HStack(spacing: 14) {
                Button { model.togglePause() } label: {
                    Image(systemName: model.state.isPaused ? "play.fill" : "pause.fill")
                        .frame(width: 18)
                }
                Button("−10s") { model.seek(by: -10) }
                Button("+10s") { model.seek(by: 10) }
                Text("\(timeText(scrubbing ?? model.state.position)) / \(timeText(model.state.duration))")
                    .font(.themeMono(.callout))
                Button { model.show(model.index - 1) } label: { Image(systemName: "backward.end.fill") }
                    .disabled(model.index == 0)
                Button { model.show(model.index + 1) } label: { Image(systemName: "forward.end.fill") }
                    .disabled(model.index >= model.items.count - 1)
                Spacer()
                trackMenu(.sub, title: "자막", symbol: "captions.bubble")
                trackMenu(.audio, title: "오디오", symbol: "speaker.wave.2")
                Slider(value: Binding(get: { model.state.volume }, set: { model.setVolume($0) }), in: 0...130)
                    .controlSize(.small)
                    .frame(width: 80)
                Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .help("전체 화면 (F)")
            }
            .font(.ui(.callout))
            .buttonStyle(.borderless)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.top, 30)
        .padding(.bottom, 12)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom))
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
        ScrollView {
            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("재생 목록").padding(.horizontal, 4)
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        Button {
                            model.show(index)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: index == model.index ? "play.fill" : "film")
                                    .foregroundStyle(index == model.index ? Color.themeAccent : .secondary)
                                    .frame(width: 56, height: 36)
                                    .background(Palette.panel2, in: .rect(cornerRadius: 6))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name).font(.ui(.callout, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                                    Text("\(placeName) · \(item.formattedSize)").font(.themeMono(.caption2)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(8)
                            .background(index == model.index ? Palette.selection : .clear, in: .rect(cornerRadius: 8))
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
                .card()

                VStack(alignment: .leading, spacing: 6) {
                    Text("FFmpeg 이 여는 것").font(.ui(.callout, weight: .semibold))
                    Text("컨테이너: MP4 · MOV · MKV · WebM · AVI · TS · FLV").font(.ui(.caption))
                    Text("코덱: H.264 · HEVC 10bit · AV1 · VP9 · ProRes · MPEG-4").font(.ui(.caption))
                    Text("자막: SRT · ASS (스타일 그대로) · PGS · 내장 자막").font(.ui(.caption))
                    Text("H.264 · HEVC 는 Mac 하드웨어(VideoToolbox)로 풀어서 배터리를 덜 써요.")
                        .font(.ui(.caption))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .well()

                VStack(alignment: .leading, spacing: 6) {
                    Text("최근 읽기 요청").font(.ui(.callout, weight: .semibold))
                    if model.reads.isEmpty {
                        Text("재생하면 FFmpeg가 요청하는 위치가 여기에 나타나요")
                            .font(.ui(.caption))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.reads.prefix(12)) { read in
                        HStack {
                            Text("bytes=\(read.offset)-").font(.themeMono(.caption2))
                            Spacer()
                            Text(read.at.formatted(date: .omitted, time: .standard))
                                .font(.themeMono(.caption2))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            }
        }
        .scrollIndicators(.never)
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
