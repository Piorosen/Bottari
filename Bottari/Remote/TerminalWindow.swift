import AppKit
import BottariCore
import BottariRemote
import BottariSFTP
import Observation
import SwiftUI

/// A shell on one server, over the pane's SSH connection.
@Observable
final class TerminalModel {
    enum Status: Equatable {
        case connecting
        case connected
        case closed(String?)
    }

    let provider: SFTPFileProvider
    let site: SavedSite?
    let folder: RemotePath
    private(set) var status: Status = .connecting
    private(set) var title: String
    private(set) var size = (columns: 120, rows: 32)
    /// Typing here also goes to every other terminal that has this on.
    var joinsBroadcast = false {
        didSet { TerminalBroadcast.shared.update(self) }
    }

    @ObservationIgnored private var session: TerminalSession?
    @ObservationIgnored weak var view: TerminalView?

    init(provider: SFTPFileProvider, site: SavedSite?, folder: RemotePath) {
        self.provider = provider
        self.site = site
        self.folder = folder
        title = "\(provider.endpoint.username)@\(provider.displayName)"
    }

    func connect() {
        session?.close()
        status = .connecting
        let session = provider.openTerminal(columns: size.columns, rows: size.rows, in: folder)
        self.session = session
        Task {
            var started = false
            for await event in session.events {
                switch event {
                case .output(let data):
                    if !started {
                        started = true
                        status = .connected
                    }
                    view?.feed(byteArray: ArraySlice(data))
                case .closed(let reason):
                    status = .closed(reason)
                }
            }
        }
    }

    /// Bytes the user typed: to this shell, and to the broadcast group if joined.
    func type(_ data: Data) {
        if joinsBroadcast {
            TerminalBroadcast.shared.send(data)
        } else {
            session?.send(data)
        }
    }

    fileprivate func receiveBroadcast(_ data: Data) {
        session?.send(data)
    }

    func run(_ command: String) {
        type(Data((command + "\n").utf8))
    }

    func resize(columns: Int, rows: Int) {
        size = (columns, rows)
        session?.resize(columns: columns, rows: rows)
    }

    func setTitle(_ title: String) {
        if !title.isEmpty { self.title = title }
    }

    func close() {
        joinsBroadcast = false
        session?.close()
        session = nil
    }
}

/// Terminals that take the same typing, for checking several servers at once.
final class TerminalBroadcast {
    static let shared = TerminalBroadcast()
    private var members: [ObjectIdentifier: () -> TerminalModel?] = [:]

    var count: Int { members.values.compactMap { $0() }.count }

    func update(_ model: TerminalModel) {
        if model.joinsBroadcast {
            members[ObjectIdentifier(model)] = { [weak model] in model }
        } else {
            members[ObjectIdentifier(model)] = nil
        }
    }

    func send(_ data: Data) {
        for member in members.values.compactMap({ $0() }) {
            member.receiveBroadcast(data)
        }
    }
}

/// Commands kept for one click, shared by all terminals.
enum TerminalSnippets {
    private static let key = "terminal.snippets"
    static let defaults = ["df -h", "free -h", "uptime", "sudo systemctl status nginx", "tail -n 100 -f /var/log/syslog", "docker ps"]

