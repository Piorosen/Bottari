import AppKit
import SwiftUI

/// The open source in the app and its licenses, from Acknowledgements.json
/// (made by scripts/acknowledgements.py).
struct Acknowledgements: Decodable {
    struct Component: Decodable, Identifiable, Hashable {
        let group: String
        let name: String
        let version: String
        let license: String
        let url: String
        let files: [String]
        let note: String

        var id: String { name }
    }

    /// How the LGPL libraries may be changed and where their source is, by language.
    let lgplNote: [String: String]
    let components: [Component]
    let texts: [String: String]

    static let shared: Acknowledgements? = Bundle.main.url(forResource: "Acknowledgements", withExtension: "json")
        .flatMap { try? Data(contentsOf: $0) }
        .flatMap { try? JSONDecoder().decode(Acknowledgements.self, from: $0) }

    var localizedNote: String {
        lgplNote[Bundle.main.preferredLocalizations.first == "ko" ? "ko" : "en"] ?? lgplNote["en"] ?? ""
    }

    static func groupTitle(_ group: String) -> String {
        switch group {
        case "player": String(localized: "영상 재생 (MPVKit)")
        case "swift": String(localized: "Swift 패키지")
        case "font": String(localized: "글꼴")
        default: group
        }
    }
}

/// "오픈 소스 라이선스": every component with its license text, and how the
/// LGPL libraries can be replaced.
struct AcknowledgementsWindow: View {
    @State private var selection: Acknowledgements.Component.ID?

    /// `selection` already chosen, for snapshots.
    init(selection: Acknowledgements.Component.ID? = nil) {
        _selection = State(initialValue: selection)
    }

    var body: some View {
        if let data = Acknowledgements.shared {
            VStack(alignment: .leading, spacing: 12) {
                WindowHeading(title: String(localized: "오픈 소스 라이선스"), subtitle: String(localized: "Bottari에 들어 있는 오픈 소스 \(data.components.count)개"))
                HStack(alignment: .top, spacing: 12) {
                    list(data)
                        .frame(width: 290)
                        .card()
                    detail(data)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .card()
                }
            }
            .padding(16)
            .background(Palette.background)
        } else {
            Text("라이선스 정보를 읽을 수 없습니다.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func list(_ data: Acknowledgements) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                row(title: String(localized: "LGPL 고지"), subtitle: String(localized: "라이브러리 교체와 소스"), selected: selection == nil) { selection = nil }
                ForEach(["player", "swift", "font"], id: \.self) { group in
                    VStack(alignment: .leading, spacing: 2) {
                        SectionLabel(Acknowledgements.groupTitle(group)).padding(.horizontal, 8).padding(.top, 4)
                        ForEach(data.components.filter { $0.group == group }) { component in
                            row(title: component.name, subtitle: [component.version, component.license].filter { !$0.isEmpty }.joined(separator: " · "), selected: selection == component.id) {
                                selection = component.id
                            }
                        }
                    }
                }
            }
            .padding(10)
        }
        .scrollIndicators(.never)
    }

    private func row(title: String, subtitle: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.ui(.callout, weight: .medium)).lineLimit(1)
                Text(subtitle).font(.themeMono(.caption2)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(selected ? Palette.selection : .clear, in: .rect(cornerRadius: 7))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func detail(_ data: Acknowledgements) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let component = data.components.first(where: { $0.id == selection }) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(component.name).font(.ui(.title3, weight: .semibold))
                        Text([component.version, component.license].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.themeMono(.callout))
                            .foregroundStyle(.secondary)
                    }
                    if let url = URL(string: component.url) {
                        Link(destination: url) { Label(component.url, systemImage: "arrow.up.right.square") }
                            .font(.ui(.callout))
                    }
                    if !component.note.isEmpty {
                        Text(component.note).font(.ui(.callout)).fixedSize(horizontal: false, vertical: true)
                    }
                    if component.group == "player" {
                        Text(data.localizedNote)
                            .font(.ui(.callout))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    ForEach(component.files, id: \.self) { file in
                        Text(data.texts[file] ?? "")
                            .font(.themeMono(.caption))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .well()
                    }
                } else {
                    Text("LGPL 고지").font(.ui(.title3, weight: .semibold))
                    Text(data.localizedNote)
                        .font(.ui(.body))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Text("왼쪽에서 항목을 고르면 그 라이선스 전문이 보입니다.")
                        .font(.ui(.callout))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(18)
        }
    }
}

/// Help › 오픈 소스 라이선스.
struct AcknowledgementsCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("오픈 소스 라이선스") { openWindow(id: "licenses") }
    }
}
