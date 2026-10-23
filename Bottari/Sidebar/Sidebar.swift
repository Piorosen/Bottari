import BottariCore
import BottariSFTP
import SwiftUI

/// Places to open in the active pane, and the bundle (보따리) underneath.
struct Sidebar: View {
    let workspace: Workspace
    @State private var isDropTarget = false
    @State private var presetName = ""
    @State private var namingPreset = false

    private var bundle: BottariBundle { .shared }
    private var sites: [SavedSite] { AppServices.sites.sites }

    private static let macFolders: [(String, String, String)] = [
        ("홈", "house", ""), ("데스크탑", "menubar.dock.rectangle", "Desktop"), ("문서", "doc", "Documents"),
        ("다운로드", "arrow.down.circle", "Downloads"),
    ]

    var body: some View {
        List {
            Section("이 Mac") {
                ForEach(Self.macFolders, id: \.0) { name, symbol, folder in
                    Button {
                        workspace.openOnMac(RemotePath(NSHomeDirectory()).appending(folder))
                    } label: {
                        Label(name, systemImage: symbol)
                    }
                }
                Button {
                    workspace.openOnMac("/Applications")
                } label: {
                    Label("응용 프로그램", systemImage: "square.grid.2x2")
                }
                if let iCloud = LocalFileProvider.iCloudDrive {
                    Button {
                        workspace.openOnMac(iCloud)
                    } label: {
                        Label("iCloud Drive", systemImage: "icloud")
                    }
                }
                ForEach(Favorites.shared.items) { favorite in
                    Button {
                        workspace.open(favorite)
                    } label: {
                        Label(favorite.name, systemImage: favorite.siteID == nil ? "folder" : "folder.badge.gearshape")
                    }
                    .contextMenu {
                        Button("사이드바에서 빼기", role: .destructive) { Favorites.shared.remove(favorite.id) }
                    }
                }
            }
            siteSection("서버", sites.filter(\.isSFTP))
            siteSection("클라우드", sites.filter { !$0.isSFTP })
            bundleSection
        }
        .listStyle(.sidebar)
        .buttonStyle(.plain)
        .alert("보따리 프리셋 이름", isPresented: $namingPreset) {
            TextField("예: 배포 보따리", text: $presetName)
            Button("저장") {
                if !presetName.isEmpty { bundle.saveAsPreset(named: presetName) }
                presetName = ""
            }
            Button("취소", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func siteSection(_ title: String, _ sites: [SavedSite]) -> some View {
        if !sites.isEmpty {
            Section(title) {
                ForEach(sites) { site in
                    Button {
                        workspace.open(site)
                    } label: {
                        HStack {
                            Label(site.name, systemImage: site.symbol)
                                .foregroundStyle(site.tag == .prod ? SavedSite.Tag.prod.color : .primary)
                            Spacer()
                            if let tag = site.tag {
                                TagChip(tag: tag)
                            }
                            if workspace.isOpen(site) {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 6, height: 6)
                                    .help("패인에서 열려 있어요")
                            }
                        }
                    }
                }
            }
        }
    }

    private var bundleSection: some View {
        Section {
            if bundle.entries.isEmpty {
                Text("⌘B로 담거나 여기로 끌어다 놓으세요. 여러 서버의 파일을 모아 한 번에 보내요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(bundle.entries) { entry in
                HStack(spacing: 6) {
                    Image(systemName: entry.item.isDirectory ? "folder" : "doc")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.item.name)
                            .lineLimit(1)
                        Text(entry.sourceName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        bundle.remove(entry.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .help("보따리에서 빼기")
                }
            }
            if !bundle.entries.isEmpty {
                HStack {
                    Button("지금 패인으로 보내기") {
                        bundle.send(to: workspace.activeSide, in: workspace)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Button("비우기") { bundle.clear() }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                }
            }
            Menu("프리셋") {
                Button("지금 보따리를 프리셋으로 저장…") { namingPreset = true }
                    .disabled(bundle.entries.isEmpty)
                if !bundle.presets.isEmpty { Divider() }
                ForEach(bundle.presets) { preset in
                    Menu(preset.name) {
                        Button("담기") {
                            Task {
                                let missing = await bundle.load(preset)
                                if !missing.isEmpty { workspace.refusal = "찾지 못한 항목: \(missing.joined(separator: ", "))" }
                            }
                        }
                        Button("지우기", role: .destructive) { bundle.deletePreset(preset.id) }
                    }
                }
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        } header: {
            Label("보따리\(bundle.entries.isEmpty ? "" : " · \(bundle.entries.count)개")", systemImage: "shippingbox")
        }
        .listRowBackground(isDropTarget ? Color.accentColor.opacity(0.12) : nil)
        .onDrop(of: [.utf8PlainText, .fileURL], isTargeted: $isDropTarget) { providers in
            workspace.dropIntoBundle(providers)
        }
    }
}
