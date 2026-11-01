import AppKit
import BottariCore
import BottariSFTP
import BottariTransfer
import SwiftUI
import UniformTypeIdentifiers

/// ⌘, : looks, keys, iCloud sync, transfers and connections, picked from a
/// list on the left as the design shows.
struct SettingsView: View {
    @State private var section = SettingsSection.look

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsSection.allCases, id: \.self) { item in
                    Button {
                        section = item
                    } label: {
                        Label(item.title, systemImage: item.symbol)
                            .font(.ui(.body, weight: section == item ? .semibold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(section == item ? Palette.selection : .clear, in: .rect(cornerRadius: 7))
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .frame(width: 190)
            .card()
            Group {
                switch section {
                case .look: AppearanceSettings()
                case .keys: KeySettings()
                case .sync: SyncSettings(sync: .shared)
                case .transfers: GeneralSettings()
                case .connections: ConnectionSettings()
                case .access: FolderAccessSettings()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(12)
        .frame(width: 1180, height: 780)
        .background(Palette.background)
        .themed()
    }
}

enum SettingsSection: CaseIterable {
    case look, keys, sync, transfers, connections, access

    var title: String {
        switch self {
        case .look: String(localized: "모양")
        case .keys: String(localized: "단축키")
        case .sync: String(localized: "iCloud 동기화")
        case .transfers: String(localized: "전송")
        case .connections: String(localized: "연결")
        case .access: String(localized: "폴더 접근")
        }
    }

    var symbol: String {
        switch self {
        case .look: "paintpalette"
        case .keys: "keyboard"
        case .sync: "icloud"
        case .transfers: "arrow.up.arrow.down"
        case .connections: "server.rack"
        case .access: "lock.open"
        }
    }
}

extension Notification.Name {
    /// Opens a folder on the Mac in the main window's active pane; the object is its path.
    static let openOnMac = Notification.Name("BottariOpenOnMac")
}

/// The folders the App Sandbox lets Bottari into because the user allowed them.
private struct FolderAccessSettings: View {
    @State private var folders = FolderAccess.shared.paths

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsGroup(
                    String(localized: "허용한 폴더"),
                    footer: String(localized: "Bottari는 macOS 샌드박스 안에서 실행되어, 여기 있는 폴더와 다운로드 폴더만 열 수 있습니다. 홈 폴더를 허용하면 그 안의 모든 폴더를 쓸 수 있습니다.")
                ) {
                    if folders.isEmpty {
                        Text("아직 허용한 폴더가 없습니다.")
                            .font(.ui(.callout))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(folders, id: \.self) { folder in
                        HStack {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text(UserHome.abbreviate(folder.string))
                                .font(.themeMono(.body))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button("허용 취소") {
                                FolderAccess.shared.forget(folder)
                                folders = FolderAccess.shared.paths
                            }
                            .buttonStyle(PanelButtonStyle())
                            .fixedSize()
                        }
                    }
                    HStack(spacing: 8) {
                        Button("홈 폴더 허용…") { allow(RemotePath(UserHome.path)) }
                            .buttonStyle(PanelButtonStyle(prominent: true))
                        Button("다른 폴더 허용…") { allow(RemotePath("/")) }
                            .buttonStyle(PanelButtonStyle())
                    }
                    .fixedSize()
                }
                SettingsGroup(
                    String(localized: "SSH 설정과 키"),
                    footer: String(localized: "~/.ssh의 config, known_hosts, 개인 키를 읽으려면 홈 폴더나 ~/.ssh 폴더를 허용하십시오. Bottari는 SSH 에이전트(1Password 등)와 ProxyCommand 대신 키 파일로 로그인하고 점프 호스트로 거쳐 갑니다.")
                ) {
                    HStack {
                        Text(FolderAccess.shared.covers(RemotePath(UserHome.path).appending(".ssh"))
                            ? String(localized: "~/.ssh를 읽을 수 있습니다")
                            : String(localized: "~/.ssh를 아직 읽을 수 없습니다"))
                            .font(.ui(.body, weight: .medium))
                        Spacer()
                        Button("~/.ssh 허용…") {
                            FolderAccessPanel.ask(startingAt: RemotePath(UserHome.path).appending(".ssh"), showingHiddenFiles: true)
                            folders = FolderAccess.shared.paths
                        }
                        .buttonStyle(PanelButtonStyle())
                        .fixedSize()
                    }
                }
            }
            .padding(.bottom, 12)
        }
        .scrollIndicators(.never)
    }

    private func allow(_ start: RemotePath) {
        FolderAccessPanel.ask(startingAt: start)
        folders = FolderAccess.shared.paths
    }
}

/// A titled group of settings in a card.
private struct SettingsGroup<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder let content: Content

    init(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title)
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
            if let footer {
                Text(footer)
                    .font(.ui(.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A switch with its title and what it does, inside a settings card.
private struct SettingSwitch: View {
    let title: String
    var detail: String?
    var badge: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.ui(.body, weight: .medium))
                if let detail {
                    Text(detail).font(.ui(.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if let badge {
                Badge(badge, color: Color(light: 0x8A6100, dark: 0xE0B44C))
            }
        }
    }
}

// MARK: - 전송

struct GeneralSettings: View {
    @AppStorage(TransferSettings.maxConcurrentKey) private var maxConcurrent = 3
    @AppStorage(TransferSettings.conflictPolicyKey) private var policy: ConflictPolicy = .ask
    @AppStorage(TransferSettings.verifiesChecksumsKey) private var verifiesChecksums = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsGroup(String(localized: "전송")) {
                    HStack {
                        Text("최대 동시 전송").font(.ui(.body, weight: .medium))
                        Spacer()
                        Button { maxConcurrent = max(1, maxConcurrent - 1) } label: { Image(systemName: "minus") }
                            .iconHelp(String(localized: "동시 전송 줄이기"))
                            .buttonStyle(IconButtonStyle())
                        Text("\(maxConcurrent)").font(.themeMono(.body)).frame(minWidth: 24)
                        Button { maxConcurrent = min(8, maxConcurrent + 1) } label: { Image(systemName: "plus") }
                            .iconHelp(String(localized: "동시 전송 늘리기"))
                            .buttonStyle(IconButtonStyle())
                    }
                    Rectangle().fill(Palette.line).frame(height: 1)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("같은 이름의 파일이 있으면").font(.ui(.body, weight: .medium))
                        HStack(spacing: 6) {
                            ForEach(ConflictPolicy.allCases, id: \.self) { option in
                                Button(option.label) { policy = option }
                                    .buttonStyle(ChoiceButtonStyle(isOn: policy == option))
                                    .fixedSize()
                            }
                        }
                    }
                    Rectangle().fill(Palette.line).frame(height: 1)
                    SettingSwitch(title: String(localized: "보낸 뒤 체크섬 비교"), detail: String(localized: "SHA-256 사용, 서버는 명령을 실행할 수 있는 경우에만 지원"), isOn: $verifiesChecksums)
                }
                SettingsGroup(String(localized: "업데이트")) {
                    HStack {
                        Text("버전").font(.ui(.body, weight: .medium))
                        Spacer()
                        Text(Diagnostics.version).font(.themeMono(.body))
                    }
                    Text("새 버전은 TestFlight에서 받습니다.")
                        .font(.ui(.caption))
                        .foregroundStyle(.secondary)
                    AcknowledgementsCommand()
                        .buttonStyle(PanelButtonStyle())
                        .fixedSize()
                }
            }
        }
        .scrollIndicators(.never)
        .onChange(of: maxConcurrent) { AppServices.transfers.maxConcurrentTransfers = maxConcurrent }
        .onChange(of: verifiesChecksums) { AppServices.transfers.verifiesChecksums = verifiesChecksums }
    }
}

// MARK: - 연결

/// Host keys trusted on first connection, to forget one after a server is reinstalled.
struct ConnectionSettings: View {
    @State private var keys = AppServices.knownHosts.remembered
    @AppStorage(KeySetupOffers.enabledKey) private var offersKeys = true
    @State private var declinesForgotten = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsGroup(String(localized: "알려진 호스트 키"), footer: String(localized: "처음 연결할 때 서버 키를 저장하고, 이후 키가 다르면 연결하지 않습니다. 서버를 다시 설치한 경우 여기서 키를 삭제한 후 다시 연결하십시오.")) {
                    if keys.isEmpty {
                        Text("저장된 키 없음").font(.ui(.callout)).foregroundStyle(.secondary)
                    }
                    ForEach(keys, id: \.host) { entry in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.host).font(.themeMono(.callout))
                                Text(entry.key.prefix(60) + (entry.key.count > 60 ? "…" : ""))
                                    .font(.themeMono(.caption2))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button("삭제") {
                                AppServices.knownHosts.forget(hostKeyID: entry.host)
                                keys = AppServices.knownHosts.remembered
                            }
                            .buttonStyle(PanelButtonStyle(destructive: true))
                            .fixedSize()
                        }
                        if entry.host != keys.last?.host {
                            Rectangle().fill(Palette.line).frame(height: 1)
                        }
                    }
                }
                SettingsGroup(
                    String(localized: "SSH 키"),
                    footer: String(localized: "Bottari 키는 이 Mac에서 만들어 서버의 ~/.ssh/authorized_keys에 넣은 키입니다. 개인 키는 이 Mac의 키체인에만 있어서, 다른 Mac에서는 비밀번호로 한 번 로그인한 뒤 그 Mac의 키를 따로 만듭니다.")
                ) {
                    SettingSwitch(
                        title: String(localized: "비밀번호로 로그인하면 SSH 키로 바꾸기 제안"),
                        detail: String(localized: "키를 만들어 서버에 넣고, 키로 로그인되면 저장된 비밀번호를 지울 수 있습니다"),
                        isOn: $offersKeys
                    )
                    Button(declinesForgotten ? String(localized: "다시 묻습니다") : String(localized: "‘다시 묻지 않기’ 한 서버에도 다시 묻기")) {
                        KeySetupOffers.forgetDeclines()
                        declinesForgotten = true
                    }
                    .buttonStyle(PanelButtonStyle())
                    .fixedSize()
                    .disabled(declinesForgotten)
                    let keyed = AppServices.sites.sites.filter { $0.authentication == .storedKey }
                    if !keyed.isEmpty {
                        Rectangle().fill(Palette.line).frame(height: 1)
                        ForEach(keyed) { site in
                            HStack(spacing: 10) {
                                Text(site.name).font(.ui(.callout, weight: .medium))
                                Spacer()
                                Text(AppServices.sites.storedKey(of: site).map { "\($0.kind.title) · \($0.fingerprint)" } ?? String(localized: "이 Mac에는 키 없음"))
                                    .font(.themeMono(.caption))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }
                SettingsGroup(String(localized: "비밀번호와 키")) {
                    Label("비밀번호, 키 암호, Bottari 키는 macOS 키체인에만 저장됩니다. 연결 목록 파일과 iCloud 동기화 파일에는 포함되지 않습니다.", systemImage: "lock.fill")
                        .font(.ui(.callout))
                }
            }
        }
        .scrollIndicators(.never)
    }
}

