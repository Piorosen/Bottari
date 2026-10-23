import AppKit
import BottariCore
import BottariRemote
import BottariSFTP
import BottariTransfer
import Observation
import SwiftUI

/// A VNC or macOS Screen Sharing session, through the site's SSH connection
/// when the site says so.
@Observable
final class ScreenModel: NSObject, VNCConnectionDelegate {
    struct CredentialRequest: Identifiable {
        let id = UUID()
        let needsUsername: Bool
        let completion: (VNCCredential?) -> Void
    }

    /// The site's SSH connection, for the tunnel and uploads. Nil connects
    /// straight to `host` (used by the self-check).
    let provider: SFTPFileProvider?
    let site: SavedSite
    let screen: SavedSite.RemoteScreen
    let host: String
    let username: String
    private(set) var status = "연결하는 중…"
    private(set) var isConnected = false
    private(set) var framebufferView: VNCCAFramebufferView?
    var credentialRequest: CredentialRequest?
    /// Fit the remote screen into the window, or show it pixel for pixel.
    var scalesToFit = true
    /// Watch only: mouse and keyboard stay here.
    var viewOnly = false
    /// Send ⌘ shortcuts to the remote computer too.
    var forwardsShortcuts = false

    @ObservationIgnored private var connection: VNCConnection?
    @ObservationIgnored private var forward: PortForward?

    init(provider: SFTPFileProvider?, site: SavedSite, screen: SavedSite.RemoteScreen) {
        self.provider = provider
        self.site = site
        self.screen = screen
        host = provider?.endpoint.host ?? site.endpoint.host
        username = provider?.endpoint.username ?? site.endpoint.username
    }

    var kindName: String { screen.kind == .vnc ? "VNC" : "화면 공유" }

    func connect() async {
        disconnect()
        do {
            var host = self.host
            var port = screen.port
            if screen.throughTunnel, let provider {
                status = "SSH 터널 여는 중…"
                let forward = try await provider.forward(toHost: "localhost", port: screen.port)
                self.forward = forward
                host = "127.0.0.1"
                port = forward.localPort
            }
            status = "\(kindName)에 연결하는 중…"
            let settings = VNCConnection.Settings(
                isDebugLoggingEnabled: false,
                hostname: host,
                port: UInt16(port),
                isShared: true,
                isScalingEnabled: scalesToFit,
                useDisplayLink: true,
                inputMode: viewOnly ? .none : forwardsShortcuts ? .forwardAllKeyboardShortcutsAndHotKeys : .forwardKeyboardShortcutsIfNotInUseLocally,
                isClipboardRedirectionEnabled: !viewOnly,
                colorDepth: .depth24Bit,
                frameEncodings: VNCFrameEncodingType.defaultFrameEncodings
            )
            let connection = VNCConnection(settings: settings, logger: VNCOSLogLogger())
            connection.delegate = self
            self.connection = connection
            connection.connect()
        } catch {
            status = "터널을 열지 못했어요: \(error.localizedDescription)"
        }
    }

    func disconnect() {
        connection?.disconnect()
        connection = nil
        framebufferView = nil
        isConnected = false
        let forward = self.forward
        self.forward = nil
        Task { await forward?.close() }
    }

    func sendControlAltDelete() {
        guard let connection else { return }
        let keys: [VNCKeyCode] = [.control, screen.kind == .appleScreenSharing ? .optionForARD : .option, .forwardDelete]
        keys.forEach(connection.keyDown)
        keys.reversed().forEach(connection.keyUp)
    }

    /// Files dropped on the screen go to the remote Desktop (or home) folder over SFTP.
    func upload(_ urls: [URL]) {
        guard let provider else { return }
        Task {
            let local = LocalFileProvider()
            var items: [FileItem] = []
            for url in urls {
                if let item = try? await local.stat(RemotePath(url.path)) { items.append(item) }
            }
            guard !items.isEmpty else { return }
            let desktop = provider.home.appending("Desktop")
            let folder = (try? await provider.list(provider.home))?.contains { $0.name == "Desktop" && $0.isDirectory } == true ? desktop : provider.home
            AppServices.transfers.enqueue(.copy, items, from: TransferEndpoint(local), to: TransferEndpoint(provider, name: site.name), into: folder, policy: TransferSettings.conflictPolicy)
            status = "\(items.count)개 항목을 \(folder.string)에 올리는 중"
        }
    }

