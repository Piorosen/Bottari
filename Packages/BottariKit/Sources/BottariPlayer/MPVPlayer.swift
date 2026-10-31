import BottariCore
import Foundation
import Libmpv
import QuartzCore

/// What the player shows: position, tracks, decoding.
public struct PlayerState: Equatable, Sendable {
    public struct Track: Equatable, Identifiable, Sendable {
        public enum Kind: String, Sendable { case video, audio, sub }
        public let id: Int
        public let kind: Kind
        public let title: String?
        public let language: String?
        public let codec: String?
        public let isSelected: Bool
        public let isExternal: Bool

        public var label: String {
            [title, language, codec].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ").ifEmpty(String(localized: "트랙 \(id)"))
        }
    }

    public var position: Double = 0
    public var duration: Double = 0
    public var isPaused = true
    /// Waiting for data, e.g. right after a seek on a slow server.
    public var isBuffering = false
    public var reachedEnd = false
    public var tracks: [Track] = []
    /// "videotoolbox" when the Mac's hardware decodes, "no" for software decoding.
    public var hardwareDecoder: String?
    public var videoCodec: String?
    public var videoSize: CGSize?
    public var volume: Double = 100
    public var error: String?

    public init() {}
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

/// libmpv (FFmpeg inside) playing files straight from providers through
/// `bottari://` streams. Give it a Metal layer to draw into, or none to play
/// without picture (for tests).
public final class MPVPlayer: @unchecked Sendable {
    public private(set) var state = PlayerState()
    /// Called on the main queue whenever `state` changes.
    public var onChange: (@MainActor (PlayerState) -> Void)?
    /// The stream mpv is reading, for the "recent reads" list.
    public private(set) var stream: ProviderStream?
    /// Called with each offset the stream starts reading from.
    public var onRead: (@Sendable (Int64) -> Void)?

    private var handle: OpaquePointer?
    private let events = DispatchQueue(label: "io.github.piorosen.bottari.mpv-events")
    private let lock = NSLock()
    private var pendingStreams: [String: ProviderStream] = [:]