// MARK: - 모양

struct AppearanceSettings: View {
    @State private var accentText = ""
    @State private var fileError: String?
    private var store: ThemeStore { .shared }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SettingsGroup(String(localized: "테마")) {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 12) {
                            ForEach(Theme.presets, id: \.theme.name) { preset in
                                Button {
                                    store.choose(preset: preset.theme)
                                } label: {
                                    PresetCard(theme: preset.theme, subtitle: preset.subtitle, isSelected: store.current.presetName == preset.theme.name)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    SettingsGroup(String(localized: "강조 색")) {
                        HStack(spacing: 10) {
                            swatch(nil, label: String(localized: "시스템"))
                            ForEach(Theme.accents, id: \.hex) { accent in
                                swatch(accent.hex, label: accent.name)
                            }
                            Rectangle().fill(Palette.line).frame(width: 1, height: 20)
                            ColorPicker(String(localized: "사용자 지정 색"), selection: accentBinding, supportsOpacity: false)
                                .labelsHidden()
                            TextField("색 코드", text: $accentText, prompt: Text(verbatim: "#3651C9"))
                                .designField(mono: true)
                                .frame(width: 100)
                                .onSubmit(applyAccentText)
                        }
                    }
                    SettingsGroup(String(localized: "글자와 간격")) {
                        HStack {
                            Text("밀도").font(.ui(.body, weight: .medium))
                            Spacer()
                            ForEach(Theme.Density.allCases, id: \.self) { density in
                                Button(density.title) { store.current.density = density }
                                    .buttonStyle(ChoiceButtonStyle(isOn: store.current.density == density))
                                    .fixedSize()
                            }
                        }
                        Rectangle().fill(Palette.line).frame(height: 1)
                        fontChoices(String(localized: "본문 글꼴"), system: String(localized: "시스템 (SF)"), choices: ThemeStore.uiFontChoices, selection: binding(\.font.ui), mono: false)
                        Rectangle().fill(Palette.line).frame(height: 1)
                        fontChoices(String(localized: "고정폭 글꼴 (경로, 크기, 코드)"), system: String(localized: "시스템 (SF Mono)"), choices: ThemeStore.monoFontChoices, selection: binding(\.font.mono), mono: true)
                        Rectangle().fill(Palette.line).frame(height: 1)
                        SettingSwitch(title: String(localized: "새 패인에서 숨김 파일 보기"), isOn: binding(\.list.showHidden))
                        SettingSwitch(title: String(localized: "Finder 아이콘 사용"), detail: String(localized: "선 아이콘 대신 Finder의 색 아이콘"), isOn: binding(\.list.finderIcons))
                    }
                    SettingsGroup(String(localized: "서버 태그 색")) {
                        ForEach(Theme.tagChoices, id: \.tag) { choice in
                            HStack(spacing: 10) {
                                TagChip(tag: choice.tag)
                                    .frame(width: 70, alignment: .leading)
                                ForEach(Array(choice.hexes.enumerated()), id: \.offset) { index, hex in
                                    let current = store.current.tags[choice.tag.label]
                                    let selected = current == hex || (current == nil && index == 0)
                                    Button {
                                        // The first is the design's own, with its hand-picked dark variant.
                                        store.current.tags[choice.tag.label] = index == 0 ? nil : hex
                                    } label: {
                                        Circle()
                                            .fill(Color(themeHex: hex, liftedInDark: true) ?? .gray)
                                            .frame(width: 18, height: 18)
                                            .padding(3)
                                            .overlay(Circle().strokeBorder(selected ? Color(themeHex: hex) ?? .gray : .clear, lineWidth: 2))
                                    }
                                    .buttonStyle(.plain)
                                    .help(hex)
                                }
                            }
                        }
                    }
                    themeFiles
                }
            }
            .scrollIndicators(.never)

            VStack(alignment: .leading, spacing: 12) {
                ThemePreview()
                    .padding(14)
                    .card()
            }
            .frame(width: 370)
        }
        .onAppear { accentText = store.current.colors.accent ?? "" }
        .onChange(of: store.current.colors.accent) { accentText = store.current.colors.accent ?? "" }
    }

    private var themeFiles: some View {
        SettingsGroup(String(localized: "테마 파일"), footer: String(localized: "\(UserHome.abbreviate(ThemeStore.shared.folder.path))/에 저장됨")) {
            HStack {
                Button("가져오기…", action: importTheme).buttonStyle(PanelButtonStyle()).fixedSize()
                Button("내보내기…", action: exportTheme).buttonStyle(PanelButtonStyle()).fixedSize()
                Spacer()
                Button("폴더 열기") {
                    try? FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(store.folder)
                }
                .buttonStyle(PanelButtonStyle())
                .fixedSize()
            }
            if let fileError {
                Label(fileError, systemImage: "exclamationmark.triangle.fill")
                    .font(.ui(.caption))
                    .foregroundStyle(.orange)
            }
            ForEach(store.saved) { theme in
                HStack {
                    Circle()
                        .fill(Color(themeHex: theme.colors.background ?? "#808080") ?? .gray)
                        .overlay(Circle().strokeBorder(Color(themeHex: theme.colors.accent ?? "#808080") ?? .gray, lineWidth: 3))
                        .frame(width: 16, height: 16)
                    Text(theme.name).font(.ui(.callout))
                    if theme == store.current {
                        Text("사용 중").font(.ui(.caption)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("적용") { store.current = theme }
                        .buttonStyle(PanelButtonStyle())
                        .fixedSize()
                        .disabled(theme == store.current)
                    Button {
                        store.delete(theme)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(IconButtonStyle())
                    .iconHelp(String(localized: "테마 파일 삭제"))
                }
            }
            DisclosureGroup("JSON 보기") {
                Text(store.json)
                    .font(.themeMono(.caption))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .well()
            }
            .font(.ui(.callout))
        }
    }

    private func swatch(_ hex: String?, label: String) -> some View {
        let selected = store.current.colors.accent?.uppercased() == hex?.uppercased()
        let fill: AnyShapeStyle = hex.flatMap { Color(themeHex: $0, liftedInDark: true) }.map(AnyShapeStyle.init)
            ?? AnyShapeStyle(AngularGradient(colors: [.red, .orange, .yellow, .green, .blue, .purple, .red], center: .center))
        return Button {
            store.current.colors.accent = hex
        } label: {
            Circle()
                .fill(fill)
                .frame(width: 20, height: 20)
                .padding(3)
                .overlay(Circle().strokeBorder(selected ? Palette.text.opacity(0.6) : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .help(label)
    }

    private var accentBinding: Binding<Color> {
        Binding(
            get: { store.accent },
            set: { store.current.colors.accent = NSColor($0).themeHex }
        )
    }

    private func applyAccentText() {
        let text = accentText.hasPrefix("#") ? accentText : "#" + accentText
        if NSColor(themeHex: text) != nil {
            store.current.colors.accent = text.uppercased()
        } else {
            accentText = store.current.colors.accent ?? ""
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<Theme, Value>) -> Binding<Value> {
        Binding(get: { store.current[keyPath: keyPath] }, set: { store.current[keyPath: keyPath] = $0 })
    }

    /// The fonts as cards written in themselves.
    private func fontChoices(_ title: String, system: String, choices: [String], selection: Binding<String?>, mono: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.ui(.body, weight: .medium))
            HStack(spacing: 8) {
                fontCard(nil, label: system, selection: selection, mono: mono)
                ForEach(choices, id: \.self) { family in
                    fontCard(family, label: family, selection: selection, mono: mono)
                }
                // A theme from elsewhere may name a font this Mac does not have.
                if let missing = selection.wrappedValue, !choices.contains(missing) {
                    fontCard(missing, label: String(localized: "\(missing) (설치 안 됨)"), selection: selection, mono: mono)
                }
            }
        }
    }

    private func fontCard(_ family: String?, label: String, selection: Binding<String?>, mono: Bool) -> some View {
        let selected = selection.wrappedValue == family
        return Button {
            selection.wrappedValue = family
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(mono ? "/var/www 2.8 KB" : String(localized: "가나다 Aa"))
                    .font(family.map { .custom($0, size: 15) } ?? .system(size: 15, design: mono ? .monospaced : .default))
                Text(label).font(.ui(.caption)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Palette.selection : Palette.panel, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.themeAccent : Palette.line, lineWidth: selected ? 1.5 : 1))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.directoryURL = store.folder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.importTheme(from: url)
            fileError = nil
        } catch {
            fileError = String(localized: "테마 파일을 읽을 수 없습니다: \(error.localizedDescription)")
        }
    }

    private func exportTheme() {
        try? FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.directoryURL = store.folder
        panel.nameFieldStringValue = store.current.name + ".json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.export(to: url)
            fileError = nil
        } catch {
            fileError = String(localized: "테마 파일을 저장할 수 없습니다: \(error.localizedDescription)")
        }
    }
}

/// A small picture of a preset's colours.
private struct PresetCard: View {
    let theme: Theme
    let subtitle: String
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if theme.colors.background == nil {
                    // The system theme: 종이 by day, 먹 by night.
                    HStack(spacing: 0) {
                        miniature(background: Color(themeHex: "#ECEEF2")!, panel: .white, line: Color(themeHex: "#DCE0E6")!, text: Color(themeHex: "#14171D")!)
                        miniature(background: Color(themeHex: "#0E1014")!, panel: Color(themeHex: "#15181E")!, line: Color(themeHex: "#272C35")!, text: Color(themeHex: "#E6E8EC")!)
                    }
                } else {
                    miniature(
                        background: Color(themeHex: theme.colors.background!) ?? .gray,
                        panel: Color(themeHex: theme.colors.panel ?? "#FFFFFF") ?? .white,
                        line: Color(themeHex: theme.colors.line ?? "#DDDDDD") ?? .gray,
                        text: Color(themeHex: theme.colors.text ?? "#000000") ?? .black
                    )
                }
            }
            .frame(height: 56)
            .clipShape(.rect(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(isSelected ? Color.themeAccent : Palette.line, lineWidth: isSelected ? 2 : 1))
            Text(theme.name).font(.ui(.callout, weight: isSelected ? .semibold : .regular))
            Text(subtitle).font(.ui(.caption)).foregroundStyle(.secondary)
        }
        .contentShape(.rect)
    }

    private func miniature(background: Color, panel: Color, line: Color, text: Color) -> some View {
        ZStack(alignment: .topLeading) {
            background
            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 1.5).fill(text.opacity(0.8)).frame(width: 28, height: 3)
                RoundedRectangle(cornerRadius: 1.5).fill(Color.themeAccent).frame(width: 40, height: 3)
                RoundedRectangle(cornerRadius: 1.5).fill(text.opacity(0.4)).frame(width: 22, height: 3)
            }
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(panel)
            .overlay(Rectangle().strokeBorder(line, lineWidth: 1))
            .padding(.leading, 14)
            .padding(.top, 8)
        }
    }
}

