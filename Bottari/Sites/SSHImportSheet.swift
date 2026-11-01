import BottariCore
import BottariSFTP
import SwiftUI

/// Picks which `~/.ssh/config` hosts become connections and which key files
/// go into the Keychain, instead of taking everything at once.
struct SSHImportSheet: View {
    let library: SiteLibrary
    /// Called with the connections made, after importing.
    let imported: ([SavedSite]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var hosts: Set<String> = []
    @State private var keys: Set<String> = []
    @State private var candidates: [KeyImportCandidate] = []
    @State private var unreadable: [String]?

    private var sshFolder: RemotePath { RemotePath(UserHome.path).appending(".ssh") }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Glyph("bt.server", size: 26)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("~/.ssh에서 가져오기").font(.ui(.title3, weight: .semibold))
                    Text("가져올 호스트와 키체인에 둘 키 파일을 고르십시오.")
                        .font(.ui(.callout))
                        .foregroundStyle(.secondary)
                }
            }
            if !FolderAccess.shared.covers(sshFolder) {
                HStack {
                    Text("~/.ssh를 아직 읽을 수 없습니다. 허용하면 config의 호스트와 키 파일이 보입니다.")
                        .font(.ui(.callout))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("~/.ssh 허용…") {
                        guard FolderAccessPanel.ask(startingAt: sshFolder, showingHiddenFiles: true) != nil else { return }
                        library.reloadSSHConfig()
                        reload(selectingAll: true)
                    }
                    .buttonStyle(PanelButtonStyle(prominent: true))
                    .fixedSize()
                }
                .padding(12)
                .well()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    hostList
                    keyList
                }
            }
            .frame(maxHeight: 440)
            if let unreadable {
                Text(unreadable.isEmpty
                    ? String(localized: "가져왔습니다.")
                    : String(localized: "이 키 파일은 읽을 수 없어 가져오지 못했습니다: \(unreadable.joined(separator: ", "))"))
                    .font(.ui(.callout))
                    .foregroundStyle(unreadable.isEmpty ? Color.secondary : Color.orange)
            }
            HStack {
                Spacer()
                Button(unreadable == nil ? String(localized: "취소") : String(localized: "닫기"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if unreadable == nil {
                    Button(importTitle, action: importChosen)
                        .keyboardShortcut(.defaultAction)
                        .disabled(hosts.isEmpty && chosenKeys.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 580)
        .onAppear { reload(selectingAll: true) }
    }

    // MARK: Hosts

    private var hostList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel(String(localized: "~/.ssh/config의 새 호스트"))
                Spacer()
                if !library.importableHosts.isEmpty {
                    Button(hosts.count == library.importableHosts.count ? String(localized: "모두 해제") : String(localized: "모두 선택")) {
                        hosts = hosts.count == library.importableHosts.count ? [] : Set(library.importableHosts.map(\.alias))
                        refreshKeys()
                    }
                    .buttonStyle(.link)
                    .font(.ui(.caption))
                }
            }
            if library.importableHosts.isEmpty {
                Text("새 호스트가 없습니다. 모두 가져왔거나 ~/.ssh/config가 비어 있습니다.")
                    .font(.ui(.caption))
                    .foregroundStyle(.secondary)
            }
            ForEach(library.importableHosts, id: \.alias) { host in
                Toggle(isOn: Binding(
                    get: { hosts.contains(host.alias) },
                    set: { on in
                        if on { hosts.insert(host.alias) } else { hosts.remove(host.alias) }
                        refreshKeys()
                    }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(host.alias).font(.ui(.callout, weight: .medium))
                        Text(Self.describe(host))
                            .font(.themeMono(.caption))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    private static func describe(_ host: SSHConfig.Host) -> String {
        var text = "\(host.user ?? NSUserName())@\(host.hostName)" + (host.port == 22 ? "" : ":\(host.port)")
        if !host.proxyJump.isEmpty { text += String(localized: " · 경유 \(host.proxyJump.joined(separator: " → "))") }
        if let key = host.identityFiles.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            text += " · " + UserHome.abbreviate(key)
        }
        return text
    }

    // MARK: Keys

    /// Keys whose users are all hosts left unchecked would change nothing.
    private func isUsed(_ candidate: KeyImportCandidate) -> Bool {
        let saved = Set(library.sites.map(\.name))
        return candidate.users.contains { saved.contains($0) || hosts.contains($0) }
    }

    private var chosenKeys: [KeyImportCandidate] {
        candidates.filter { keys.contains($0.path) && isUsed($0) }
    }

    private var keyList: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(String(localized: "키체인으로 가져올 키 파일"))
            Text("고른 키는 이 Mac의 키체인에 복사되고, 그 키를 쓰는 연결은 Bottari 키로 바뀝니다. 그 뒤로는 ~/.ssh를 허용하지 않아도 로그인합니다. ~/.ssh의 파일은 그대로 둡니다.")
                .font(.ui(.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if candidates.isEmpty {
                Text("키 파일을 쓰는 연결이 없습니다.")
                    .font(.ui(.caption))
                    .foregroundStyle(.secondary)
            }
            ForEach(candidates) { candidate in
                Toggle(isOn: Binding(
                    get: { keys.contains(candidate.path) },
                    set: { on in if on { keys.insert(candidate.path) } else { keys.remove(candidate.path) } }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(UserHome.abbreviate(candidate.path)).font(.themeMono(.callout))
                        Text(Self.describe(candidate))
                            .font(.ui(.caption))
                            .foregroundStyle(candidate.summary == nil ? Color.orange : Color.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(String(localized: "사용: \(candidate.users.joined(separator: ", "))"))
                            .font(.ui(.caption))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(candidate.summary == nil || !isUsed(candidate))
            }
        }
    }

    private static func describe(_ candidate: KeyImportCandidate) -> String {
        guard let summary = candidate.summary else {
            return String(localized: "읽을 수 없음 · 이 파일이 있는 폴더를 허용해야 합니다")
        }
        var parts = [summary.type, summary.fingerprint].filter { !$0.isEmpty }
        if summary.isEncrypted { parts.append(String(localized: "암호 있음 · 연결할 때 키 암호를 묻습니다")) }
        return parts.joined(separator: " · ")
    }

    // MARK: Actions

    private var importTitle: String {
        let keyCount = chosenKeys.count
        switch (hosts.count, keyCount) {
        case (0, _): return String(localized: "키 \(keyCount)개 가져오기")
        case (_, 0): return String(localized: "호스트 \(hosts.count)개 가져오기")
        default: return String(localized: "호스트 \(hosts.count)개 · 키 \(keyCount)개 가져오기")
        }
    }

    private func reload(selectingAll: Bool) {
        if selectingAll { hosts = Set(library.importableHosts.map(\.alias)) }
        refreshKeys()
        if selectingAll { keys = Set(candidates.filter { $0.summary != nil }.map(\.path)) }
    }

    private func refreshKeys() {
        candidates = library.keyImportCandidates(for: library.importableHosts)
    }

    private func importChosen() {
        let paths = Set(chosenKeys.map(\.path))
        let added = hosts.isEmpty ? [] : library.importSSHConfig(only: hosts)
        let failed = paths.isEmpty ? [] : library.importKeys(paths)
        imported(added)
        if failed.isEmpty {
            dismiss()
        } else {
            unreadable = failed
        }
    }
}
