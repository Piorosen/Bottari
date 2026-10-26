import BottariCore
import BottariSFTP
import BottariTransfer
import SwiftUI

/// Asks before writing to (or moving out of) a site marked "confirm before
/// writing", as in the design: the target with its tag, what will happen, and
/// the items. PROD sites get the warning colour and no default button.
struct WriteConfirmationSheet: View {
    let request: TransferRequest
    let confirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var writesToGuardedSite: Bool { request.destinationSite?.confirmsWrites == true }
    private var site: SavedSite? { writesToGuardedSite ? request.destinationSite : request.sourceSite }
    private var isProd: Bool { site?.tag == .prod }
    private var band: Color { isProd ? SavedSite.Tag.prod.color : .accentColor }
    private var verb: String { request.kind == .move ? "이동합니다" : "복사합니다" }

    private var title: String {
        let name = site?.name ?? ""
        return switch (writesToGuardedSite, isProd) {
        case (true, true): "운영 서버에 파일을 씁니다"
        case (true, false): "‘\(name)’에 파일을 씁니다"
        case (false, true): "운영 서버에서 파일을 이동합니다"
        case (false, false): "‘\(name)’에서 파일을 이동합니다"
        }
    }

    private var summary: String {
        let consequence = writesToGuardedSite
            ? "같은 이름의 파일은 \(TransferSettings.conflictPolicy.consequence)."
            : "전송이 끝나면 원본을 삭제합니다."
        return "다음 \(request.items.count)개 항목을 \(verb). \(consequence)"
    }

    private var targetPath: String {
        writesToGuardedSite ? request.folder.string : (request.items.first?.path.parent?.string ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(band)
                .frame(height: 4)
            VStack(alignment: .leading, spacing: 14) {
                Label {
                    Text(title)
                        .font(.ui(.title3, weight: .semibold))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(band)
                }
                HStack(spacing: 8) {
                    Glyph("bt.server", size: 16)
                        .foregroundStyle(band)
                    Text(site?.name ?? "")
                        .font(.ui(.headline))
                    if let tag = site?.tag {
                        TagChip(tag: tag)
                    }
                    Spacer()
                    Text(targetPath)
                        .font(.themeMono(.callout))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .padding(10)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
                Text(summary)
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(request.items.prefix(12)) { item in
                            Label(item.name, systemImage: item.isDirectory ? "folder" : "doc")
                                .lineLimit(1)
                        }
                        if request.items.count > 12 {
                            Text("외 \(request.items.count - 12)개")
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
                    if isProd {
                        // No Return shortcut: writing to production takes a deliberate click.
                        Button(request.kind == .move ? "이동" : "복사", role: .destructive) {
                            confirm()
                            dismiss()
                        }
                    } else {
                        Button(request.kind == .move ? "이동" : "복사") {
                            confirm()
                            dismiss()
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .padding(20)
        }
        .frame(width: 480)
    }
}
