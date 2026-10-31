import BottariCore
import BottariSFTP
import SystemConfiguration
import SwiftUI

/// Places to open in the active pane — favorites, servers, clouds and this
/// Mac — with the bundle (보따리) underneath.
struct Sidebar: View {
    let workspace: Workspace
    @AppStorage("sidebar.showsICloudDrive") private var showsICloudDrive = true

    private var library: SiteLibrary { workspace.left.library }
    private var sites: [SavedSite] { library.sites }
    private var activePane: PaneModel { workspace.pane(workspace.activeSide) }

    private static let macFolders: [(String, String, String)] = [
        (MacFolder.desktop, "bt.desktop", "Desktop"), (MacFolder.documents, "bt.document", "Documents"),
        (MacFolder.downloads, "bt.download", "Downloads"),
    ]

    private static let computerName = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? String(localized: "이 Mac")

    /// Where a favorite lives: its site's name, this Mac, or a site deleted since.
    private func favoritePlace(_ favorite: Favorites.Favorite) -> String {
        guard let siteID = favorite.siteID else { return String(localized: "이 Mac") }
        return library.site(siteID)?.name ?? String(localized: "삭제된 연결")
    }

    var body: some View {
        VStack(spacing: 0) {
            OpenTargetPicker(workspace: workspace)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !Favorites.shared.items.isEmpty {
                        group(String(localized: "즐겨찾기")) {
                            ForEach(Favorites.shared.items) { favorite in
                                SidebarRow(symbol: "bt.star", title: favorite.name, isCurrent: isCurrent(favorite)) {
                                    Text(favoritePlace(favorite))
                                        .font(.themeMono(.caption2))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                } action: {
                                    workspace.open(favorite)
                                }
                                .contextMenu {
                                    Button("사이드바에서 제거", role: .destructive) { Favorites.shared.remove(favorite.id) }
                                }
                            }
                        }
                    }
                    let servers = sites.filter(\.isSFTP)
                    if !servers.isEmpty {
                        group(String(localized: "서버")) {
                            ForEach(servers, content: siteRow)
                        }
                    }
                    let clouds = sites.filter { !$0.isSFTP }
                    let iCloud = showsICloudDrive ? LocalFileProvider.iCloudDrive : nil
                    if !clouds.isEmpty || iCloud != nil {
                        group(String(localized: "클라우드")) {
                            if let iCloud {
                                SidebarRow(symbol: "bt.cloud", title: "iCloud Drive", isCurrent: activePane.isLocal && activePane.path.string.hasPrefix(iCloud.string)) {
                                    EmptyView()
                                } action: {
                                    workspace.openOnMac(iCloud)
                                }
                            }
                            ForEach(clouds, content: siteRow)
                        }
                    }
                    group(String(localized: "이 Mac")) {
                        let home = RemotePath(UserHome.path)
                        SidebarRow(symbol: "bt.mac", title: Self.computerName, isCurrent: activePane.isLocal && activePane.path == home) {
                            EmptyView()
                        } action: {
                            workspace.openOnMac(home)
                        }
                        ForEach(Self.macFolders, id: \.0) { name, symbol, folder in
                            let path = home.appending(folder)
                            SidebarRow(symbol: symbol, title: name, isCurrent: activePane.isLocal && activePane.path == path) {
                                EmptyView()
                            } action: {
                                workspace.openOnMac(path)
                            }
                            .contextMenu {
                                Button("왼쪽 패인에서 열기") { workspace.openOnMac(path, in: .left) }
                                Button("오른쪽 패인에서 열기") { workspace.openOnMac(path, in: .right) }
                            }
                        }
                        SidebarRow(symbol: "bt.apps", title: String(localized: "응용 프로그램"), isCurrent: activePane.isLocal && activePane.path == "/Applications") {
                            EmptyView()
                        } action: {
                            workspace.openOnMac("/Applications")
                        }
                    }
                    Button {
                        workspace.siteManager = SiteManagerRequest()
                    } label: {
                        Label("연결 추가", glyph: "bt.plus", size: 14)
                            .font(.ui(.callout))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.never)
            BundleCard(workspace: workspace)
                .padding(10)
        }
        .background(Palette.panel2)
    }