    static var all: [String] {
        get { UserDefaults.standard.stringArray(forKey: key) ?? defaults }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

struct TerminalWindow: View {
    let contextID: UUID
    @State private var model: TerminalModel?

    var body: some View {
        Group {
            if let model {
                TerminalScreen(model: model)
            } else {
                ContentUnavailableView("터미널을 열 수 없어요", systemImage: "terminal", description: Text("SSH 서버를 연 패인에서 열어 주세요."))
            }
        }
        .frame(minWidth: 640, minHeight: 400)
        .onAppear {
            guard model == nil, let context = Viewers.context(contextID), let server = context.provider as? SFTPFileProvider else { return }
            model = TerminalModel(provider: server, site: context.site, folder: context.item.path)
        }
        .onDisappear {
            model?.close()
            Viewers.close(contextID)
        }
    }
}

private struct TerminalScreen: View {
    @Bindable var model: TerminalModel
    @State private var showsSnippets = true
    @State private var snippets = TerminalSnippets.all
    @State private var newSnippet = ""

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                Divider()
                ZStack(alignment: .top) {
                    SwiftTermView(model: model)
                    if case .closed(let reason) = model.status {
                        disconnectedBanner(reason)
                    }
                }
                Divider()
                statusBar
            }
            if showsSnippets {
                Divider()
                snippetList
                    .frame(width: 240)
            }
        }
        .navigationTitle(model.title)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .foregroundStyle(model.site?.tag == .prod ? SavedSite.Tag.prod.color : .secondary)
            Text(model.provider.displayName)
                .font(.headline)
            if let tag = model.site?.tag {
                TagChip(tag: tag)
            }
            if let jumps = model.site?.proxyJump, !jumps.isEmpty {
                Text("via \(jumps.joined(separator: " → "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(model.folder.string)
                .font(.themeMono(.callout))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
            Button("이 폴더로 이동") {
                model.run("cd -- \(SFTPFileProvider.quote(model.folder.string))")
            }
            .help("패인에서 보던 폴더로 cd")
            Toggle(isOn: $model.joinsBroadcast) {
                Label("동시 입력", systemImage: "dot.radiowaves.left.and.right")
            }
            .toggleStyle(.button)
            .help("켜 둔 터미널 모두에 같은 입력을 보내요. 서버 여러 대를 점검할 때 써요.")
            Toggle(isOn: $showsSnippets) {
                Image(systemName: "sidebar.right")
            }
            .toggleStyle(.button)
            .help("명령 조각")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func disconnectedBanner(_ reason: String?) -> some View {
        HStack {
            Image(systemName: "bolt.horizontal.circle")
            Text(reason.map { "연결이 끊겼어요 · \($0)" } ?? "셸이 끝났어요")
            Spacer()
            Button("다시 연결") { model.connect() }
        }
        .padding(10)
        .background(.orange.opacity(0.9), in: .rect(cornerRadius: 8))
        .foregroundStyle(.white)
        .padding(10)
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(model.status == .connected ? Color.green : model.status == .connecting ? .yellow : .red)
                .frame(width: 7, height: 7)
            Text("\(model.provider.endpoint.username)@\(model.provider.endpoint.hostKeyID)")
            Text("SSH · UTF-8 · xterm-256color")
            Text("\(model.size.columns)×\(model.size.rows)")
                .monospacedDigit()
            Spacer()
            if model.joinsBroadcast {
                Text("동시 입력 중 · \(TerminalBroadcast.shared.count)개 세션")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private var snippetList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("명령 조각")
                .font(.headline)
                .padding(12)
            Text("누르면 실행해요")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
            List {
                ForEach(snippets, id: \.self) { snippet in
                    Button {
                        model.run(snippet)
                    } label: {
                        Text(snippet)
                            .font(.themeMono(.callout))
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("지우기", role: .destructive) {
                            snippets.removeAll { $0 == snippet }
                            TerminalSnippets.all = snippets
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            HStack {
                TextField("새 명령", text: $newSnippet)
                    .font(.themeMono(.callout))
                    .onSubmit(addSnippet)
                Button(action: addSnippet) { Image(systemName: "plus") }
                    .disabled(newSnippet.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
        }
    }

    private func addSnippet() {
        let snippet = newSnippet.trimmingCharacters(in: .whitespaces)
        guard !snippet.isEmpty, !snippets.contains(snippet) else { return }
        snippets.append(snippet)
        TerminalSnippets.all = snippets
        newSnippet = ""
    }
}

/// SwiftTerm's terminal, wired to the model.
private struct SwiftTermView: NSViewRepresentable {
    let model: TerminalModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero, font: ThemeStore.shared.monoNSFont(size: 13))
        view.terminalDelegate = context.coordinator
        view.optionAsMetaKey = true
        model.view = view
        model.connect()
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {}

    final class Coordinator: NSObject, TerminalViewDelegate {
        let model: TerminalModel

        init(model: TerminalModel) {
            self.model = model
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            model.type(Data(data))
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            model.resize(columns: newCols, rows: newRows)
        }

        func setTerminalTitle(source: TerminalView, title: String) {
            model.setTitle(title)
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func scrolled(source: TerminalView, position: Double) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link) { NSWorkspace.shared.open(url) }
        }

        func bell(source: TerminalView) {
            NSSound.beep()
        }

        func clipboardCopy(source: TerminalView, content: Data) {
            guard let text = String(data: content, encoding: .utf8) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
