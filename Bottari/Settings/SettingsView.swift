import AppKit
import BottariSFTP
import BottariTransfer
import SwiftUI
import UniformTypeIdentifiers

/// ⌘, : transfers, looks, keys and iCloud sync.
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("일반", systemImage: "gearshape") { GeneralSettings() }
            Tab("모양", systemImage: "paintpalette") { AppearanceSettings() }
            Tab("단축키", systemImage: "keyboard") { KeySettings() }
            Tab("iCloud 동기화", systemImage: "icloud") { SyncSettings(sync: .shared) }
        }
        .themed()
    }
}

extension Notification.Name {
    /// Opens a folder on the Mac in the main window's active pane; the object is its path.
    static let openOnMac = Notification.Name("BottariOpenOnMac")
}

// MARK: - 일반

struct GeneralSettings: View {
    @AppStorage(TransferSettings.maxConcurrentKey) private var maxConcurrent = 3
    @AppStorage(TransferSettings.conflictPolicyKey) private var policy: ConflictPolicy = .ask
    @AppStorage(TransferSettings.verifiesChecksumsKey) private var verifiesChecksums = false

    var body: some View {
        Form {
            Section("전송") {
                Stepper(value: $maxConcurrent, in: 1...8) {
                    LabeledContent("동시에 보낼 파일", value: "\(maxConcurrent)개")
                }
                Picker("같은 이름의 파일이 있으면", selection: $policy) {
                    ForEach(ConflictPolicy.allCases, id: \.self) { policy in
                        Text(policy.label).tag(policy)
                    }
                }
                Toggle(isOn: $verifiesChecksums) {
                    Text("보낸 뒤 체크섬 비교")
                    Text("양쪽에서 SHA-256을 계산해 비교해요. 서버는 명령을 실행할 수 있을 때만 돼요.")
                }
            }
            Section("업데이트") {
                if Updates.shared.isAvailable {
                    Toggle("자동으로 업데이트 확인", isOn: Binding(get: { Updates.shared.automaticallyChecks }, set: { Updates.shared.automaticallyChecks = $0 }))
                    Button("지금 확인") { Updates.shared.checkForUpdates() }
                } else {
                    LabeledContent("버전", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                    Text("이 빌드는 업데이트를 확인하지 않아요. 서명한 릴리스(scripts/release.sh)에서 켜져요.")
                        .font(.ui(.caption))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 620, height: 380)
        .onChange(of: maxConcurrent) { AppServices.transfers.maxConcurrentTransfers = maxConcurrent }
        .onChange(of: verifiesChecksums) { AppServices.transfers.verifiesChecksums = verifiesChecksums }
    }
}

// MARK: - 모양

struct AppearanceSettings: View {
    @State private var accentText = ""
    @State private var fileError: String?
    private var store: ThemeStore { .shared }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Form {
                Section("테마") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                        ForEach(Theme.presets, id: \.theme.name) { preset in
                            Button {
                                store.choose(preset: preset.theme)
                            } label: {
                                PresetCard(theme: preset.theme, subtitle: preset.subtitle, isSelected: store.current.presetName == preset.theme.name)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section("강조 색") {
                    HStack(spacing: 10) {
                        swatch(nil, label: "시스템")
                        ForEach(Theme.accents, id: \.hex) { accent in
                            swatch(accent.hex, label: accent.name)
                        }
                        Divider().frame(height: 18)
                        ColorPicker("직접 고르기", selection: accentBinding, supportsOpacity: false)
                            .labelsHidden()
                        TextField("색 코드", text: $accentText, prompt: Text(verbatim: "#3651C9"))
                            .labelsHidden()
                            .font(.themeMono(.body))
                            .frame(width: 96)
                            .onSubmit(applyAccentText)
                    }
                }
                Section("글자와 간격") {
                    Picker("밀도", selection: binding(\.density)) {
                        ForEach(Theme.Density.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    fontPicker("본문 글꼴", system: "시스템 (SF)", choices: ThemeStore.uiFontChoices, selection: binding(\.font.ui))
                    fontPicker("고정폭 글꼴 (경로 · 크기 · 코드)", system: "시스템 (SF Mono)", choices: ThemeStore.monoFontChoices, selection: binding(\.font.mono))
                    Toggle("새 패인에서 숨김 파일 보기", isOn: binding(\.list.showHidden))
                }
                Section("서버 태그 색") {
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
            .formStyle(.grouped)
            .frame(width: 520)

            ThemePreview()
                .padding(.top, 20)
                .padding(.trailing, 20)
        }
        .frame(width: 880, height: 700)
        .onAppear { accentText = store.current.colors.accent ?? "" }
        .onChange(of: store.current.colors.accent) { accentText = store.current.colors.accent ?? "" }
    }

    private var themeFiles: some View {
        Section {
            HStack {
                Button("가져오기…", action: importTheme)
                Button("내보내기…", action: exportTheme)
                Spacer()
                Button("폴더 열기") {
                    try? FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(store.folder)
                }
            }
            if let fileError {
                Label(fileError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            ForEach(store.saved) { theme in
                HStack {
                    Circle()
                        .fill(Color(themeHex: theme.colors.background ?? "#808080") ?? .gray)
                        .overlay(Circle().strokeBorder(Color(themeHex: theme.colors.accent ?? "#808080") ?? .gray, lineWidth: 3))
                        .frame(width: 16, height: 16)
                    Text(theme.name)
                    if theme == store.current {
                        Text("사용 중").font(.ui(.caption)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("쓰기") { store.current = theme }
                        .disabled(theme == store.current)
                    Button {
                        store.delete(theme)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("이 테마 파일 지우기")
                }
            }
            DisclosureGroup("JSON 보기") {
                Text(store.json)
                    .font(.themeMono(.caption))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } header: {
            Text("테마 파일")
        } footer: {
            Text("~/Library/Application Support/Bottari/themes/ 에 저장돼요. 다른 사람과 파일로 주고받을 수 있어요.")
                .font(.ui(.caption))
                .foregroundStyle(.secondary)
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
                .frame(width: 18, height: 18)
                .padding(3)
                .overlay(Circle().strokeBorder(selected ? Color.primary.opacity(0.6) : .clear, lineWidth: 2))
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

    private func fontPicker(_ title: String, system: String, choices: [String], selection: Binding<String?>) -> some View {
        Picker(title, selection: selection) {
            Text(system).tag(String?.none)
            ForEach(choices, id: \.self) { family in
                Text(family).font(.custom(family, size: 13)).tag(Optional(family))
            }
            // A theme from elsewhere may name a font this Mac does not have.
            if let missing = selection.wrappedValue, !choices.contains(missing) {
                Text("\(missing) (설치 안 됨)").tag(Optional(missing))
            }
        }
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
            fileError = "테마 파일을 읽지 못했어요: \(error.localizedDescription)"
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
            fileError = "테마 파일을 쓰지 못했어요: \(error.localizedDescription)"
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
                    // The system theme: half light, half dark.
                    HStack(spacing: 0) {
                        miniature(background: .init(white: 0.93), panel: .white, line: .init(white: 0.85), text: .init(white: 0.1))
                        miniature(background: .init(white: 0.08), panel: .init(white: 0.13), line: .init(white: 0.22), text: .init(white: 0.9))
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
            .frame(height: 54)
            .clipShape(.rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isSelected ? Color.themeAccent : Color.secondary.opacity(0.3), lineWidth: isSelected ? 2 : 1))
            Text(theme.name).fontWeight(isSelected ? .semibold : .regular)
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
        ("assets", "—", "folder.fill", false), ("nginx.conf", "2.8 KB", "doc.text", false),
        ("hero.png", "2.1 MB", "photo", false), ("promo.mp4", "48.2 MB", "film", false),
        (".htaccess", "312 B", "doc", true), ("db-2026-10-21.sql.gz", "1.2 GB", "archivebox", false),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("미리보기").font(.ui(.headline))
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("서버").font(.ui(.caption2)).foregroundStyle(.secondary)
                    Label("prod-web", systemImage: "server.rack").foregroundStyle(SavedSite.Tag.prod.color)
                    Label("dev-api", systemImage: "server.rack")
                    Text("클라우드").font(.ui(.caption2)).foregroundStyle(.secondary).padding(.top, 4)
                    Label("Google Drive", systemImage: "cloud")
                    Spacer()
                }
                .font(.ui(.caption))
                .padding(8)
                .frame(width: 104, alignment: .leading)
                .background(Palette.background)
                Divider()
                VStack(spacing: 0) {
                    HStack(spacing: 5) {
                        Text("prod-web").font(.ui(.caption, weight: .bold)).foregroundStyle(SavedSite.Tag.prod.color)
                        TagChip(tag: .prod)
                        Text("/var/www/site").font(.themeMono(.caption)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(6)
                    .background(Palette.panel2)
                    .overlay(alignment: .top) { SavedSite.Tag.prod.color.frame(height: 2) }
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if !row.hidden || store.current.list.showHidden {
                            HStack(spacing: 6) {
                                Image(systemName: row.symbol)
                                    .foregroundStyle(index == 1 ? Color.white : row.symbol == "folder.fill" ? Color.themeAccent : .secondary)
                                    .frame(width: 14)
                                Text(row.name).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(row.size).font(.themeMono(.caption))
                                    .foregroundStyle(index == 1 ? Color.white.opacity(0.85) : .secondary)
                            }
                            .font(.ui(.caption))
                            .foregroundStyle(index == 1 ? Color.white : .primary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2 + store.rowPadding)
                            .background(index == 1 ? Color.themeAccent : .clear, in: .rect(cornerRadius: 4))
                            .padding(.horizontal, 3)
                        }
                    }
                    Spacer(minLength: 6)
                    HStack {
                        Button("편집하기") {}
                        Button("dev-api에 복사") {}
                            .buttonStyle(.borderedProminent)
                    }
                    .controlSize(.small)
                    .padding(8)
                }
                .padding(.top, 0)
                .background(Palette.panel)
            }
            .frame(width: 330, height: 300)
            .clipShape(.rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line))
            Text("⌘K 이동 · 연결 · 명령").font(.ui(.caption)).foregroundStyle(.secondary)
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
        Form {
            Section("기본 배열") {
                HStack(spacing: 12) {
                    ForEach(KeyLayout.allCases) { layout in
                        let selected = keymap.layout == layout
                        Button {
                            keymap.layout = layout
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(layout.title).fontWeight(selected ? .semibold : .regular)
                                Text(layout.subtitle).font(.ui(.caption)).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(selected ? Color.themeAccent.opacity(0.12) : .clear, in: .rect(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.themeAccent : Color.secondary.opacity(0.3), lineWidth: selected ? 2 : 1))
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Section {
                ForEach(PaneAction.allCases) { action in
                    HStack(spacing: 8) {
                        Text(action.title)
                        Spacer()
                        if recording != action, let clash = keymap.clash(for: action) {
                            Text("겹침 · \(clash)")
                                .font(.ui(.caption))
                                .foregroundStyle(.orange)
                        }
                        if keymap.isCustom(action) {
                            Text("사용자 지정")
                                .font(.ui(.caption))
                                .foregroundStyle(Color.themeAccent)
                            Button {
                                keymap.set(nil, for: action)
                            } label: {
                                Image(systemName: "arrow.uturn.backward")
                            }
                            .buttonStyle(.borderless)
                            .help("\(keymap.layout.title) 기본값으로")
                        }
                        Button {
                            recording == action ? stopRecording() : startRecording(action)
                        } label: {
                            Text(recording == action ? "키를 누르세요…" : keymap.combo(for: action).description)
                                .font(.themeMono(.body))
                                .frame(minWidth: 110)
                        }
                    }
                }
            } header: {
                Text("단축키 (눌러서 바꾸기)")
            } footer: {
                Text("단축키 칸을 누른 뒤 원하는 키를 누르면 바뀌어요. Esc로 취소. ⌘·⌃ 조합과 F 키는 메뉴에도 보이고, Space · ↵ · Tab 같은 키는 파일 목록에서만 들어요.")
                    .font(.ui(.caption))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 620, height: 620)
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
    var height: CGFloat = 700
    @AppStorage("sidebar.showsICloudDrive") private var showsICloudDrive = true
    @AppStorage("panes.showsCloudBadges") private var showsCloudBadges = true

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: sync.isEnabled ? "icloud.fill" : "icloud.slash")
                        .font(.ui(.title))
                        .foregroundStyle(sync.isEnabled ? Color.themeAccent : .secondary)
                        .frame(width: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("iCloud로 설정 동기화").font(.ui(.headline))
                        Text(status).font(.ui(.callout)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(sync.isSyncing ? "동기화 중…" : "지금 동기화") { sync.syncNow() }
                        .disabled(!sync.isEnabled || sync.isSyncing)
                    Toggle("iCloud로 설정 동기화", isOn: Binding(get: { sync.isEnabled }, set: { sync.setEnabled($0) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                ForEach(sync.errors, id: \.self) { error in
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            if sync.isEnabled {
                conflicts
            }
            if let resolution = sync.resolution {
                Label(resolution, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            Section("무엇을 동기화할까요") {
                ForEach(SettingsSync.Item.allCases) { item in
                    Toggle(isOn: Binding(get: { sync.items.contains(item) }, set: { sync.set(item, on: $0) })) {
                        Text(item.title)
                        Text(item.subtitle)
                    }
                }
                Toggle(isOn: .constant(false)) {
                    HStack {
                        Text("비밀번호와 키 암호")
                        Text("서명된 앱 필요")
                            .font(.ui(.caption2))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: .capsule)
                    }
                    Text("iCloud 키체인으로 나눠요. Developer ID로 서명하고 키체인 공유 권한을 받은 앱에서만 돼요.")
                }
                .disabled(true)
            }
            .disabled(!sync.isEnabled)
            Section("저장 방식") {
                method("iCloud Drive 폴더", recommended: true, detail: "설정을 JSON 파일로 iCloud Drive에 둬요. 개발자 계정 없이 되고, 파일이라 직접 열어 볼 수 있어요.", place: "~/iCloud Drive/Bottari/", available: true)
                method("CloudKit", recommended: false, detail: "Apple 서버의 앱 전용 저장소예요. 바뀐 내용이 더 빨리 퍼지지만, Apple Developer 계정과 앱 서명이 필요해서 아직 쓰지 않아요.", place: "iCloud 비공개 데이터베이스", available: false)
            }
            Section("파일 창의 iCloud Drive") {
                Toggle("사이드바에 iCloud Drive 보이기", isOn: $showsICloudDrive)
                Toggle("파일 옆에 iCloud 상태 표시", isOn: $showsCloudBadges)
            }
            if !sync.devices.isEmpty {
                Section("같은 설정을 쓰는 Mac") {
                    ForEach(sync.devices) { device in
                        HStack {
                            Image(systemName: device.isLaptop ? "laptopcomputer" : "desktopcomputer")
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(device.name)
                                Text("\(Self.time(device.lastSync)) 동기화").font(.ui(.caption)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if device.id == sync.devices.last?.id {
                                Text("이 Mac").font(.ui(.caption)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section {
                Text(tree)
                    .font(.themeMono(.callout))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Button("Bottari에서 이 폴더 열기") {
                        if let folder = sync.folder {
                            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                            NotificationCenter.default.post(name: .openOnMac, object: folder.path)
                        }
                    }
                    .disabled(sync.folder == nil || !sync.isEnabled)
                }
            } header: {
                Text("iCloud Drive에 저장되는 파일")
            } footer: {
                Text("Finder에서 직접 열어 볼 수 있어요. 지워도 다음 동기화 때 다시 만들어요.")
                    .font(.ui(.caption))
                    .foregroundStyle(.secondary)
            }
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("비밀번호는 파일에 쓰지 않아요")
                        Text("JSON에는 서버 주소와 설정만 들어가요. 비밀번호와 키 암호는 이 Mac의 키체인에만 있어요.")
                            .font(.ui(.caption))
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "lock.fill")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 640, height: height)
    }

    @ViewBuilder
    private var conflicts: some View {
        ForEach(SettingsSync.Item.allCases) { item in
            let found = sync.conflicts.filter { $0.item == item }
            if !found.isEmpty {
                Section {
                    ForEach(found) { conflict in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(conflict.title).fontWeight(.semibold)
                            Text(conflict.detail).font(.ui(.callout)).foregroundStyle(.secondary)
                            HStack {
                                Button("이 Mac 것 유지") { sync.resolve(conflict, .keepMine) }
                                Button("\(sync.otherMacName) 것 쓰기") { sync.resolve(conflict, .useTheirs) }
                                if conflict.canKeepBoth {
                                    Button("둘 다 남기기") { sync.resolve(conflict, .keepBoth) }
                                }
                            }
                            .controlSize(.small)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Label("\(item.subject) 두 Mac에서 서로 다르게 바뀌었어요", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var status: String {
        guard sync.isEnabled else { return "꺼짐 · 이 Mac에만 저장해요" }
        if sync.folder == nil { return "iCloud Drive를 찾지 못했어요" }
        return "iCloud Drive 사용 중 · 마지막 동기화 " + (sync.lastSync.map(Self.time) ?? "아직 없음")
    }

    private var tree: String {
        let items = SettingsSync.Item.allCases.filter { sync.items.contains($0) }
        var lines = ["Bottari/"]
        let entries = items.flatMap { item in item.files.map { ($0, item.title) } } + [("devices/", "같은 설정을 쓰는 Mac")]
        for (index, entry) in entries.enumerated() {
            let branch = index == entries.count - 1 ? "└─ " : "├─ "
            lines.append(branch + entry.0.padding(toLength: 22, withPad: " ", startingAt: 0) + entry.1)
        }
        return lines.joined(separator: "\n")
    }

    private func method(_ title: String, recommended: Bool, detail: String, place: String, available: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: available ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(available ? Color.themeAccent : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title).fontWeight(.medium)
                    if recommended {
                        Text("추천").font(.ui(.caption2)).padding(.horizontal, 5).padding(.vertical, 1)
                            .foregroundStyle(Color.themeAccent)
                            .background(Color.themeAccent.opacity(0.12), in: .capsule)
                    }
                }
                Text(detail).font(.ui(.caption)).foregroundStyle(.secondary)
                Text(place).font(.themeMono(.caption)).foregroundStyle(.secondary)
            }
        }
        .opacity(available ? 1 : 0.55)
    }

    static func time(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "오늘 " + date.formatted(date: .omitted, time: .shortened) }
        if Calendar.current.isDateInYesterday(date) { return "어제 " + date.formatted(date: .omitted, time: .shortened) }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
