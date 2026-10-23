import AppKit
import BottariCore
import BottariEditor
import BottariSFTP
import SwiftUI

struct EditorWindow: View {
    let contextID: UUID
    @State private var model: EditorModel?

    var body: some View {
        Group {
            if let model {
                EditorView(model: model)
            } else {
                ContentUnavailableView("파일을 열 수 없어요", systemImage: "doc.text")
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .onAppear {
            guard model == nil, let context = Viewers.context(contextID) else { return }
            let editor = EditorModel(context: context)
            model = editor
            Task { await editor.load() }
        }
        .onDisappear {
            Viewers.close(contextID)
        }
    }
}

private struct EditorView: View {
    @Bindable var model: EditorModel
    @State private var confirmingSave = false
    @State private var showsDiff = false
    @State private var showsCommand = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let conflict = model.conflict {
                conflictBanner(conflict)
                Divider()
            }
            if let notice = model.notice {
                noticeBanner(notice)
                Divider()
            }
            content
            Divider()
            statusBar
        }
        .navigationTitle(model.item.name)
        .background(WindowCloseGuard(isDirty: model.isDirty, save: { await save() }))
        .confirmationDialog("운영 서버의 파일을 저장할까요?", isPresented: $confirmingSave) {
            Button("저장", role: .destructive) { Task { await model.save() } }
        } message: {
            Text("\(model.site?.name ?? "") · \(model.item.path.string)")
        }
        .sheet(isPresented: $showsDiff) {
            if let conflict = model.conflict {
                DiffSheet(theirs: conflict.theirs, mine: model.text)
            }
        }
    }

    private func save() async {
        if model.needsConfirmation {
            confirmingSave = true
        } else {
            await model.save()
        }
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
            Text(model.item.path.string)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
            if model.isReadOnly {
                Label("읽기 전용", systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
            }
            if model.canRunCommands {
                Button {
                    showsCommand.toggle()
                } label: {
                    Label("저장한 뒤 실행", systemImage: model.postSaveCommand.isEmpty ? "terminal" : "terminal.fill")
                }
                .popover(isPresented: $showsCommand) { commandPopover }
            }
            Button("외부 에디터로 열기") {
                ExternalEdits.shared.start(item: model.item, provider: model.provider, site: model.site)
            }
            .disabled(model.phase != .ready)
            Button {
                Task { await save() }
            } label: {
                if model.isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Text("저장")
                }
            }
            .keyboardShortcut("s")
            .disabled(model.phase != .ready || model.isReadOnly || model.isSaving)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var commandPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("저장한 뒤 서버에서 실행")
                .font(.headline)
            TextField("예: nginx -t", text: $model.postSaveCommand)
                .font(.body.monospaced())
                .frame(width: 320)
            Text("명령이 실패하면 방금 올린 파일을 이전 버전으로 되돌려요. 이 파일에만 적용돼요.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 350)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView("여는 중…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView("열 수 없어요", systemImage: "doc.text", description: Text(message))
        case .ready:
            CodeTextView(
                text: $model.text,
                revision: model.revision,
                language: model.language,
                isEditable: !model.isReadOnly,
                onEdit: { model.markEdited() },
                onCursorMove: { model.cursor = ($0, $1) }
            )
        }
    }

    private func conflictBanner(_ conflict: EditorModel.Conflict) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("편집하는 사이 서버에서 이 파일이 바뀌었어요", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
            if let modified = conflict.modified {
                Text("서버 쪽 수정 시각 \(modified.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if conflict.merged != nil {
                Text("서로 다른 줄을 고쳤어요. 둘 다 반영해서 저장할 수 있어요.")
                    .font(.caption)
            }
            HStack {
                Button("차이 보기") { showsDiff = true }
                Button("서버 버전 다시 열기") { Task { await model.reloadServerVersion() } }
                Button("내 버전으로 덮어쓰기", role: .destructive) { Task { await model.overwriteServerVersion() } }
                if conflict.merged != nil {
                    Button("둘 다 반영하고 저장") { Task { await model.saveMerged() } }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08))
    }

    private func noticeBanner(_ notice: String) -> some View {
        HStack(alignment: .top) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.secondary)
            Text(notice)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("닫기") { model.notice = nil }
                .buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            Text(model.format.label)
            Text("줄 \(model.cursor.line), 칸 \(model.cursor.column)")
                .monospacedDigit()
            if let language = model.language {
                Text(language)
            }
            Spacer()
            if model.isDirty {
                Text("저장 안 됨")
                    .foregroundStyle(.orange)
            } else if let savedAt = model.savedAt {
                Text("저장됨 \(savedAt.formatted(date: .omitted, time: .shortened))")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}

/// The server's version against the one being edited.
private struct DiffSheet: View {
    let theirs: String
    let mine: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("서버 버전 → 내 버전")
                    .font(.headline)
                Spacer()
                Button("닫기") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(LineDiff.lines(from: theirs, to: mine).enumerated()), id: \.offset) { _, line in
                        Text((line.kind == .added ? "+ " : line.kind == .removed ? "- " : "  ") + line.text)
                            .font(.body.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .background(line.kind == .added ? Color.green.opacity(0.12) : line.kind == .removed ? Color.red.opacity(0.12) : .clear)
                    }
                }
            }
        }
        .frame(width: 640, height: 460)
    }
}

/// Asks before closing a window with unsaved changes. SwiftUI owns the
/// window's delegate, so this stands in front of it and passes everything else on.
private struct WindowCloseGuard: NSViewRepresentable {
    let isDirty: Bool
    let save: () async -> Void

    func makeCoordinator() -> Proxy {
        Proxy()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window, !(window.delegate is Proxy) else { return }
            context.coordinator.original = window.delegate
            window.delegate = context.coordinator
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.isDirty = isDirty
        context.coordinator.save = save
        view.window?.isDocumentEdited = isDirty
    }

    final class Proxy: NSObject, NSWindowDelegate {
        // Read from AppKit's message forwarding, which is not on the main actor's books.
        nonisolated(unsafe) weak var original: NSWindowDelegate?
        var isDirty = false
        var save: () async -> Void = {}

        func windowShouldClose(_ window: NSWindow) -> Bool {
            guard isDirty else { return original?.windowShouldClose?(window) ?? true }
            let alert = NSAlert()
            alert.messageText = "저장하지 않은 변경 사항이 있어요"
            alert.informativeText = "닫기 전에 저장할까요?"
            alert.addButton(withTitle: "저장")
            alert.addButton(withTitle: "취소")
            alert.addButton(withTitle: "저장 안 함")
            alert.beginSheetModal(for: window) { response in
                switch response {
                case .alertFirstButtonReturn:
                    Task {
                        await self.save()
                        if !self.isDirty { window.close() }
                    }
                case .alertThirdButtonReturn:
                    self.isDirty = false
                    window.close()
                default:
                    break
                }
            }
            return false
        }

        nonisolated override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (original?.responds(to: selector) ?? false)
        }

        nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
            original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
        }
    }
}