    // MARK: - VNCConnectionDelegate (called off the main thread)

    nonisolated func connection(_ connection: VNCConnection, stateDidChange connectionState: VNCConnection.ConnectionState) {
        let status = connectionState.status
        let error = connectionState.error?.localizedDescription
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                switch status {
                case .connecting:
                    self.status = "\(self.kindName)에 연결하는 중…"
                case .connected:
                    self.isConnected = true
                    self.status = "연결됨"
                case .disconnecting:
                    self.status = "연결을 끊는 중…"
                case .disconnected:
                    self.isConnected = false
                    self.framebufferView = nil
                    self.status = error.map { "연결이 끊겼어요 · \($0)" } ?? "연결을 끊었어요 · SSH 터널도 함께 닫았어요"
                    let forward = self.forward
                    self.forward = nil
                    Task { await forward?.close() }
                @unknown default:
                    break
                }
            }
        }
    }

    nonisolated func connection(_ connection: VNCConnection, credentialFor authenticationType: VNCAuthenticationType, completion: @escaping (VNCCredential?) -> Void) {
        let needsUsername = authenticationType.requiresUsername
        let reply = UncheckedBox(completion)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let stored = try? AppServices.sites.secrets.secret(for: self.site.screenPasswordKey)
                if let stored, !stored.isEmpty {
                    reply.value(needsUsername
                        ? VNCUsernamePasswordCredential(username: self.username, password: stored)
                        : VNCPasswordCredential(password: stored))
                } else {
                    self.credentialRequest = CredentialRequest(needsUsername: needsUsername, completion: reply.value)
                }
            }
        }
    }

    /// The user typed a password (and for Screen Sharing, maybe another account).
    func answer(_ request: CredentialRequest, username: String, password: String, remember: Bool) {
        credentialRequest = nil
        if remember {
            try? AppServices.sites.secrets.setSecret(password, for: site.screenPasswordKey)
        }
        request.completion(request.needsUsername
            ? VNCUsernamePasswordCredential(username: username.isEmpty ? self.username : username, password: password)
            : VNCPasswordCredential(password: password))
    }

    nonisolated func connection(_ connection: VNCConnection, didCreateFramebuffer framebuffer: VNCFramebuffer) {
        let box = UncheckedBox((connection, framebuffer))
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let (connection, framebuffer) = box.value
                // The view draws updates and passes connection events on to us.
                let view = VNCCAFramebufferView(frame: CGRect(origin: .zero, size: framebuffer.size.cgSize), framebuffer: framebuffer, connection: connection, connectionDelegate: self)
                connection.delegate = view
                self.framebufferView = view
            }
        }
    }

    nonisolated func connection(_ connection: VNCConnection, didResizeFramebuffer framebuffer: VNCFramebuffer) {}
    nonisolated func connection(_ connection: VNCConnection, didUpdateFramebuffer framebuffer: VNCFramebuffer, x: UInt16, y: UInt16, width: UInt16, height: UInt16) {}
    nonisolated func connection(_ connection: VNCConnection, didUpdateCursor cursor: VNCCursor) {}
}

/// Carries a value RoyalVNC hands over on its own queue to the main queue.
private nonisolated struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

struct ScreenWindow: View {
    let contextID: UUID
    @State private var model: ScreenModel?

