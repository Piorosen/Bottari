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

    /// Files bigger than this open in Quick Look instead.
    static let sizeLimit: Int64 = 5 * 1024 * 1024

    let provider: any FileProvider
    let site: SavedSite?
    let item: FileItem
    let language: String?
    private let file: EditedFile

    var text = ""
    /// Bumped whenever the text is replaced wholesale (load, reload, merge),
    /// so the text view knows to take it.
    private(set) var revision = 0
    private(set) var phase: Phase = .loading
    var format: TextFormat { file.format }
    private(set) var isDirty = false
    private(set) var isSaving = false
    private(set) var savedAt: Date?
    var conflict: EditedFile.Conflict?
    /// The outcome of the last save, or a problem to show.
    var notice: String?
    var cursor = (line: 1, column: 1)

    /// Run on the server after each save, e.g. `nginx -t`; a failure puts the previous version back.
    var postSaveCommand: String {
        didSet { UserDefaults.standard.set(postSaveCommand, forKey: commandKey) }
    }

    /// When the server's copy was last changed, as of opening or the last save.
    var remoteModified: Date? { file.remoteModified }
    private let commandKey: String

    init(context: ViewerContext) {
        provider = context.provider
        site = context.site
        item = context.item
        file = EditedFile(provider: context.provider, item: context.item)
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
            text = try await file.open(sizeLimit: Self.sizeLimit)
            revision += 1
            isDirty = false
            phase = .ready
        } catch EditedFile.OpenError.tooLarge(let size) {
            phase = .failed(String(localized: "파일이 너무 큽니다 (\(ByteFormat.string(size))). 빠른 미리보기를 사용하십시오."))
        } catch EditedFile.OpenError.notText {
            phase = .failed(String(localized: "텍스트 파일이 아닙니다."))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Saving

    /// Uploads the text, unless the server's copy changed since it was opened
    /// (then `conflict` is set).
    func save() async {
        await save(over: nil)
    }

    /// Uploads the text; over `newer`, that overwrites the server's copy it found.
    private func save(over newer: EditedFile.Conflict?) async {
        guard !isReadOnly else {
            notice = String(localized: "읽기 전용 서버에는 저장할 수 없습니다.")
            return
        }
        // Typing goes on while the upload runs; only what was sent counts as saved.
        let sending = text
        isSaving = true
        defer { isSaving = false }
        do {
            switch try await file.save(sending, over: newer, check: postSaveCheck) {
            case .unencodable:
                notice = String(localized: "\(format.label)로 저장할 수 없는 문자가 있습니다.")
            case .conflict(let found):
                conflict = found
            case .checkFailed(let error, restoreError: nil):
                notice = String(localized: "검사에 실패하여 서버 파일을 이전 버전으로 되돌렸습니다. 편집한 내용은 유지됩니다.\n\(error.localizedDescription)")
            case .checkFailed(_, restoreError: let error?):
                notice = String(localized: "검사에 실패했으며 이전 버전으로 되돌릴 수 없습니다: \(error.localizedDescription)")
            case .saved:
                isDirty = text != sending
                conflict = nil
                savedAt = Date()
            }
        } catch {
            notice = String(localized: "저장할 수 없습니다: \(error.localizedDescription)")
        }
    }

    /// The post-save command, when there is one and the server can run it.
    private var postSaveCheck: (@Sendable () async throws -> Void)? {
        let command = postSaveCommand.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty, let server = provider as? SFTPFileProvider, server.canRunCommands else { return nil }
        return { _ = try await server.run(command) }
    }

    // MARK: - Settling a conflict

    func reloadServerVersion() async {
        conflict = nil
        await load()
    }

    /// Saves over the server's newer copy, keeping that copy on the Mac
    /// first: it may hold someone else's work.
    func overwriteServerVersion() async {
        guard let conflict else { return }
        let replaced = file.keepCopy(of: conflict, in: URL.applicationSupportDirectory.appending(path: "Bottari/Replaced"))
        self.conflict = nil
        await save(over: conflict)
        if let replaced, notice == nil {
            notice = String(localized: "덮어쓴 서버 쪽 내용은 \(replaced.path(percentEncoded: false))에 보관했습니다.")
        }
    }

    func saveMerged() async {
        guard let conflict, let merged = conflict.merged else { return }
        text = merged
        revision += 1
        self.conflict = nil
        await save(over: conflict)
    }
}
