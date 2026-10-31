import AppKit
import BottariCore
import BottariSFTP
import SwiftUI

/// One thing ⌘K can do.
struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    var subtitle = ""
    let symbol: String
    /// Extra words it answers to, e.g. "ssh terminal".
    var keywords = ""
    let run: () -> Void

    /// How well `query` matches: a prefix beats a substring beats letters in order.
    func score(_ query: String) -> Int? {
        let query = query.lowercased()
        guard !query.isEmpty else { return 1 }
        let haystacks = [title.lowercased(), keywords.lowercased(), subtitle.lowercased()]
        if haystacks[0].hasPrefix(query) { return 100 }
        if haystacks.contains(where: { $0.split(separator: " ").contains { $0.hasPrefix(query) } }) { return 80 }
        if haystacks.contains(where: { $0.contains(query) }) { return 60 }
        var remaining = Substring(query)
        for character in haystacks[0] where character == remaining.first {
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return 20 }
        }
        return nil
    }
}

/// "폴더, 서버, 명령 검색": a search box over places, sites and
/// commands, acting on the active pane.
struct CommandPalette: View {
    let workspace: Workspace
    let close: () -> Void
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("폴더, 서버, 명령 검색", text: $query)
                    .textFieldStyle(.plain)
                    .font(.ui(.title3))
                    .focused($focused)
                    .onSubmit(runSelected)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.escape) { close(); return .handled }
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, command in
                            row(command, isSelected: index == selected)
                                .id(index)
                                .onTapGesture {
                                    selected = index
                                    runSelected()
                                }
                        }
                        if results.isEmpty {
                            Text("일치하는 항목 없음")
                                .foregroundStyle(.secondary)
                                .padding(20)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: selected) { proxy.scrollTo(selected) }
            }
            .frame(maxHeight: 360)
            Divider()
            HStack {
                Text("↵ 실행 · ↑↓ 선택 · esc 닫기")
                Spacer()
                Text("대상: \(workspace.pane(workspace.activeSide).provider.displayName) 패인")
            }
            .font(.ui(.caption))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(width: 620)
        .background(.regularMaterial, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
        .shadow(radius: 30, y: 10)
        .onAppear { focused = true }
        .onChange(of: query) { selected = 0 }
    }

    private func row(_ command: PaletteCommand, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Glyph(command.symbol, size: 16)
                .frame(width: 22)
                .foregroundStyle(isSelected ? .white : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(command.title)
                if !command.subtitle.isEmpty {
                    Text(command.subtitle)
                        .font(.ui(.caption))
                        .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(isSelected ? .white : .primary)
        .background(isSelected ? Color.themeAccent : .clear, in: .rect(cornerRadius: 7))
        .contentShape(.rect)
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selected = (selected + delta + results.count) % results.count
    }

    private func runSelected() {
        guard results.indices.contains(selected) else { return }
        let command = results[selected]
        close()
        command.run()
    }

    private var results: [PaletteCommand] {
        commands
            .compactMap { command in command.score(query).map { (command, $0) } }
            .sorted { $0.1 > $1.1 }
            .prefix(40)
            .map(\.0)
    }

    private func keys(_ action: PaneAction) -> String {
        Keymap.shared.combo(for: action).description
    }

    private var commands: [PaletteCommand] {
        let side = workspace.activeSide
        let pane = workspace.pane(side)
        var list: [PaletteCommand] = []

        // A typed path goes straight there.
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            let path = trimmed.hasPrefix("~") ? pane.provider.home.appending(String(trimmed.dropFirst())) : RemotePath(trimmed)
            list.append(PaletteCommand(id: "path", title: String(localized: "이 폴더로 이동: \(path.string)"), subtitle: pane.provider.displayName, symbol: "arrow.right.circle", keywords: trimmed) {
                Task { await pane.open(path) }
            })
        }

        for site in AppServices.sites.sites {
            list.append(PaletteCommand(id: "site-\(site.id)", title: String(localized: "\(site.name) 열기"), subtitle: site.summary, symbol: site.symbol, keywords: String(localized: "연결 connect \(site.tag?.label ?? "")")) {
                workspace.open(site)
            })
        }
        let home = RemotePath(NSHomeDirectory())
        for (name, folder) in [(String(localized: "홈"), ""), (MacFolder.desktop, "Desktop"), (MacFolder.documents, "Documents"), (MacFolder.downloads, "Downloads")] {
            list.append(PaletteCommand(id: "mac-\(name)", title: name, subtitle: String(localized: "이 Mac"), symbol: "folder", keywords: "mac \(folder.lowercased())") {
                workspace.openOnMac(home.appending(folder))
            })
        }
        if let iCloud = LocalFileProvider.iCloudDrive {
            list.append(PaletteCommand(id: "icloud", title: "iCloud Drive", subtitle: String(localized: "이 Mac"), symbol: "bt.cloud", keywords: "icloud") {
                workspace.openOnMac(iCloud)
            })
        }
        for favorite in Favorites.shared.items {
            list.append(PaletteCommand(id: "favorite-\(favorite.id)", title: favorite.name, subtitle: favorite.path.string, symbol: "bt.star", keywords: String(localized: "즐겨찾기 favorite")) {
                workspace.open(favorite)
            })
        }

        let selection = pane.selectedItems
        let other = workspace.pane(side.other).provider.displayName
        list += [
            PaletteCommand(id: "new-folder", title: String(localized: "새 폴더"), subtitle: keys(.newFolder), symbol: "folder.badge.plus", keywords: "new folder mkdir") {
                workspace.makeFolder(in: side)
            },
            PaletteCommand(id: "copy-other", title: String(localized: "선택 항목을 \(other)에 복사"), subtitle: String(localized: "\(selection.count)개 선택 · \(keys(.copyToOther))"), symbol: "arrow.right.doc.on.clipboard", keywords: String(localized: "copy 복사 전송")) {
                workspace.send(selection, from: side, kind: .copy)
            },
            PaletteCommand(id: "move-other", title: String(localized: "선택 항목을 \(other)(으)로 이동"), subtitle: String(localized: "\(selection.count)개 선택 · \(keys(.moveToOther))"), symbol: "arrow.right", keywords: String(localized: "move 이동 전송")) {
                workspace.send(selection, from: side, kind: .move)
            },
            PaletteCommand(id: "bundle", title: String(localized: "선택 항목을 보따리에 담기"), subtitle: keys(.bundle), symbol: "bt.bundle", keywords: String(localized: "bundle 보따리")) {
                workspace.addToBundle(from: side)
            },
            PaletteCommand(id: "bundle-send", title: String(localized: "보따리를 현재 패인으로 보내기"), subtitle: String(localized: "\(BottariBundle.shared.entries.count)개"), symbol: "bt.bundle", keywords: String(localized: "bundle 보따리 send")) {
                BottariBundle.shared.send(to: side, in: workspace)
            },
            PaletteCommand(id: "reload", title: String(localized: "새로고침"), subtitle: "⌘R", symbol: "arrow.clockwise", keywords: "reload refresh") {
                Task { await pane.reload() }
            },
            PaletteCommand(id: "hidden", title: pane.showsHiddenFiles ? String(localized: "숨김 파일 감추기") : String(localized: "숨김 파일 보기"), symbol: "eye", keywords: "hidden dotfiles") {
                pane.showsHiddenFiles.toggle()
            },
            PaletteCommand(id: "transfers", title: String(localized: "전송 센터 열기"), symbol: "bt.transfer", keywords: String(localized: "transfers queue 전송")) {
                openWindow(id: "transfers")
            },
            PaletteCommand(id: "inspector", title: workspace.showsInspector ? String(localized: "미리보기 닫기") : String(localized: "미리보기 열기"), symbol: "bt.inspector", keywords: String(localized: "inspector preview 미리보기")) {
                workspace.showsInspector.toggle()
            },
            PaletteCommand(id: "tunnels", title: String(localized: "터널 관리"), symbol: "bt.tunnel", keywords: String(localized: "tunnel vpn proxy socks 터널")) {
                openWindow(id: "tunnels")
            },
            PaletteCommand(id: "settings", title: String(localized: "설정"), subtitle: "⌘,", symbol: "bt.settings", keywords: String(localized: "settings preferences theme 테마 단축키 icloud")) {
                openSettings()
            },
        ]
        if pane.provider is SFTPFileProvider {
            list.append(PaletteCommand(id: "terminal", title: String(localized: "SSH 터미널 열기"), subtitle: "⌃`", symbol: "bt.terminal", keywords: String(localized: "ssh terminal shell 터미널")) {
                workspace.openTerminal(in: side)
            })
            if pane.site?.remoteScreen != nil {
                list.append(PaletteCommand(id: "screen", title: String(localized: "원격 화면 열기"), symbol: "bt.screen", keywords: String(localized: "vnc screen remote 원격")) {
                    workspace.openScreen(in: side)
                })
            }
        }
        // Nothing to act on: leave out what would silently do nothing.
        if selection.isEmpty {
            list.removeAll { ["copy-other", "move-other", "bundle"].contains($0.id) }
        }
        if BottariBundle.shared.entries.isEmpty {
            list.removeAll { $0.id == "bundle-send" }
        }
        for profile in TunnelStore.shared.profiles {
            let active = TunnelStore.shared.state(profile.id).isActive
            list.append(PaletteCommand(id: "tunnel-\(profile.id)", title: String(localized: "터널 \(profile.name) \(active ? String(localized: "끄기") : String(localized: "켜기"))"), subtitle: profile.mode.title, symbol: "point.3.filled.connected.trianglepath.dotted", keywords: String(localized: "tunnel vpn 터널")) {
                TunnelStore.shared.toggle(profile.id)
            })
        }
        return list
    }
}