/// A miniature main window in the current theme.
struct ThemePreview: View {
    private var store: ThemeStore { .shared }

    private let rows: [(name: String, size: String, symbol: String, hidden: Bool)] = [
        ("assets", "—", "folder", false), ("nginx.conf", "2.8 KB", "doc.text", false),
        ("hero.png", "2.1 MB", "photo", false), ("promo.mp4", "48.2 MB", "film", false),
        (".htaccess", "312 B", "doc", true), ("db-2026-10-21.sql.gz", "1.2 GB", "archivebox", false),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(String(localized: "미리보기"))
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("서버").font(.ui(.caption2)).foregroundStyle(.secondary)
                    Label("prod-web", glyph: "bt.server").foregroundStyle(SavedSite.Tag.prod.color)
                    Label("dev-api", glyph: "bt.server")
                    Text("클라우드").font(.ui(.caption2)).foregroundStyle(.secondary).padding(.top, 4)
                    Label("Google Drive", glyph: "bt.cloud")
                    Spacer()
                }
                .font(.ui(.caption))
                .padding(8)
                .frame(width: 108, alignment: .leading)
                .background(Palette.panel2)
                Rectangle().fill(Palette.line).frame(width: 1)
                VStack(spacing: 0) {
                    HStack(spacing: 5) {
                        Text("prod-web").font(.ui(.caption, weight: .bold)).foregroundStyle(SavedSite.Tag.prod.color)
                        TagChip(tag: .prod)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    Text("/var/www/site").font(.themeMono(.caption2)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 6)
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if !row.hidden || store.current.list.showHidden {
                            HStack(spacing: 6) {
                                Image(systemName: row.symbol)
                                    .foregroundStyle(row.symbol == "folder" ? Color.themeAccent : .secondary)
                                    .frame(width: 14)
                                Text(row.name).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(row.size).font(.themeMono(.caption2)).foregroundStyle(.secondary)
                            }
                            .font(.ui(.caption))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3 + store.rowPadding)
                            .background(index == 1 ? Palette.selection : .clear, in: .rect(cornerRadius: 5))
                            .padding(.horizontal, 4)
                        }
                    }
                    Spacer(minLength: 6)
                    HStack {
                        Button("편집") {}
                            .buttonStyle(PanelButtonStyle(prominent: true))
                        Button("dev-api에 복사") {}
                            .buttonStyle(PanelButtonStyle())
                    }
                    .padding(8)
                }
                .background(Palette.panel)
            }
            .frame(height: 300)
            .background(Palette.background)
            .clipShape(.rect(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.line))
            Text("⌘K 명령 팔레트").font(.ui(.caption)).foregroundStyle(.secondary)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 단축키

