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
    /// The shell's working folder, when it reports one (OSC 7).
    private(set) var reportedDirectory: RemotePath?
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

    /// `file://host/path` from the shell.
    func setReportedDirectory(_ directory: String?) {
        guard let directory else { return }
        let path = URL(string: directory)?.path ?? directory
        if path.hasPrefix("/") { reportedDirectory = RemotePath(path) }
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
        VStack(spacing: 0) {
            header
            HStack(alignment: .top, spacing: 12) {
                FolderCard(model: model)
                    .frame(width: 230)
                VStack(spacing: 0) {
                    ZStack(alignment: .top) {
                        SwiftTermView(model: model)
                            .padding(10)
                        if case .closed(let reason) = model.status {
                            disconnectedBanner(reason)
                        }
                    }
                    statusBar
                }
                .background(Color(light: 0x0E1014, dark: 0x0A0C10))
                .overlay(alignment: .top) {
                    if model.site?.tag == .prod {
                        Rectangle().fill(SavedSite.Tag.prod.color).frame(height: 3)
                    }
                }
                .clipShape(.rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.line))
                if showsSnippets {
                    snippetList
                        .frame(width: 290)
                }
            }
            .padding([.horizontal, .bottom], 12)
        }
        .background(Palette.background)
        .navigationTitle(model.title)
    }

    private var header: some View {
        HStack(spacing: 10) {
            BackButton(title: "파일로 돌아가기") { NSApp.keyWindow?.performClose(nil) }
                .buttonStyle(PanelButtonStyle())
                .fixedSize()
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(model.site?.tag?.color ?? Color.secondary.opacity(0.4))
                    .frame(width: 3, height: 16)
                Text(model.site?.name ?? model.provider.displayName).font(.ui(.callout, weight: .semibold))
                if let jumps = model.site?.proxyJump, !jumps.isEmpty {
                    Text("via \(jumps.joined(separator: " → "))")
                        .font(.themeMono(.caption2))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Palette.panel, in: .rect(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.line))
            Spacer()
            Button {
                model.joinsBroadcast.toggle()
            } label: {
                Label("동시 입력", systemImage: "dot.radiowaves.left.and.right")
            }
            .buttonStyle(ChoiceButtonStyle(isOn: model.joinsBroadcast))
            .fixedSize()
            .help("켜 둔 터미널 모두에 같은 입력을 보내요. 서버 여러 대를 점검할 때 써요.")
            Button { showsSnippets.toggle() } label: { Image(systemName: "sidebar.right") }
                .buttonStyle(IconButtonStyle(isOn: showsSnippets))
                .help("명령 조각")
        }
        .padding(12)
    }

    private func disconnectedBanner(_ reason: String?) -> some View {
        HStack {
            Image(systemName: "bolt.horizontal.circle")
            Text(reason.map { "연결이 끊겼어요 · \($0)" } ?? "셸이 끝났어요")
            Spacer()
            Button("다시 연결") { model.connect() }
                .buttonStyle(PanelButtonStyle())
                .fixedSize()
        }
        .font(.ui(.callout))
        .padding(10)
        .background(Color.orange.opacity(0.9), in: .rect(cornerRadius: 8))
        .foregroundStyle(.white)
        .padding(14)
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(model.status == .connected ? Color.green : model.status == .connecting ? .yellow : .red)
                .frame(width: 6, height: 6)
            Text("\(model.provider.endpoint.username)@\(model.site?.name ?? model.provider.displayName)")
            Text("SSH · \(model.site.map { auth($0) } ?? "")")
            Spacer()
            if model.joinsBroadcast {
                Text("동시 입력 중 · \(TerminalBroadcast.shared.count)개 세션")
                    .foregroundStyle(.orange)
            }
            Text("UTF-8 · xterm-256color · \(model.size.columns)×\(model.size.rows)")
        }
        .font(.themeMono(.caption2))
        .foregroundStyle(Color.white.opacity(0.55))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.04))
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
    }

    private func auth(_ site: SavedSite) -> String {
        switch site.authentication {
        case .agent: "ssh-agent"
        case .keyFile(let path): (path as NSString).lastPathComponent
        case .password: "비밀번호"
        }
    }

    private var snippetList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("명령 조각").font(.ui(.body, weight: .semibold))
                Spacer()
                Text("누르면 실행").font(.ui(.caption)).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(snippets, id: \.self) { snippet in
                        Button {
                            model.run(snippet)
                        } label: {
                            Text(snippet)
                                .font(.themeMono(.caption))
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(Palette.panel, in: .rect(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line))
                                .contentShape(.rect)
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
            }
            .scrollIndicators(.never)
            HStack(spacing: 6) {
                TextField("새 명령", text: $newSnippet)
                    .designField(mono: true)
                    .onSubmit(addSnippet)
                Button(action: addSnippet) { Image(systemName: "plus") }
                    .buttonStyle(IconButtonStyle())
                    .disabled(newSnippet.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .card()
    }

    private func addSnippet() {
        let snippet = newSnippet.trimmingCharacters(in: .whitespaces)
        guard !snippet.isEmpty, !snippets.contains(snippet) else { return }
        snippets.append(snippet)
        TerminalSnippets.all = snippets
        newSnippet = ""
    }
}

/// The folder the terminal started in, listed: clicking a folder goes there
/// (and runs cd when 경로 맞추기 is on), clicking a file types its path.
private struct FolderCard: View {
    let model: TerminalModel
    @State private var path: RemotePath?
    @State private var items: [FileItem] = []
    @State private var follows = true

    private var shown: RemotePath { path ?? model.folder }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("현재 폴더").font(.ui(.body, weight: .semibold))
                Spacer()
                Toggle("경로 맞추기", isOn: $follows)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.ui(.caption))
                    .help("폴더를 누르면 터미널에서도 cd 해요. 셸이 알려 주면 터미널의 위치를 따라가요.")
            }
            Text("\(model.site?.name ?? model.provider.displayName):\(shown.string)")
                .font(.themeMono(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.head)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let parent = shown.parent {
                        row(symbol: "chevron.up", name: "..", size: nil) { go(parent) }
                    }
                    ForEach(items.filter { !$0.isHidden }) { item in
                        row(symbol: item.glyph, name: item.isDirectory ? item.name + "/" : item.name, size: item.isDirectory ? nil : item.formattedSize, folder: item.isDirectory) {
                            if item.isDirectory {
                                go(item.path)
                            } else {
                                model.type(Data((SFTPFileProvider.quote(item.path.string) + " ").utf8))
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            Rectangle().fill(Palette.line).frame(height: 1)
            Text("폴더를 누르면 cd, 파일을 누르면 경로가 입력돼요.")
                .font(.ui(.caption))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .card()
        .task(id: shown) {
            items = (try? await model.provider.list(shown)) ?? []
        }
        .onChange(of: model.reportedDirectory) {
            if follows, let directory = model.reportedDirectory { path = directory }
        }
    }

    private func go(_ folder: RemotePath) {
        path = folder
        if follows { model.run("cd -- \(SFTPFileProvider.quote(folder.string))") }
    }

    private func row(symbol: String, name: String, size: String?, folder: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(folder ? Color.themeAccent : .secondary)
                    .frame(width: 16)
                Text(name).font(.ui(.callout)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if let size {
                    Text(size).font(.themeMono(.caption2)).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 5)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
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
        view.nativeBackgroundColor = NSColor(themeHex: "#0E1014") ?? .black
        view.nativeForegroundColor = NSColor(themeHex: "#E6E8EC") ?? .white
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

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            model.setReportedDirectory(directory)
        }

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
