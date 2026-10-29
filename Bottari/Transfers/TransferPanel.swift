import BottariCore
import BottariTransfer
import SwiftUI

/// The strip under the panes: the transfer in progress with its route and
/// speed, the clipboard, and the way into the transfer center.
struct TransferBar: View {
    @Bindable var workspace: Workspace
    @Environment(\.openWindow) private var openWindow

    private var queue: TransferQueue { AppServices.transfers }

    /// A job waiting for an answer first, then one in progress, then one that failed.
    private var featured: TransferJob? {
        queue.jobs.first { $0.pendingConflict != nil }
            ?? queue.jobs.first { $0.state == .running || $0.state == .preparing }
            ?? queue.jobs.last { $0.state == .failed }
    }

    private var activeCount: Int {
        queue.jobs.filter(\.isActive).count
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                openWindow(id: "transfers")
            } label: {
                HStack(spacing: 6) {
                    Glyph("bt.transfer", size: 15)
                    Text(activeCount > 0 ? String(localized: "전송 \(activeCount)개 진행 중") : String(localized: "전송"))
                        .font(.ui(.callout, weight: .semibold))
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Palette.panel, in: .rect(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.line))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("전송 센터")
            if let job = featured {
                Text(job.name)
                    .font(.ui(.callout, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 220, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                RouteChips(stops: job.stops)
                ProgressStrip(value: job.fractionCompleted, tint: job.tint)
                    .frame(minWidth: 120)
                Text(job.percentText)
                    .font(.ui(.callout, weight: .semibold))
                    .monospacedDigit()
                if job.pendingConflict != nil || job.state == .failed {
                    Text(job.statusText)
                        .font(.ui(.callout))
                        .foregroundStyle(job.pendingConflict != nil ? Color.orange : job.tint)
                } else if job.bytesPerSecond > 0 {
                    Text(ByteFormat.rate(job.bytesPerSecond))
                        .font(.ui(.callout))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            } else if !AppServices.transferRecords.interrupted.isEmpty {
                Button("끝나지 않은 전송 \(AppServices.transferRecords.interrupted.count)개 · 이어서 보내기") {
                    openWindow(id: "transfers")
                }
                .buttonStyle(.link)
                .font(.ui(.callout))
                Spacer(minLength: 8)
            } else {
                Text("대기 중인 전송 없음")
                    .font(.ui(.callout))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
            }
            ExternalEditsButton()
            if let count = AppServices.clipboard.content?.items.count {
                Text("클립보드 \(count)개 · ⌘V")
                    .font(.ui(.caption))
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Palette.panel)
        .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
    }
}

/// "외부 편집 2" with the files being edited in other apps.
struct ExternalEditsButton: View {
    @State private var showsList = false
    private var edits: ExternalEdits { .shared }

    var body: some View {
        if !edits.sessions.isEmpty {
            Button {
                showsList.toggle()
            } label: {
                Label("외부 편집 \(edits.sessions.count)", systemImage: "square.and.pencil")
            }
            .popover(isPresented: $showsList) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("외부 에디터에서 편집 중")
                        .font(.ui(.headline))
                    Text("저장하면 서버에 자동으로 업로드됩니다.")
                        .font(.ui(.caption))
                        .foregroundStyle(.secondary)
                    ForEach(edits.sessions) { session in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.item.name)
                                Text("\(session.provider.displayName) · \(session.status)")
                                    .font(.ui(.caption))
                                    .foregroundStyle(session.blockedByServerChange ? .orange : .secondary)
                            }
                            Spacer()
                            if session.blockedByServerChange {
                                Button("그래도 업로드") { edits.uploadAnyway(session) }
                            }
                            Button("열기") { NSWorkspace.shared.open(session.localURL) }
                            Button("중단") { edits.stop(session) }
                        }
                        .controlSize(.small)
                    }
                }
                .padding(14)
                .frame(width: 420)
            }
        }
    }
}
