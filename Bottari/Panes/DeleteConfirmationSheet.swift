import BottariCore
import BottariSFTP
import SwiftUI

/// Asks before deleting on a server, where there is no trash to undo it.
/// Return does nothing here: deleting takes a deliberate click.
struct DeleteConfirmationSheet: View {
    let deletion: DeletionRequest
    let confirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var isProd: Bool { deletion.site?.tag == .prod }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(isProd ? SavedSite.Tag.prod.color : .red)
                .frame(height: 4)
            VStack(alignment: .leading, spacing: 14) {
                Label {
                    Text("\(deletion.items.count)개 항목을 삭제할까요?")
                        .font(.title3.weight(.semibold))
                } icon: {
                    Image(systemName: "trash.fill")
                        .foregroundStyle(.red)
                }
                if let site = deletion.site {
                    HStack(spacing: 8) {
                        Image(systemName: "server.rack")
                            .foregroundStyle(isProd ? SavedSite.Tag.prod.color : .secondary)
                        Text(site.name)
                            .font(.headline)
                        if let tag = site.tag {
                            TagChip(tag: tag)
                        }
                        Spacer()
                        Text(deletion.folder.string)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
                }
                Text("서버에는 휴지통이 없어서 되돌릴 수 없어요. 폴더는 안의 내용까지 모두 지워요.")
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(deletion.items.prefix(12)) { item in
                            Label(item.name, systemImage: item.isDirectory ? "folder" : "doc")
                                .lineLimit(1)
                        }
                        if deletion.items.count > 12 {
                            Text("외 \(deletion.items.count - 12)개")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                HStack {
                    Spacer()
                    Button("취소", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("삭제", role: .destructive) {
                        confirm()
                        dismiss()
                    }
                }
            }
            .padding(20)
        }
        .frame(width: 460)
    }
}
