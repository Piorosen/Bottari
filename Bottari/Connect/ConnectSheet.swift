import AppKit
import BottariSFTP
import SwiftUI

/// Asks for an SFTP server and hands back an open connection.
struct ConnectSheet: View {
    let onConnected: (SFTPFileProvider) -> Void

    @Environment(\.dismiss) private var dismiss

    // Remembered between launches. Secrets are not: Keychain support comes with saved sites.
    @AppStorage("connect.host") private var host = ""
    @AppStorage("connect.port") private var port = 22
    @AppStorage("connect.username") private var username = NSUserName()
    @AppStorage("connect.usesKey") private var usesKey = true
    @AppStorage("connect.keyPath") private var keyPath = "~/.ssh/id_ed25519"
    @State private var password = ""
    @State private var passphrase = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @State private var changedKeyEndpoint: SFTPEndpoint?

    private var endpoint: SFTPEndpoint {
        SFTPEndpoint(
            host: host.trimmingCharacters(in: .whitespaces),
            port: port,
            username: username.trimmingCharacters(in: .whitespaces)
        )
    }

    private var canConnect: Bool {
        !endpoint.host.isEmpty && !endpoint.username.isEmpty && (1...65535).contains(port)
            && (usesKey ? !keyPath.isEmpty : !password.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("SFTP 서버") {
                    TextField("호스트", text: $host, prompt: Text("example.com"))
                    TextField("포트", value: $port, format: .number.grouping(.never))
                    TextField("사용자", text: $username)
                }
                Section("인증") {
                    Picker("방식", selection: $usesKey) {
                        Text("키 파일").tag(true)
                        Text("비밀번호").tag(false)
                    }
                    .pickerStyle(.segmented)
                    if usesKey {
                        HStack {
                            TextField("키 파일", text: $keyPath)
                            Button("선택…", action: chooseKey)
                        }
                        SecureField("키 암호", text: $passphrase, prompt: Text("없으면 비워 두세요"))
                    } else {
                        SecureField("비밀번호", text: $password)
                    }
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                        if changedKeyEndpoint != nil {
                            Button("서버를 다시 설치했어요. 새 키를 믿고 연결", role: .destructive) {
                                Task { await trustNewKeyAndConnect() }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isConnecting)

            Divider()
            HStack {
                if isConnecting {
                    ProgressView().controlSize(.small)
                    Text("연결하는 중…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("취소", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("연결") { Task { await connect() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConnect || isConnecting)
            }
            .padding(16)
        }
        .frame(width: 460)
    }

    private func connect() async {
        isConnecting = true
        errorMessage = nil
        changedKeyEndpoint = nil
        defer { isConnecting = false }
        let endpoint = endpoint
        do {
            let provider = try await SFTPFileProvider.connect(
                to: endpoint,
                credential: try credential(),
                hostKeys: .knownHosts(AppServices.knownHosts)
            )
            onConnected(provider)
            dismiss()
        } catch let error as SFTPConnectError {
            errorMessage = error.localizedDescription
            if case .hostKeyChanged = error {
                changedKeyEndpoint = endpoint
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func trustNewKeyAndConnect() async {
        guard let endpoint = changedKeyEndpoint else { return }
        AppServices.knownHosts.forget(endpoint)
        await connect()
    }

    private func credential() throws -> SFTPCredential {
        guard usesKey else { return .password(password) }
        let path = (keyPath as NSString).expandingTildeInPath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw KeyFileError(path: keyPath)
        }
        return .privateKey(text, passphrase: passphrase.isEmpty ? nil : passphrase)
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.title = "개인 키 선택"
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh")
        if panel.runModal() == .OK, let url = panel.url {
            keyPath = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }
}

private struct KeyFileError: LocalizedError {
    let path: String
    var errorDescription: String? { "키 파일을 읽지 못했어요: \(path)" }
}
