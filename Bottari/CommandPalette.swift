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

/// "폴더 이동, 서버 연결, 명령 실행…": a search box over places, sites and
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
                TextField("폴더 이동, 서버 연결, 명령 실행…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
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
                            Text("일치하는 항목이 없어요")
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
                Text("↵ 실행 · ↑↓ 고르기 · esc 닫기")
                Spacer()
                Text("대상: \(workspace.pane(workspace.activeSide).provider.displayName) 패인")
            }
            .font(.caption)
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
            Image(systemName: command.symbol)
                .frame(width: 22)
                .foregroundStyle(isSelected ? .white : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(command.title)
                if !command.subtitle.isEmpty {
                    Text(command.subtitle)
                        .font(.caption)
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
            list.append(PaletteCommand(id: "path", title: "이 폴더로 이동: \(path.string)", subtitle: pane.provider.displayName, symbol: "arrow.right.circle", keywords: trimmed) {
                Task { await pane.open(path) }
            })
        }

        for site in AppServices.sites.sites {
            list.append(PaletteCommand(id: "site-\(site.id)", title: "\(site.name) 열기", subtitle: site.summary, symbol: site.symbol, keywords: "연결 connect \(site.tag?.label ?? "")") {
                workspace.open(site)
            })
        }
        let home = RemotePath(NSHomeDirectory())
        for (name, folder) in [("홈", ""), ("데스크탑", "Desktop"), ("문서", "Documents"), ("다운로드", "Downloads")] {
            list.append(PaletteCommand(id: "mac-\(name)", title: name, subtitle: "이 Mac", symbol: "folder", keywords: "mac \(folder.lowercased())") {
                workspace.openOnMac(home.appending(folder))
            })
        }
        if let iCloud = LocalFileProvider.iCloudDrive {
            list.append(PaletteCommand(id: "icloud", title: "iCloud Drive", subtitle: "이 Mac", symbol: "icloud", keywords: "icloud") {
                workspace.openOnMac(iCloud)
            })
        }
        for favorite in Favorites.shared.items {
            list.append(PaletteCommand(id: "favorite-\(favorite.id)", title: favorite.name, subtitle: favorite.path.string, symbol: "star", keywords: "즐겨찾기 favorite") {
                workspace.open(favorite)
            })
        }

        let selection = pane.selectedItems
        let other = workspace.pane(side.other).provider.displayName
        list += [
            PaletteCommand(id: "new-folder", title: "새 폴더", subtitle: keys(.newFolder), symbol: "folder.badge.plus", keywords: "new folder mkdir") {
                workspace.makeFolder(in: side)
            },
            PaletteCommand(id: "copy-other", title: "선택 항목을 \(other)에 복사", subtitle: "\(selection.count)개 선택 · \(keys(.copyToOther))", symbol: "arrow.right.doc.on.clipboard", keywords: "copy 복사 전송") {
                workspace.send(selection, from: side, kind: .copy)
            },
            PaletteCommand(id: "move-other", title: "선택 항목을 \(other)(으)로 이동", subtitle: "\(selection.count)개 선택 · \(keys(.moveToOther))", symbol: "arrow.right", keywords: "move 이동 전송") {
                workspace.send(selection, from: side, kind: .move)
            },
            PaletteCommand(id: "bundle", title: "선택 항목을 보따리에 담기", subtitle: keys(.bundle), symbol: "shippingbox", keywords: "bundle 보따리") {
                workspace.addToBundle(from: side)
            },
            PaletteCommand(id: "bundle-send", title: "보따리를 지금 패인으로 보내기", subtitle: "\(BottariBundle.shared.entries.count)개", symbol: "shippingbox.and.arrow.backward", keywords: "bundle 보따리 send") {
                BottariBundle.shared.send(to: side, in: workspace)
            },
            PaletteCommand(id: "reload", title: "새로고침", subtitle: "⌘R", symbol: "arrow.clockwise", keywords: "reload refresh") {
                Task { await pane.reload() }
            },
            PaletteCommand(id: "hidden", title: pane.showsHiddenFiles ? "숨김 파일 감추기" : "숨김 파일 보기", symbol: "eye", keywords: "hidden dotfiles") {
                pane.showsHiddenFiles.toggle()
            },
            PaletteCommand(id: "transfers", title: workspace.showsTransfers ? "전송 목록 닫기" : "전송 목록 열기", symbol: "arrow.up.arrow.down", keywords: "transfers queue 전송") {
                workspace.showsTransfers.toggle()
            },
            PaletteCommand(id: "tunnels", title: "터널 관리", symbol: "point.3.connected.trianglepath.dotted", keywords: "tunnel vpn proxy socks 터널") {
                openWindow(id: "tunnels")
            },
            PaletteCommand(id: "settings", title: "설정", subtitle: "⌘,", symbol: "gearshape", keywords: "settings preferences theme 테마 단축키 icloud") {
                openSettings()
            },
        ]
        if pane.provider is SFTPFileProvider {
            list.append(PaletteCommand(id: "terminal", title: "여기서 SSH 터미널 열기", subtitle: "⌃`", symbol: "terminal", keywords: "ssh terminal shell 터미널") {
                workspace.openTerminal(in: side)
            })
            if pane.site?.remoteScreen != nil {
                list.append(PaletteCommand(id: "screen", title: "원격 화면 열기", symbol: "display", keywords: "vnc screen remote 원격") {
                    workspace.openScreen(in: side)
                })
            }
        }
        for profile in TunnelStore.shared.profiles {
            let active = TunnelStore.shared.state(profile.id).isActive
            list.append(PaletteCommand(id: "tunnel-\(profile.id)", title: "터널 \(profile.name) \(active ? "끄기" : "켜기")", subtitle: profile.mode.title, symbol: "point.3.filled.connected.trianglepath.dotted", keywords: "tunnel vpn 터널") {
                TunnelStore.shared.toggle(profile.id)
            })
        }
        return list
    }
}