    var body: some View {
        Group {
            if let model {
                ScreenView(model: model)
            } else {
                ContentUnavailableView("원격 화면을 열 수 없어요", systemImage: "display", description: Text("연결 관리에서 이 서버의 원격 제어를 켜 주세요."))
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .onAppear {
            guard model == nil, let context = Viewers.context(contextID), let server = context.provider as? SFTPFileProvider,
                  let site = context.site, let screen = site.remoteScreen else { return }
            let screenModel = ScreenModel(provider: server, site: site, screen: screen)
            model = screenModel
            Task { await screenModel.connect() }
        }
        .onDisappear {
            model?.disconnect()
            Viewers.close(contextID)
        }
    }
}

struct ScreenView: View {
    @Bindable var model: ScreenModel
    @State private var isDropTarget = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 12) {
                    screen
                        .clipShape(.rect(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line))
                    bottomBar
                }
                sidePanel
                    .frame(width: 300)
            }
            .padding([.horizontal, .bottom], 12)
        }
        .background(Palette.background)
        .navigationTitle("\(model.site.name) · \(model.kindName)")
        .sheet(item: $model.credentialRequest) { request in
            CredentialSheet(request: request, defaultUsername: model.username) { username, password, remember in
                model.answer(request, username: username, password: password, remember: remember)
            } cancel: {
                model.credentialRequest = nil
                request.completion(nil)
            }
        }
    }

    private var stopped: Bool {
        !model.isConnected && (model.status.hasPrefix("연결이") || model.status.hasPrefix("연결을 끊었") || model.status.hasPrefix("터널을"))
    }

    private var screen: some View {
        ZStack {
            Color(light: 0x0E1014, dark: 0x0A0C10)
            if let view = model.framebufferView {
                FramebufferHost(view: view, scalesToFit: model.scalesToFit)
                    .padding(10)
            } else {
                VStack(spacing: 10) {
                    if !stopped {
                        ProgressView().controlSize(.large)
                    }
                    Text(model.status).font(.ui(.callout))
                    if stopped {
                        Button("다시 연결") { Task { await model.connect() } }
                            .buttonStyle(PanelButtonStyle())
                            .fixedSize()
                    }
                }
                .foregroundStyle(.white)
            }
            if isDropTarget {
                Text("놓으면 \(model.site.name)에 업로드 (SFTP)")
                    .font(.ui(.callout))
                    .padding(12)
                    .background(.ultraThinMaterial, in: .rect(cornerRadius: 8))
            }
        }
        .environment(\.colorScheme, .dark)
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
            Task {
                var urls: [URL] = []
                for provider in providers {
                    if let url = await withCheckedContinuation({ (continuation: CheckedContinuation<URL?, Never>) in
                        _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                            continuation.resume(returning: (object as? NSURL).map { $0 as URL })
                        }
                    }) { urls.append(url) }
                }
                model.upload(urls)
            }
            return true
        }
    }

    private var route: String {
        let jumps = model.site.proxyJump
        return [
            model.screen.throughTunnel ? "\(model.kindName) over SSH (자동 터널)" : "\(model.kindName) 직접 연결",
            "\(model.host):\(String(model.screen.port))",
        ].joined(separator: " · ") + (jumps.isEmpty ? "" : " · \(jumps.joined(separator: " → ")) 경유")
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            BackButton(title: "파일로 돌아가기") { NSApp.keyWindow?.performClose(nil) }
                .buttonStyle(PanelButtonStyle())
                .fixedSize()
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("\(model.site.name) · 원격 화면").font(.ui(.body, weight: .semibold))
                    if let tag = model.site.tag {
                        if tag == .prod { TagChip(tag: tag) } else { TagChip.outlined(tag) }
                    }
                }
                Text(route).font(.themeMono(.caption2)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            HStack(spacing: 0) {
                Button("화면 맞춤") { model.scalesToFit = true }
                    .buttonStyle(ChoiceButtonStyle(isOn: model.scalesToFit))
                Button("1:1") { model.scalesToFit = false }
                    .buttonStyle(ChoiceButtonStyle(isOn: !model.scalesToFit))
            }
            .fixedSize()
            .onChange(of: model.scalesToFit) { Task { await model.connect() } }
            Menu("키 보내기") {
                Button("Ctrl + Alt + Delete") { model.sendControlAltDelete() }
                Toggle("⌘ 단축키도 원격으로 보내기", isOn: $model.forwardsShortcuts)
            }
            .fixedSize()
            .onChange(of: model.forwardsShortcuts) { Task { await model.connect() } }
            Button(model.isConnected ? "연결 끊기" : "다시 연결") {
                if model.isConnected { model.disconnect() } else { Task { await model.connect() } }
            }
            .buttonStyle(PanelButtonStyle(destructive: model.isConnected))
            .fixedSize()
        }
        .padding(12)
    }

    private var bottomBar: some View {
        HStack(spacing: 16) {
            Toggle("보기만 (조작 안 함)", isOn: $model.viewOnly)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.ui(.callout))
                .onChange(of: model.viewOnly) { Task { await model.connect() } }
            Spacer()
            Text("Finder에서 파일을 화면 위로 끌어다 놓으면 원격 컴퓨터로 올라가요")
                .font(.ui(.caption))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .card()
    }

    private var sidePanel: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                Text("연결 상태").font(.ui(.body, weight: .semibold))
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    row("상태", model.isConnected ? "연결됨" : model.status)
                    row("종류", model.screen.kind == .vnc ? "VNC (RFB)" : "macOS 화면 공유")
                    row("주소", "\(model.host):\(String(model.screen.port))")
                    if let size = model.framebufferView?.framebufferSize {
                        row("원격 해상도", "\(Int(size.width)) × \(Int(size.height))")
                    }
                    row("암호화", model.screen.throughTunnel ? "SSH 터널" : "없음 · 직접 연결")
                    if !model.site.proxyJump.isEmpty {
                        row("경유", model.site.proxyJump.joined(separator: " → "))
                    }
                    row("표시", model.scalesToFit ? "화면 맞춤" : "1:1")
                    row("입력", model.viewOnly ? "보기만" : model.forwardsShortcuts ? "⌘ 단축키까지" : "마우스 · 키보드")
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
            VStack(alignment: .leading, spacing: 6) {
                Text(model.screen.throughTunnel ? "왜 SSH 터널인가요?" : "직접 연결 중이에요").font(.ui(.callout, weight: .semibold))
                Text(model.screen.throughTunnel
                     ? "VNC는 기본적으로 암호화가 약해요. Bottari는 이미 저장된 SSH 연결로 터널을 열고 그 안으로 화면을 보내서, 서버 방화벽에 \(String(model.screen.port)) 포트를 열 필요가 없어요."
                     : "화면이 암호화되지 않고 오갈 수 있어요. 연결 관리에서 'SSH 터널로 연결'을 켜는 걸 추천해요.")
                    .font(.ui(.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .well()
            Spacer()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).font(.ui(.caption)).foregroundStyle(.secondary)
            Text(value).font(.themeMono(.caption)).lineLimit(2)
        }
    }
}

