import BottariCore
import SwiftUI

/// Items whose permissions the user is about to change.
struct PermissionsRequest: Identifiable {
    let id = UUID()
    let items: [FileItem]
}

/// Read, write and execute for owner, group and everyone, as boxes and as the
/// octal number `chmod` takes; for folders, how far down the change goes.
struct PermissionsSheet: View {
    let items: [FileItem]
    let apply: (_ mode: UInt16, _ scope: PaneModel.PermissionScope) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var mode: UInt16
    @State private var octal: String
    @State private var scope = PaneModel.PermissionScope.chosenOnly

    init(items: [FileItem], apply: @escaping (_ mode: UInt16, _ scope: PaneModel.PermissionScope) -> Void) {
        self.items = items
        self.apply = apply
        let start = items.first?.permissions ?? (items.first?.isDirectory == true ? 0o755 : 0o644)
        _mode = State(initialValue: start & 0o7777)
        _octal = State(initialValue: String(start & 0o7777, radix: 8))
    }

    private static let classes: [(title: String, shift: UInt16)] = [(String(localized: "소유자"), 6), (String(localized: "그룹"), 3), (String(localized: "모든 사용자"), 0)]
    private static let rights: [(title: String, bit: UInt16, letter: String)] = [(String(localized: "읽기"), 4, "r"), (String(localized: "쓰기"), 2, "w"), (String(localized: "실행"), 1, "x")]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("권한 변경")
                    .font(.ui(.title3, weight: .semibold))
                Text(items.count == 1 ? items[0].name : String(localized: "\(items[0].name) 외 \(items.count - 1)개"))
                    .font(.themeMono(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    ForEach(Self.rights, id: \.bit) { right in
                        Text(right.title).font(.ui(.caption)).foregroundStyle(.secondary)
                    }
                }
                ForEach(Self.classes, id: \.shift) { group in
                    GridRow {
                        Text(group.title).font(.ui(.callout))
                        ForEach(Self.rights, id: \.bit) { right in
                            Toggle("\(group.title) \(right.title)", isOn: bit(right.bit << group.shift))
                                .labelsHidden()
                                .toggleStyle(.checkbox)
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                Text("숫자로").font(.ui(.callout))
                TextField("755", text: $octal)
                    .designField(mono: true)
                    .frame(width: 80)
                    .onChange(of: octal) {
                        if let parsed = UInt16(octal, radix: 8), parsed <= 0o7777 { mode = parsed }
                    }
                Text(symbolic)
                    .font(.themeMono(.callout))
                    .foregroundStyle(.secondary)
            }
            if items.contains(where: { $0.isDirectory && !$0.isSymbolicLink }) {
                Picker("폴더 안의 항목", selection: $scope) {
                    ForEach(PaneModel.PermissionScope.allCases, id: \.self) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                .font(.ui(.callout))
            }
            HStack {
                Spacer()
                Button("취소", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("적용") {
                    apply(mode, scope)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(UInt16(octal, radix: 8).map { $0 > 0o7777 } ?? true)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    /// One permission bit as a checkbox, keeping the number in step.
    private func bit(_ value: UInt16) -> Binding<Bool> {
        Binding(
            get: { mode & value != 0 },
            set: { on in
                mode = on ? mode | value : mode & ~value
                octal = String(mode, radix: 8)
            }
        )
    }

    /// `rwxr-xr-x`, as `ls -l` shows it.
    private var symbolic: String {
        Self.classes.map { group in
            Self.rights.map { right in mode & (right.bit << group.shift) != 0 ? right.letter : "-" }.joined()
        }.joined()
    }
}