struct KeySettings: View {
    @State private var recording: PaneAction?
    @State private var monitor: Any?
    private var keymap: Keymap { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsGroup(String(localized: "기본 배열")) {
                    HStack(spacing: 10) {
                        ForEach(KeyLayout.allCases) { layout in
                            let selected = keymap.layout == layout
                            Button {
                                keymap.layout = layout
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(layout.title).font(.ui(.body, weight: selected ? .semibold : .regular))
                                    Text(layout.subtitle).font(.ui(.caption)).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(selected ? Palette.selection : Palette.panel, in: .rect(cornerRadius: 9))
                                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? Color.themeAccent : Palette.line, lineWidth: selected ? 1.5 : 1))
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                SettingsGroup(String(localized: "단축키"), footer: String(localized: "단축키를 클릭한 후 새 키를 누르십시오. Esc를 누르면 취소됩니다. ⌘ 또는 ⌃ 조합과 F 키는 메뉴에도 표시되며, Space, ↵, Tab 같은 키는 파일 목록에서만 동작합니다.")) {
                    ForEach(PaneAction.allCases) { action in
                        HStack(spacing: 8) {
                            Text(action.title).font(.ui(.body))
                            Spacer()
                            if recording != action, let clash = keymap.clash(for: action) {
                                Badge(String(localized: "겹침: \(clash)"), color: .orange)
                            }
                            if keymap.isCustom(action) {
                                Badge(String(localized: "사용자 지정"), color: .themeAccent)
                                Button {
                                    keymap.set(nil, for: action)
                                } label: {
                                    Image(systemName: "arrow.uturn.backward")
                                }
                                .buttonStyle(.borderless)
                                .iconHelp(String(localized: "\(keymap.layout.title) 기본값 복원"))
                            }
                            Button {
                                recording == action ? stopRecording() : startRecording(action)
                            } label: {
                                Text(recording == action ? String(localized: "키 입력 대기 중…") : keymap.combo(for: action).description)
                                    .font(.themeMono(.body))
                                    .foregroundStyle(recording == action ? Color.themeAccent : Palette.text)
                                    .frame(minWidth: 120)
                                    .padding(.vertical, 5)
                                    .background(recording == action ? Palette.selection : Palette.panel2, in: .rect(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(recording == action ? Color.themeAccent : Palette.line, lineWidth: recording == action ? 1.5 : 1))
                            }
                            .buttonStyle(.plain)
                        }
                        if action != PaneAction.allCases.last {
                            Rectangle().fill(Palette.line).frame(height: 1)
                        }
                    }
                }
            }
        }
        .scrollIndicators(.never)
        .onDisappear(perform: stopRecording)
    }

    private func startRecording(_ action: PaneAction) {
        stopRecording()
        recording = action
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode != 53, let combo = KeyCombo(event) {
                Keymap.shared.set(combo, for: action)
            }
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }
}

// MARK: - iCloud 동기화

struct SyncSettings: View {
    let sync: SettingsSync
    var height: CGFloat?
    @AppStorage("sidebar.showsICloudDrive") private var showsICloudDrive = true
    @AppStorage("panes.showsCloudBadges") private var showsCloudBadges = true

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if sync.isEnabled {
                        conflicts
                    }
                    if let resolution = sync.resolution {
                        Label(resolution, systemImage: "checkmark.circle.fill")
                            .font(.ui(.callout))
                            .foregroundStyle(Color(light: 0x0F7C5A, dark: 0x3CC48E))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(String(localized: "동기화할 항목"))
                        ForEach(SettingsSync.Item.allCases) { item in
                            SettingSwitch(title: item.title, detail: item.subtitle, isOn: Binding(get: { sync.items.contains(item) }, set: { sync.set(item, on: $0) }))
                                .padding(12)
                                .card()
                        }
                        SettingSwitch(title: String(localized: "비밀번호와 키 암호"), detail: String(localized: "iCloud 키체인 사용, Developer ID 서명과 키체인 공유 권한 필요"), badge: String(localized: "서명된 앱 필요"), isOn: .constant(false))
                            .disabled(true)
                            .padding(12)
                            .card()
                    }
                    .disabled(!sync.isEnabled)
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(String(localized: "저장 방식"))
                        HStack(alignment: .top, spacing: 10) {
                            method(String(localized: "iCloud Drive 폴더"), recommended: true, detail: String(localized: "iCloud Drive에 JSON 파일로 저장, 개발자 계정 불필요"), place: "~/iCloud Drive/Bottari/", available: true)
                            method("CloudKit", recommended: false, detail: String(localized: "Apple 서버의 앱 전용 저장소. Apple Developer 계정과 앱 서명이 필요해 아직 지원하지 않음"), place: String(localized: "iCloud 비공개 데이터베이스"), available: false)
                        }
                    }
                    SettingsGroup(String(localized: "파일 창의 iCloud Drive")) {
                        SettingSwitch(title: String(localized: "사이드바에 iCloud Drive 표시"), isOn: $showsICloudDrive)
                        SettingSwitch(title: String(localized: "파일 옆에 iCloud 상태 표시"), isOn: $showsCloudBadges)
                    }
                }
            }
            .scrollIndicators(.never)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    devicesCard
                    filesCard
                    VStack(alignment: .leading, spacing: 4) {
                        Text("비밀번호는 파일에 저장되지 않음").font(.ui(.callout, weight: .semibold))
                        Text("JSON 파일에는 서버 주소와 설정만 저장됩니다. 비밀번호와 키 암호는 이 Mac의 키체인에만 보관됩니다.")
                            .font(.ui(.caption))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .well()
                }
            }
            .scrollIndicators(.never)
            .frame(width: 330)
        }
        .frame(height: height)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "icloud")
                    .font(.system(size: 18))
                    .foregroundStyle(sync.isEnabled ? Color.themeAccent : .secondary)
                    .frame(width: 44, height: 44)
                    .background(Palette.panel, in: .rect(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.line))
                VStack(alignment: .leading, spacing: 2) {
                    Text("iCloud로 설정 동기화").font(.ui(.body, weight: .semibold))
                    Text(status).font(.ui(.caption)).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("iCloud로 설정 동기화", isOn: Binding(get: { sync.isEnabled }, set: { sync.setEnabled($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                Button(sync.isSyncing ? String(localized: "동기화 중…") : String(localized: "지금 동기화")) { sync.syncNow() }
                    .buttonStyle(PanelButtonStyle())
                    .fixedSize()
                    .disabled(!sync.isEnabled || sync.isSyncing)
            }
            ForEach(sync.errors, id: \.self) { error in
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.ui(.caption))
                    .foregroundStyle(.orange)
            }
            if let iCloud = LocalFileProvider.iCloudDrive, !FolderAccess.shared.covers(iCloud) {
                HStack {
                    Text("iCloud Drive 폴더를 허용해야 동기화할 수 있습니다.")
                        .font(.ui(.caption))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("iCloud Drive 허용…") {
                        FolderAccessPanel.ask(startingAt: iCloud)
                        sync.syncNow()
                    }
                    .buttonStyle(PanelButtonStyle())
                    .fixedSize()
                }
            }
        }
        .padding(16)
        .well(radius: 10)
    }

    @ViewBuilder
    private var conflicts: some View {
        ForEach(SettingsSync.Item.allCases) { item in
            let found = sync.conflicts.filter { $0.item == item }
            if !found.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(item.subject) 두 Mac에서 다르게 변경됨").font(.ui(.body, weight: .semibold))
                    ForEach(found) { conflict in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(conflict.title) \(conflict.detail)")
                                .font(.themeMono(.caption))
                                .foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                Button("이 Mac의 버전 유지") { sync.resolve(conflict, .keepMine) }
                                    .buttonStyle(PanelButtonStyle(prominent: true))
                                Button("\(sync.otherMacName)의 버전 사용") { sync.resolve(conflict, .useTheirs) }
                                    .buttonStyle(PanelButtonStyle())
                                if conflict.canKeepBoth {
                                    Button("둘 다 유지") { sync.resolve(conflict, .keepBoth) }
                                        .buttonStyle(PanelButtonStyle())
                                }
                            }
                            .fixedSize()
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.07), in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.45)))
            }
        }
    }

    private var devicesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("동기화하는 Mac").font(.ui(.body, weight: .semibold))
            if sync.devices.isEmpty {
                Text("동기화를 켜면 이 Mac과 다른 Mac이 여기에 표시됨")
                    .font(.ui(.caption))
                    .foregroundStyle(.secondary)
            }
            ForEach(sync.devices.reversed()) { device in
                HStack(spacing: 10) {
                    Image(systemName: device.isLaptop ? "laptopcomputer" : "desktopcomputer")
                        .frame(width: 22)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.name).font(.ui(.callout, weight: .semibold))
                        Text("\(Self.time(device.lastSync)) 동기화").font(.ui(.caption)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if device.id == sync.devices.last?.id {
                        Badge(String(localized: "이 Mac"), color: .themeAccent)
                    }
                }
                .padding(10)
                .well()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var filesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("iCloud Drive에 저장되는 파일").font(.ui(.body, weight: .semibold))
            Text(tree)
                .font(.themeMono(.caption))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .well()
            Text("삭제해도 다음 동기화 때 다시 생성됨")
                .font(.ui(.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Bottari에서 이 폴더 열기") {
                if let folder = sync.folder {
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    NotificationCenter.default.post(name: .openOnMac, object: folder.path)
                }
            }
            .buttonStyle(.link)
            .font(.ui(.caption))
            .disabled(sync.folder == nil || !sync.isEnabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var status: String {
        guard sync.isEnabled else { return String(localized: "꺼짐 · 이 Mac에만 저장") }
        if sync.folder == nil { return String(localized: "iCloud Drive를 찾을 수 없음") }
        return String(localized: "iCloud Drive 사용 중 · 마지막 동기화: ") + (sync.lastSync.map(Self.time) ?? String(localized: "없음"))
    }

    private var tree: String {
        let items = SettingsSync.Item.allCases.filter { sync.items.contains($0) }
        var lines = ["Bottari/"]
        let entries = items.flatMap { item in item.files.map { ($0, item.title) } } + [("devices/", String(localized: "동기화하는 Mac"))]
        for (index, entry) in entries.enumerated() {
            let branch = index == entries.count - 1 ? "└─ " : "├─ "
            lines.append(branch + entry.0.padding(toLength: 22, withPad: " ", startingAt: 0) + entry.1)
        }
        return lines.joined(separator: "\n")
    }

    private func method(_ title: String, recommended: Bool, detail: String, place: String, available: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.ui(.callout, weight: .semibold))
                if recommended {
                    Badge(String(localized: "기본"), color: .themeAccent)
                }
            }
            Text(detail).font(.ui(.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(place).font(.themeMono(.caption2)).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(available ? Palette.selection : Palette.panel, in: .rect(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(available ? Color.themeAccent : Palette.line, lineWidth: available ? 1.5 : 1))
        .opacity(available ? 1 : 0.6)
    }

    static func time(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return String(localized: "오늘 ") + date.formatted(date: .omitted, time: .shortened) }
        if Calendar.current.isDateInYesterday(date) { return String(localized: "어제 ") + date.formatted(date: .omitted, time: .shortened) }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