    private func group(_ title: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionLabel(title)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            rows()
        }
    }

    private func siteRow(_ site: SavedSite) -> some View {
        let open = workspace.isOpen(site)
        let connecting = workspace.left.connectingSite?.id == site.id || workspace.right.connectingSite?.id == site.id
        return SidebarRow(symbol: site.symbol, title: site.name, isCurrent: activePane.site?.id == site.id, isBold: open,
                          tint: site.tag == .prod ? SavedSite.Tag.prod.color : nil) {
            HStack(spacing: 6) {
                if let tag = site.tag {
                    TagChip.outlined(tag)
                }
                // Only open connections get a dot, so they stand out in a long list.
                if connecting {
                    ProgressView()
                        .controlSize(.mini)
                        .help("연결하는 중")
                        .transition(.opacity)
                } else if open {
                    StatusDot(on: true)
                        .help("연결됨")
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .motion(value: connecting)
            .motion(value: open)
        } action: {
            workspace.open(site)
        }
        .contextMenu {
            Button("왼쪽 패인에서 열기") {
                workspace.activeSide = .left
                workspace.connect(site, in: .left)
            }
            Button("오른쪽 패인에서 열기") {
                workspace.activeSide = .right
                workspace.connect(site, in: .right)
            }
            Divider()
            Button("연결 관리에서 열기") { workspace.siteManager = SiteManagerRequest(selection: site.id) }
        }
    }

    private func isCurrent(_ favorite: Favorites.Favorite) -> Bool {
        activePane.path == favorite.path && activePane.site?.id == favorite.siteID && (favorite.siteID != nil || activePane.isLocal)
    }
}

/// Which pane the sidebar opens places in. It is the active pane, so
/// clicking a pane changes it too; this says so, and lets it be picked here.
private struct OpenTargetPicker: View {
    let workspace: Workspace
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 8) {
            Text("여는 곳")
                .font(.ui(.caption, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            HStack(spacing: 0) {
                segment(.left, symbol: "rectangle.lefthalf.filled", title: String(localized: "왼쪽"))
                segment(.right, symbol: "rectangle.righthalf.filled", title: String(localized: "오른쪽"))
            }
            .padding(2)
            .background(Palette.panel, in: .rect(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.line))
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 2)
        .help("사이드바에서 고른 서버나 폴더가 열릴 패인입니다. 패인을 클릭해도 바뀝니다.")
        .motion(value: workspace.activeSide)
    }

    private func segment(_ side: PaneSide, symbol: String, title: String) -> some View {
        let isOn = workspace.activeSide == side
        return Button {
            workspace.activeSide = side
            workspace.focusRequest = side
        } label: {
            Label(title, systemImage: symbol)
                .labelStyle(.titleAndIcon)
                .font(.ui(.caption, weight: isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? AnyShapeStyle(Color.themeAccent) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background {
                    // One highlight that slides to the chosen side.
                    if isOn {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Palette.selection)
                            .matchedGeometryEffect(id: "target", in: highlight)
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(side == .left ? String(localized: "왼쪽 패인에 열기") : String(localized: "오른쪽 패인에 열기"))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// One place in the sidebar.
private struct SidebarRow<Accessory: View>: View {
    let symbol: String
    let title: String
    var isCurrent = false
    var isBold = false
    var tint: Color?
    @ViewBuilder let accessory: Accessory
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Glyph(symbol, size: 16)
                    .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
                    .frame(width: 18)
                Text(title)
                    .font(.ui(.body, weight: isBold || isCurrent ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 4)
                accessory
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(isCurrent ? Palette.selection : hovering ? Palette.line.opacity(0.5) : .clear, in: .rect(cornerRadius: 7))
            .contentShape(.rect)
            .motion(Motion.quick, value: hovering)
            .motion(value: isCurrent)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The bundle the app is named after, as a card at the bottom of the sidebar:
/// files gathered from anywhere, unpacked into the active pane at once.
private struct BundleCard: View {
    let workspace: Workspace
    @State private var isDropTarget = false
    @State private var presetName = ""
    @State private var namingPreset = false

    private var bundle: BottariBundle { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Glyph("bt.bundle", size: 17)
                    .foregroundStyle(Color.themeAccent)
                Text("보따리").font(.ui(.body, weight: .semibold))
                Spacer()
                if !bundle.entries.isEmpty {
                    Text("\(bundle.entries.count)")
                        .font(.ui(.caption, weight: .semibold))
                        .foregroundStyle(Color.themeAccent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(Palette.selection, in: .capsule)
                }
                Menu {
                    Button("프리셋으로 저장…") { namingPreset = true }
                        .disabled(bundle.entries.isEmpty)
                    if !bundle.presets.isEmpty {
                        Section("프리셋 담기") {
                            ForEach(bundle.presets) { preset in
                                Button(preset.name) {
                                    Task {
                                        let missing = await bundle.load(preset)
                                        if !missing.isEmpty { workspace.refusal = String(localized: "찾지 못한 항목: \(missing.joined(separator: ", "))") }
                                    }
                                }
                            }
                        }
                        Menu("프리셋 삭제") {
                            ForEach(bundle.presets) { preset in
                                Button(preset.name, role: .destructive) { bundle.deletePreset(preset.id) }
                            }
                        }
                    }
                    Divider()
                    Button("비우기") { bundle.clear() }
                        .disabled(bundle.entries.isEmpty)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .iconHelp(String(localized: "보따리 메뉴"))
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
            }
            if bundle.entries.isEmpty {
                Text("⌘B 또는 끌어다 놓아 담기")
                    .font(.ui(.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(bundle.entries.prefix(6)) { entry in
                HStack(spacing: 6) {
                    Image(systemName: entry.item.glyph)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    Text(entry.item.name)
                        .font(.ui(.callout))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(entry.sourceName)
                        .font(.themeMono(.caption2))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button {
                        bundle.remove(entry.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("보따리에서 제거")
                }
            }
            if bundle.entries.count > 6 {
                Text("외 \(bundle.entries.count - 6)개").font(.ui(.caption)).foregroundStyle(.secondary)
            }
            if !bundle.entries.isEmpty {
                Button("\(targetName)에 풀기") {
                    bundle.send(to: workspace.activeSide, in: workspace)
                }
                .buttonStyle(PanelButtonStyle(prominent: true))
                .padding(.top, 2)
                Button("프리셋으로 저장") { namingPreset = true }
                    .buttonStyle(PanelButtonStyle())
            }
        }
        .padding(12)
        .card(highlighted: isDropTarget)
        // Items going in and coming out ease, rather than the card jumping.
        .motion(value: bundle.entries.map(\.id))
        .onDrop(of: [.bottariPaneItems, .fileURL], isTargeted: $isDropTarget) { providers in
            workspace.dropIntoBundle(providers)
        }
        .alert("보따리 프리셋 이름", isPresented: $namingPreset) {
            TextField("예: 배포 보따리", text: $presetName)
            Button("저장") {
                if !presetName.isEmpty { bundle.saveAsPreset(named: presetName) }
                presetName = ""
            }
            Button("취소", role: .cancel) {}
        }
    }

    private var targetName: String {
        let pane = workspace.pane(workspace.activeSide)
        return pane.site?.name ?? (pane.isLocal ? pane.path.name : pane.provider.displayName)
    }
}

/// The names of the Mac's own folders. Keys of their own, since "다운로드" alone
/// is also the transfer direction, which English calls something else.
enum MacFolder {
    static let desktop = String(localized: "folder.desktop", defaultValue: "데스크탑")
    static let documents = String(localized: "folder.documents", defaultValue: "문서")
    static let downloads = String(localized: "folder.downloads", defaultValue: "다운로드")
}