/// RoyalVNC's framebuffer view, fitted to the window or in a scroll view at 1:1.
private struct FramebufferHost: NSViewRepresentable {
    let view: VNCCAFramebufferView
    let scalesToFit: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = !scalesToFit
        scrollView.hasHorizontalScroller = !scalesToFit
        scrollView.drawsBackground = false
        scrollView.documentView = view
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        if scrollView.documentView !== view {
            scrollView.documentView = view
        }
        if scalesToFit {
            view.autoresizingMask = [.width, .height]
            view.frame = scrollView.contentView.bounds
        } else {
            view.autoresizingMask = []
            view.frame = CGRect(origin: .zero, size: view.framebufferSize)
        }
    }
}

private struct CredentialSheet: View {
    let request: ScreenModel.CredentialRequest
    let defaultUsername: String
    let answer: (String, String, Bool) -> Void
    let cancel: () -> Void
    @State private var username = ""
    @State private var password = ""
    @State private var remember = true

    var body: some View {
        Form {
            Section(request.needsUsername ? "macOS 계정으로 로그인" : "VNC 비밀번호") {
                if request.needsUsername {
                    TextField("사용자", text: $username, prompt: Text(defaultUsername))
                }
                SecureField("비밀번호", text: $password)
                Toggle("키체인에 저장", isOn: $remember)
            }
            HStack {
                Spacer()
                Button("취소", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("연결") { answer(username, password, remember) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
    }
}
