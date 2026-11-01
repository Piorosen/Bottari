import AppKit
import BottariCore
import SwiftUI

/// Asks the user for a folder (or file) the App Sandbox keeps Bottari out of,
/// and keeps it reachable from then on.
enum FolderAccessPanel {
    /// The open panel, starting in `folder`; nil when the user cancels.
    @discardableResult
    static func ask(startingAt folder: RemotePath, showingHiddenFiles: Bool = false) -> URL? {
        let panel = NSOpenPanel()
        panel.title = String(localized: "폴더 허용")
        panel.message = String(localized: "Bottari가 쓸 폴더를 고르십시오. 고른 폴더와 그 안의 모든 것을 열 수 있게 되고, 다음에 실행할 때도 기억합니다.")
        panel.prompt = String(localized: "허용")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = showingHiddenFiles
        panel.directoryURL = URL(fileURLWithPath: folder.string, isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        FolderAccess.shared.remember(url)
        // ~/.ssh may just have come within reach.
        AppServices.sites.reloadSSHConfig()
        return url
    }
}

/// What a pane shows in place of a folder of this Mac it may not open yet.
struct FolderAccessPrompt: View {
    let folder: RemotePath
    /// The folder the user allowed.
    let allowed: (URL) -> Void
    let openDownloads: () -> Void

    private var isHome: Bool { folder.string == UserHome.path }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.open")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text("‘\(folder.name)’ 폴더를 열려면 허용이 필요합니다")
                .font(.ui(.headline))
                .multilineTextAlignment(.center)
            Text(isHome
                ? String(localized: "Bottari는 macOS 샌드박스 안에서 실행되어, 직접 허용한 폴더만 열 수 있습니다. 홈 폴더를 허용하면 그 안의 모든 폴더와 ~/.ssh의 설정, 키도 함께 쓸 수 있습니다.")
                : String(localized: "Bottari는 macOS 샌드박스 안에서 실행되어, 직접 허용한 폴더만 열 수 있습니다. 한 번 허용하면 다음에도 기억합니다."))
                .font(.ui(.callout))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(isHome ? String(localized: "홈 폴더 허용…") : String(localized: "이 폴더 허용…")) {
                    if let url = FolderAccessPanel.ask(startingAt: folder) { allowed(url) }
                }
                .buttonStyle(PanelButtonStyle(prominent: true))
                Button("다운로드 폴더 열기", action: openDownloads)
                    .buttonStyle(PanelButtonStyle())
            }
            .fixedSize()
        }
        .padding(24)
        .frame(maxWidth: 420)
    }
}
