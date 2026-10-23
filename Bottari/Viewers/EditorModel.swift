import BottariCore
import BottariEditor
import BottariSFTP
import Foundation
import Observation

/// One text file being edited, from the Mac or a server.
@Observable
final class EditorModel {
    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    /// The server's copy changed while it was being edited.
    struct Conflict {
        let theirs: String
        let modified: Date?
        /// Both edits combined, when they touched different lines.
        let merged: String?
    }

    /// Files bigger than this open in Quick Look instead.
    static let sizeLimit: Int64 = 5 * 1024 * 1024

    let provider: any FileProvider
    let site: SavedSite?
    let item: FileItem
    let language: String?

    var text = ""
    /// Bumped whenever the text is replaced wholesale (load, reload, merge),
    /// so the text view knows to take it.
    private(set) var revision = 0
    private(set) var phase: Phase = .loading
    private(set) var format = TextFormat()
    private(set) var isDirty = false
    private(set) var isSaving = false
    private(set) var savedAt: Date?
    var conflict: Conflict?
    /// The outcome of the last save, or a problem to show.
    var notice: String?
    var cursor = (line: 1, column: 1)

    /// Run on the server after each save, e.g. `nginx -t`; a failure puts the previous version back.
    var postSaveCommand: String {
        didSet { UserDefaults.standard.set(postSaveCommand, forKey: commandKey) }
    }

    /// The text as last opened or saved: the base for merging and for undoing a failed check.
    @ObservationIgnored private var savedText = ""
    @ObservationIgnored private var savedData = Data()
    /// When the server's copy was last changed, as of opening or the last save.
    @ObservationIgnored private(set) var remoteModified: Date?
    @ObservationIgnored private var remoteSize: Int64?
    private let commandKey: String

    init(context: ViewerContext) {
        provider = context.provider
        site = context.site
        item = context.item
        language = SyntaxHighlighting.language(forFileNamed: context.item.name)
        commandKey = "editor.postSave.\(context.provider.locationID)\(context.item.path.string)"
        postSaveCommand = UserDefaults.standard.string(forKey: commandKey) ?? ""
    }

    var isReadOnly: Bool { site?.readOnly == true }
    var needsConfirmation: Bool { site?.confirmsWrites == true }
    var canRunCommands: Bool { (provider as? SFTPFileProvider)?.canRunCommands == true }

    func markEdited() {
        isDirty = true
        notice = nil
    }

    // MARK: - Loading

    func load() async {
        phase = .loading
        do {
            let current = try await provider.stat(item.path)
            if let size = current.size, size > Self.sizeLimit {
                phase = .failed("\(ByteFormat.string(size))라서 편집기로 열지 않아요. 빠른 미리보기를 쓰세요.")
                return
            }
            let data = try await provider.readData(item.path)
            guard let (decoded, format) = TextCodec.decode(data) else {
                phase = .failed("텍스트 파일이 아니에요.")
                return
            }
            replaceText(decoded, data: data)
            self.format = format
            remoteModified = current.modified
            remoteSize = current.size
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func replaceText(_ newText: String, data: Data) {
        text = newText
        savedText = newText
        savedData = data
        revision += 1
        isDirty = false
    }

    // MARK: - Saving

    /// Uploads the text, unless the server's copy changed since it was opened
    /// (then `conflict` is set) or `force` says to overwrite it anyway.
    func save(force: Bool = false) async {
        guard !isReadOnly else {
            notice = "읽기 전용으로 연 서버라 저장할 수 없어요."
            return
        }
        guard let data = TextCodec.encode(text, as: format) else {
            notice = "\(format.label)로는 저장할 수 없는 글자가 있어요."
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            if !force {
                let current = try await provider.stat(item.path)
                if current.modified != remoteModified || current.size != remoteSize {
                    let theirs = TextCodec.decode(try await provider.readData(item.path))?.text ?? ""
                    let merged: String? = switch ThreeWayMerge.merge(base: savedText, mine: text, theirs: theirs) {
                    case .merged(let text): text
                    case .conflict: nil
                    }
                    conflict = Conflict(theirs: theirs, modified: current.modified, merged: merged)
                    return
                }
            }
            let previous = savedData
            try await provider.write(item.path, data: data)
            if let message = await runCheck(restoring: previous) {
                notice = message
                await refreshRemoteState()
                return
            }
            savedText = text
            savedData = data
            isDirty = false
            conflict = nil
            savedAt = Date()
            await refreshRemoteState()
        } catch {
            notice = "저장하지 못했어요: \(error.localizedDescription)"
        }
    }

    /// Runs the post-save command; on failure puts `previous` back and says why.
    private func runCheck(restoring previous: Data) async -> String? {
        let command = postSaveCommand.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty, let server = provider as? SFTPFileProvider, server.canRunCommands else { return nil }
        do {
            _ = try await server.run(command)
            return nil
        } catch {
            do {
                try await provider.write(item.path, data: previous)
                return "검사가 실패해서 이전 버전으로 되돌렸어요. 편집한 내용은 그대로 있어요.\n\(error.localizedDescription)"
            } catch {
                return "검사가 실패했고, 이전 버전으로 되돌리지도 못했어요: \(error.localizedDescription)"
            }
        }
    }

    private func refreshRemoteState() async {
        if let current = try? await provider.stat(item.path) {
            remoteModified = current.modified
            remoteSize = current.size
        }
    }

    // MARK: - Settling a conflict

    func reloadServerVersion() async {
        conflict = nil
        await load()
    }

    func overwriteServerVersion() async {
        conflict = nil
        await save(force: true)
    }

    func saveMerged() async {
        guard let conflict, let merged = conflict.merged else { return }
        text = merged
        revision += 1
        self.conflict = nil
        await save(force: true)
    }
}
