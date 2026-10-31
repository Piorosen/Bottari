import BottariSFTP
import SwiftUI

/// Turns on a server's remote screen right where it is wanted: which kind,
/// which port, and whether something answers there before saying yes.
struct ScreenSetupView: View {
    let site: SavedSite
    /// Whether the server is a Mac, which is most likely shared with Screen Sharing.
    let isMac: () async -> Bool
    /// What the server says about a port of its own.
    let check: (Int) async -> SFTPFileProvider.PortCheck
    /// The settings to save and open with, or nil to leave things as they were.
    let finish: (SavedSite.RemoteScreen?) -> Void

    @State private var kind = SavedSite.RemoteScreen.Kind.vnc
    @State private var port = 5900
    @State private var throughTunnel = true
    /// What the server said about the port; nil while asking.
    @State private var probe: SFTPFileProvider.PortCheck?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("원격 화면 켜기")
                    .font(.ui(.headline))
                Text("‘\(site.name)’의 화면을 Bottari 창에서 보고 조작합니다.")
                    .font(.ui(.callout))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Button("VNC") { kind = .vnc }
                    .buttonStyle(ChoiceButtonStyle(isOn: kind == .vnc))
                Button("macOS 화면 공유") { kind = .appleScreenSharing }
                    .buttonStyle(ChoiceButtonStyle(isOn: kind == .appleScreenSharing))
            }
            HStack(spacing: 8) {
                Text("포트").font(.ui(.callout, weight: .medium))
                TextField("포트", value: $port, format: .number.grouping(.never))
                    .designField(mono: true)
                    .frame(width: 80)
                probeLabel
                    .motion(value: probe)
            }
            Toggle(isOn: $throughTunnel) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("SSH 연결을 거쳐 열기")
                        .font(.ui(.callout))
                    Text("서버의 방화벽을 열지 않아도 되고, 화면 내용이 암호화된 SSH 안으로만 오갑니다.")
                        .font(.ui(.caption))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
            if let advice {
                Text(advice)
                    .font(.ui(.caption))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .unfolds()
            }
            HStack {
                Spacer()
                Button("취소") { finish(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("켜고 열기") {
                    finish(SavedSite.RemoteScreen(kind: kind, port: port, throughTunnel: throughTunnel))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!(1...65535).contains(port))
            }
        }
        .padding(16)
        .frame(width: 400)
        .motion(value: advice)
        .task {
            if await isMac() { kind = .appleScreenSharing }
        }
        .task(id: port) {
            probe = nil
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            probe = await check(port)
        }
    }

    /// What to do on the server when nothing usable answers.
    private var advice: String? {
        switch probe {
        case .silent:
            kind == .vnc
                ? String(localized: "서버에서 VNC 서버를 먼저 켜야 합니다. 예: x11vnc -localhost -display :0 -forever, 또는 TigerVNC의 vncserver -localhost")
                : String(localized: "그 Mac의 시스템 설정 › 일반 › 공유에서 화면 공유를 켜야 합니다.")
        case .forwardingDisabled:
            String(localized: "이 서버는 SSH를 거친 포트 연결을 막아 두었습니다(sshd_config의 AllowTcpForwarding). 서버 설정을 바꾸거나, 아래 ‘SSH 연결을 거쳐 열기’를 끄고 화면 포트에 직접 연결하십시오.")
        case .answering, nil:
            nil
        }
    }

    @ViewBuilder private var probeLabel: some View {
        switch probe {
        case nil:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("서버에서 확인하는 중").font(.ui(.caption)).foregroundStyle(.secondary)
            }
        case .answering:
            Label("화면 서버가 응답합니다", systemImage: "checkmark.circle.fill")
                .font(.ui(.caption))
                .foregroundStyle(.green)
        case .silent:
            Label("이 포트에서 응답이 없습니다", systemImage: "exclamationmark.circle")
                .font(.ui(.caption))
                .foregroundStyle(.orange)
        case .forwardingDisabled:
            Label("확인할 수 없습니다", systemImage: "exclamationmark.circle")
                .font(.ui(.caption))
                .foregroundStyle(.orange)
        }
    }
}

extension ScreenSetupView {
    /// Asks the pane's own server.
    init(provider: SFTPFileProvider, site: SavedSite, finish: @escaping (SavedSite.RemoteScreen?) -> Void) {
        self.init(site: site, isMac: {
            guard provider.canRunCommands else { return false }
            return (try? await provider.run("uname -s"))?.hasPrefix("Darwin") == true
        }, check: { port in
            await provider.checkPort(host: "localhost", port: port)
        }, finish: finish)
    }
}