    public init(layer: CAMetalLayer?) throws {
        setlocale(LC_NUMERIC, "C")
        guard let handle = mpv_create() else { throw PlayerError(String(localized: "mpv를 시작할 수 없습니다")) }
        self.handle = handle
        if let layer {
            // mpv draws into the layer through MoltenVK; "wid" is the layer's address.
            set("wid", int64: Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque())))
            set("vo", "gpu-next")
            set("gpu-api", "vulkan")
            set("gpu-context", "moltenvk")
            set("hwdec", "videotoolbox")
        } else {
            set("vo", "null")
            set("ao", "null")
        }
        set("ytdl", "no")
        // None of mpv's own Lua scripts (on-screen controls, stats, console …):
        // Bottari draws its own controls, and LuaJIT writes code into memory at
        // run time, which the hardened runtime of a signed build kills the app for.
        // Unknown names in older or newer mpv versions are simply refused.
        set("config", "no")
        set("load-scripts", "no")
        for script in ["osc", "load-stats-overlay", "load-console", "load-osd-console", "load-auto-profiles",
                       "load-select", "load-commands", "load-context-menu", "load-positioning"] {
            set(script, "no")
        }
        set("keep-open", "yes")
        set("idle", "yes")
        set("subs-match-os-language", "yes")
        set("subs-fallback", "yes")
        set("input-default-bindings", "no")
        set("cache", "yes")
        set("demuxer-max-bytes", "64MiB")
        guard mpv_initialize(handle) >= 0 else {
            mpv_terminate_destroy(handle)
            self.handle = nil
            throw PlayerError(String(localized: "mpv를 초기화할 수 없습니다"))
        }
        mpv_stream_cb_add_ro(handle, "bottari", Unmanaged.passUnretained(self).toOpaque(), openStream)
        for (name, format) in [
            ("time-pos", MPV_FORMAT_DOUBLE), ("duration", MPV_FORMAT_DOUBLE), ("pause", MPV_FORMAT_FLAG),
            ("paused-for-cache", MPV_FORMAT_FLAG), ("eof-reached", MPV_FORMAT_FLAG), ("track-list/count", MPV_FORMAT_INT64),
            ("hwdec-current", MPV_FORMAT_STRING), ("video-codec", MPV_FORMAT_STRING), ("width", MPV_FORMAT_INT64),
            ("height", MPV_FORMAT_INT64), ("volume", MPV_FORMAT_DOUBLE), ("aid", MPV_FORMAT_STRING), ("sid", MPV_FORMAT_STRING),
        ] {
            mpv_observe_property(handle, 0, name, format)
        }
        mpv_set_wakeup_callback(handle, { context in
            guard let context else { return }
            Unmanaged<MPVPlayer>.fromOpaque(context).takeUnretainedValue().drainEvents()
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit {
        if let handle { mpv_terminate_destroy(handle) }
    }

    /// Stops playback and frees mpv. Call before letting go of the player.
    public func shutDown() {
        lock.lock()
        let handle = self.handle
        self.handle = nil
        lock.unlock()
        stream?.cancel()
        if let handle {
            mpv_set_wakeup_callback(handle, nil, nil)
            mpv_terminate_destroy(handle)
        }
    }

    // MARK: - Control

    /// Plays `item`, reading it from `provider` as mpv asks for bytes.
    public func play(_ item: FileItem, from provider: any FileProvider, startingAt seconds: Double = 0) {
        let token = UUID().uuidString
        let stream = ProviderStream(provider: provider, path: item.path, size: item.size)
        stream.onRequest = onRead
        lock.lock()
        pendingStreams[token] = stream
        lock.unlock()
        state = PlayerState()
        publish()
        // In mpv's option list "," and "[" are syntax; %<bytes>% quotes the
        // name whatever it holds ("[SubsPlease] Show - 01.mkv", "Movie, Part 1").
        var options = "force-media-title=%\(item.name.utf8.count)%\(item.name)"
        if seconds > 0 { options += ",start=\(seconds)" }
        command("loadfile", "bottari://\(token)", "replace", "-1", options)
    }

    public func setPaused(_ paused: Bool) {
        set("pause", flag: paused)
    }

    public func togglePause() {
        setPaused(!state.isPaused)
    }

    public func seek(to seconds: Double) {
        command("seek", String(seconds), "absolute")
    }

    public func seek(by seconds: Double) {
        command("seek", String(seconds), "relative")
    }

    public func setVolume(_ volume: Double) {
        set("volume", double: volume)
    }

    /// Selects a track; nil turns that kind off (subtitles).
    public func select(_ kind: PlayerState.Track.Kind, id: Int?) {
        let property = kind == .audio ? "aid" : kind == .sub ? "sid" : "vid"
        set(property, id.map(String.init) ?? "no")
    }

    /// Loads a subtitle file from the Mac.
    public func addSubtitle(_ url: URL) {
        command("sub-add", url.path, "select")
    }

    // MARK: - mpv plumbing

    fileprivate func takeStream(for uri: String) -> ProviderStream? {
        let token = String(uri.dropFirst("bottari://".count))
        lock.lock()
        defer { lock.unlock() }
        guard let stream = pendingStreams.removeValue(forKey: token) else { return nil }
        self.stream = stream
        return stream
    }

    private func set(_ name: String, _ value: String) {
        guard let handle else { return }
        mpv_set_option_string(handle, name, value)
    }

    private func set(_ name: String, int64 value: Int64) {
        guard let handle else { return }
        var value = value
        mpv_set_option(handle, name, MPV_FORMAT_INT64, &value)
    }

    private func set(_ name: String, flag: Bool) {
        guard let handle else { return }
        var value: Int32 = flag ? 1 : 0
        mpv_set_property(handle, name, MPV_FORMAT_FLAG, &value)
    }

    private func set(_ name: String, double value: Double) {
        guard let handle else { return }
        var value = value
        mpv_set_property(handle, name, MPV_FORMAT_DOUBLE, &value)
    }

    private func command(_ arguments: String...) {
        guard let handle else { return }
        var pointers = arguments.map { strdup($0) } + [nil]
        defer { pointers.forEach { free($0) } }
        pointers.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) {
                _ = mpv_command_async(handle, 0, $0)
            }
        }
    }

