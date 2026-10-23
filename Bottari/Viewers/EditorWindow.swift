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

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 0) {
                    if let conflict = model.conflict {
                        conflictBanner(conflict)
                        Rectangle().fill(Palette.line).frame(height: 1)
                    }
                    if let notice = model.notice {
                        noticeBanner(notice)
                        Rectangle().fill(Palette.line).frame(height: 1)
                    }
                    content
                    Rectangle().fill(Palette.line).frame(height: 1)
                    statusBar
                }
                .overlay(alignment: .top) {
                    if model.site?.tag == .prod {
                        Rectangle().fill(SavedSite.Tag.prod.color).frame(height: 3)
                    }
                }
                .card()
                sidePanel
                    .frame(width: 300)
            }
            .padding([.horizontal, .bottom], 12)
        }
        .background(Palette.background)
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

    private var placeName: String {
        model.site?.name ?? (model.provider.isLocal ? "Mac" : model.provider.displayName)
    }

    private var header: some View {
        HStack(spacing: 10) {
            BackButton(title: "목록으로") { NSApp.keyWindow?.performClose(nil) }
                .buttonStyle(PanelButtonStyle())
                .fixedSize()
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(model.site?.tag?.color ?? Color.secondary.opacity(0.4))
                    .frame(width: 3, height: 16)
                Text(model.item.name).font(.ui(.callout, weight: .semibold))
                Text(placeName).font(.themeMono(.caption)).foregroundStyle(.secondary)
                if model.isDirty {
                    Circle().fill(Palette.text.opacity(0.7)).frame(width: 6, height: 6)
                        .help("저장 안 된 변경")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Palette.panel, in: .rect(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.line))
            if model.isReadOnly {
                Label("읽기 전용", systemImage: "lock.fill")
                    .font(.ui(.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("외부 에디터로 열기") {
                ExternalEdits.shared.start(item: model.item, provider: model.provider, site: model.site)
            }
            .buttonStyle(PanelButtonStyle())
            .fixedSize()
            .disabled(model.phase != .ready)
            Button {
                Task { await save() }
            } label: {
                if model.isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Text("저장 ⌘S")
                }
            }
            .buttonStyle(PanelButtonStyle(prominent: true))
            .fixedSize()
            .keyboardShortcut("s")
            .disabled(model.phase != .ready || model.isReadOnly || model.isSaving)
        }
        .padding(12)
    }

    /// What saving does, the command after it, and other files open elsewhere.
    private var sidePanel: some View {
        ScrollView {
            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("저장할 때 일어나는 일").font(.ui(.body, weight: .semibold))
                    step("원격 수정 시각 · 크기 확인", model.remoteModified.map { "연 시각 \($0.formatted(date: .omitted, time: .shortened)) 와 비교" })
                    step("임시 이름으로 업로드", model.item.path.partialWritePath.string)
                    step("원래 이름으로 바꾸기", "rename 이라 중간에 끊겨도 원본은 그대로")
                    if !model.postSaveCommand.isEmpty {
                        step("검사 명령 실행", model.postSaveCommand)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()

                if model.canRunCommands {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("저장한 뒤 명령 실행").font(.ui(.body, weight: .semibold))
                        TextField("예: sudo nginx -t && sudo systemctl reload nginx", text: $model.postSaveCommand, axis: .vertical)
                            .lineLimit(2...4)
                            .designField(mono: true)
                        Text("검사가 실패하면 방금 올린 파일을 이전 버전으로 되돌려요. 이 파일에만 적용돼요.")
                            .font(.ui(.caption))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()
                }

                if !ExternalEdits.shared.sessions.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("외부 에디터에서 편집 중").font(.ui(.body, weight: .semibold))
                        ForEach(ExternalEdits.shared.sessions) { session in
                            HStack(spacing: 8) {
                                StatusDot(on: !session.blockedByServerChange, color: session.blockedByServerChange ? .orange : Color(light: 0x0F7C5A, dark: 0x3CC48E))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(session.item.name).font(.ui(.callout, weight: .semibold))
                                    Text("\(session.provider.displayName) · \(session.status)")
                                        .font(.themeMono(.caption2))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .well()
                        }
                        Text("임시 폴더에 받아 두고, 저장을 감지하면 자동으로 올려요.")
                            .font(.ui(.caption))
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()
                }
            }
        }
        .scrollIndicators(.never)
    }

    private func step(_ title: String, _ detail: String?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .strokeBorder(Palette.line, lineWidth: 1.5)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.ui(.callout))
                if let detail {
                    Text(detail).font(.themeMono(.caption2)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
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
                .font(.ui(.callout, weight: .semibold))
                .foregroundStyle(.orange)
            if let modified = conflict.modified {
                Text("서버 쪽 수정 시각 \(modified.formatted(date: .omitted, time: .shortened))")
                    .font(.ui(.caption))
                    .foregroundStyle(.secondary)
            }
            if conflict.merged != nil {
                Text("서로 다른 줄을 고쳤어요. 둘 다 반영해서 저장할 수 있어요.")
                    .font(.ui(.caption))
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
        .background(Color.orange.opacity(0.08))
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
        .font(.ui(.callout))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            Text("\(placeName):\(model.item.path.string)")
                .lineLimit(1)
                .truncationMode(.head)
            Text(model.format.label)
            if let language = model.language {
                Text(language)
            }
            Spacer()
            Text((model.isDirty ? "저장 안 된 변경 · " : model.savedAt.map { "저장됨 \($0.formatted(date: .omitted, time: .shortened)) · " } ?? "") + "줄 \(model.cursor.line), 칸 \(model.cursor.column)")
                .foregroundStyle(model.isDirty ? Color.orange : .secondary)
        }
        .font(.themeMono(.caption))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Palette.panel2)
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
                    .font(.ui(.headline))
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
                            .font(.themeMono(.body))
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
