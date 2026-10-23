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

private struct ScreenView: View {
    @Bindable var model: ScreenModel
    @State private var isDropTarget = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ZStack {
                Color.black
                if let view = model.framebufferView {
                    FramebufferHost(view: view, scalesToFit: model.scalesToFit)
                } else {
                    VStack(spacing: 10) {
                        if !model.status.hasPrefix("연결이") && !model.status.hasPrefix("연결을 끊었") && !model.status.hasPrefix("터널을") {
                            ProgressView().controlSize(.large)
                        }
                        Text(model.status)
                        if !model.isConnected && (model.status.hasPrefix("연결이") || model.status.hasPrefix("연결을 끊었") || model.status.hasPrefix("터널을")) {
                            Button("다시 연결") { Task { await model.connect() } }
                        }
                    }
                    .foregroundStyle(.white)
                }
                if isDropTarget {
                    Text("놓으면 \(model.site.name)에 업로드 (SFTP)")
                        .padding(12)
                        .background(.ultraThinMaterial, in: .rect(cornerRadius: 8))
                }
            }
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
            Divider()
            statusBar
        }
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

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "display")
                .foregroundStyle(model.site.tag == .prod ? SavedSite.Tag.prod.color : .secondary)
            Text(model.site.name)
                .font(.headline)
            if let tag = model.site.tag {
                TagChip(tag: tag)
            }
            Text(model.kindName)
                .foregroundStyle(.secondary)
            Spacer()
            Picker("크기", selection: $model.scalesToFit) {
                Text("화면 맞춤").tag(true)
                Text("1:1").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .onChange(of: model.scalesToFit) { Task { await model.connect() } }
            Menu("키 보내기") {
                Button("Ctrl + Alt + Delete") { model.sendControlAltDelete() }
                Toggle("⌘ 단축키도 원격으로 보내기", isOn: $model.forwardsShortcuts)
            }
            .fixedSize()
            .onChange(of: model.forwardsShortcuts) { Task { await model.connect() } }
            Toggle(isOn: $model.viewOnly) {
                Label("보기만", systemImage: model.viewOnly ? "eye.fill" : "eye")
            }
            .toggleStyle(.button)
            .help("마우스와 키보드를 보내지 않아요")
            .onChange(of: model.viewOnly) { Task { await model.connect() } }
            Button(model.isConnected ? "연결 끊기" : "다시 연결") {
                if model.isConnected { model.disconnect() } else { Task { await model.connect() } }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(model.isConnected ? Color.green : .orange)
                .frame(width: 7, height: 7)
            Text(model.status)
            Spacer()
            if model.screen.throughTunnel {
                Label("SSH 터널 · 서버 방화벽에 \(String(model.screen.port)) 포트를 열 필요 없어요", systemImage: "lock.fill")
            } else {
                Label("직접 연결", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
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