    private func string(_ name: String) -> String? {
        guard let handle, let value = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(value) }
        return String(cString: value)
    }

    private func drainEvents() {
        events.async { [weak self] in
            guard let self else { return }
            var changed = false
            while true {
                self.lock.lock()
                let handle = self.handle
                self.lock.unlock()
                guard let handle, let event = mpv_wait_event(handle, 0)?.pointee, event.event_id != MPV_EVENT_NONE else { break }
                switch event.event_id {
                case MPV_EVENT_PROPERTY_CHANGE:
                    if let property = event.data?.assumingMemoryBound(to: mpv_event_property.self).pointee {
                        self.apply(property)
                        changed = true
                    }
                case MPV_EVENT_END_FILE:
                    if let end = event.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee, end.reason == MPV_END_FILE_REASON_ERROR {
                        self.state.error = String(localized: "재생할 수 없습니다: \(String(cString: mpv_error_string(end.error)))")
                        changed = true
                    }
                case MPV_EVENT_SHUTDOWN:
                    return
                default:
                    break
                }
            }
            if changed { self.publish() }
        }
    }

    private func apply(_ property: mpv_event_property) {
        let name = String(cString: property.name)
        let data = property.data
        func double() -> Double? { property.format == MPV_FORMAT_DOUBLE ? data?.assumingMemoryBound(to: Double.self).pointee : nil }
        func flag() -> Bool? { property.format == MPV_FORMAT_FLAG ? data.map { $0.assumingMemoryBound(to: Int32.self).pointee != 0 } : nil }
        func text() -> String? {
            guard property.format == MPV_FORMAT_STRING, let pointer = data?.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee else { return nil }
            return String(cString: pointer)
        }
        switch name {
        case "time-pos": state.position = double() ?? state.position
        case "duration": state.duration = double() ?? 0
        case "pause": state.isPaused = flag() ?? state.isPaused
        case "paused-for-cache": state.isBuffering = flag() ?? false
        case "eof-reached": state.reachedEnd = flag() ?? false
        case "hwdec-current": state.hardwareDecoder = text()
        case "video-codec": state.videoCodec = text()
        case "volume": state.volume = double() ?? state.volume
        case "width", "height":
            if let width = Double(string("width") ?? ""), let height = Double(string("height") ?? "") {
                state.videoSize = CGSize(width: width, height: height)
            }
        case "track-list/count", "aid", "sid":
            state.tracks = readTracks()
        default:
            break
        }
    }

    private func readTracks() -> [PlayerState.Track] {
        let count = Int(string("track-list/count") ?? "") ?? 0
        return (0..<count).compactMap { index in
            let prefix = "track-list/\(index)/"
            guard let id = Int(string(prefix + "id") ?? ""), let kind = PlayerState.Track.Kind(rawValue: string(prefix + "type") ?? "") else { return nil }
            return PlayerState.Track(
                id: id,
                kind: kind,
                title: string(prefix + "title"),
                language: string(prefix + "lang"),
                codec: string(prefix + "codec"),
                isSelected: string(prefix + "selected") == "yes",
                isExternal: string(prefix + "external") == "yes"
            )
        }
    }

    private func publish() {
        let snapshot = state
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.onChange?(snapshot)
            }
        }
    }
}

public struct PlayerError: LocalizedError {
    public let message: String
    init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

// MARK: - Stream callbacks (C function pointers, so no captures)

private func openStream(_ userData: UnsafeMutableRawPointer?, _ uri: UnsafeMutablePointer<CChar>?, _ info: UnsafeMutablePointer<mpv_stream_cb_info>?) -> Int32 {
    guard let userData, let uri, let info else { return MPV_ERROR_LOADING_FAILED.rawValue }
    let player = Unmanaged<MPVPlayer>.fromOpaque(userData).takeUnretainedValue()
    guard let stream = player.takeStream(for: String(cString: uri)) else { return MPV_ERROR_LOADING_FAILED.rawValue }
    info.pointee.cookie = Unmanaged.passRetained(stream).toOpaque()
    info.pointee.read_fn = { cookie, buffer, count in
        guard let cookie, let buffer else { return -1 }
        return Unmanaged<ProviderStream>.fromOpaque(cookie).takeUnretainedValue().read(into: buffer, count: Int(count))
    }
    info.pointee.seek_fn = { cookie, offset in
        guard let cookie else { return Int64(MPV_ERROR_GENERIC.rawValue) }
        return Unmanaged<ProviderStream>.fromOpaque(cookie).takeUnretainedValue().seek(to: offset)
    }
    info.pointee.size_fn = { cookie in
        guard let cookie else { return Int64(MPV_ERROR_UNSUPPORTED.rawValue) }
        return Unmanaged<ProviderStream>.fromOpaque(cookie).takeUnretainedValue().size ?? Int64(MPV_ERROR_UNSUPPORTED.rawValue)
    }
    info.pointee.cancel_fn = { cookie in
        guard let cookie else { return }
        Unmanaged<ProviderStream>.fromOpaque(cookie).takeUnretainedValue().cancel()
    }
    info.pointee.close_fn = { cookie in
        guard let cookie else { return }
        let stream = Unmanaged<ProviderStream>.fromOpaque(cookie).takeRetainedValue()
        stream.close()
    }
    return 0
}
