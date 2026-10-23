import BottariCore
import BottariTransfer
import SwiftUI

/// The strip under the panes: the transfer in progress, the clipboard, and a
/// button for the full list.
struct TransferBar: View {
    @Bindable var workspace: Workspace

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
        HStack(spacing: 10) {
            if let job = featured {
                Image(systemName: job.symbol)
                    .foregroundStyle(.secondary)
                Text(job.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 220, alignment: .leading)
                RouteChips(stops: job.stops)
                ProgressView(value: job.fractionCompleted)
                    .tint(job.tint)
                    .frame(width: 140)
                Text(job.percentText)
                    .monospacedDigit()
                Text(job.statusText)
                    .foregroundStyle(job.pendingConflict != nil ? .orange : .secondary)
            } else {
                Text("대기 중인 전송이 없어요")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            ExternalEditsButton()
            if let count = AppServices.clipboard.content?.items.count {
                Text("클립보드: \(count)개 · ⌘V 붙여넣기")
                    .foregroundStyle(.secondary)
            }
            Button {
                workspace.showsTransfers.toggle()
            } label: {
                Label(activeCount > 0 ? "\(activeCount)개 전송 중" : "전송", systemImage: "arrow.up.arrow.down")
            }
            .help("전송 목록 \(workspace.showsTransfers ? "닫기" : "열기")")
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// Every transfer, with controls, and the queue's settings.
struct TransferPanel: View {
    @Bindable var workspace: Workspace
    @AppStorage(TransferSettings.maxConcurrentKey) private var maxConcurrent = 3
    @AppStorage(TransferSettings.conflictPolicyKey) private var policy: ConflictPolicy = .ask
    @AppStorage(TransferSettings.verifiesChecksumsKey) private var verifiesChecksums = false

    private var queue: TransferQueue { AppServices.transfers }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("전송")
                    .font(.headline)
                Spacer()
                Stepper("동시 전송 \(maxConcurrent)", value: $maxConcurrent, in: 1...8)
                    .fixedSize()
                Picker("같은 이름", selection: $policy) {
                    ForEach(ConflictPolicy.allCases, id: \.self) { policy in
                        Text(policy.label).tag(policy)
                    }
                }
                .fixedSize()
                .help("같은 이름의 파일이 있을 때. 새로 시작하는 전송부터 적용돼요.")
                Toggle("체크섬 비교", isOn: $verifiesChecksums)
                    .toggleStyle(.checkbox)
                    .help("전송한 뒤 양쪽에서 SHA-256을 계산해 비교해요. 서버는 명령을 실행할 수 있을 때만 돼요.")
                Button("모두 일시정지") { queue.pauseAll() }
                Button("모두 재개") { queue.resumeAll() }
                Button("완료 항목 지우기") { queue.removeEnded() }
                Button {
                    workspace.showsTransfers = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("전송 목록 닫기")
            }
            .controlSize(.small)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()
            if queue.jobs.isEmpty {
                Text("전송 기록이 없어요")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(queue.jobs) { job in
                            TransferRow(job: job)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(height: 250)
        .onChange(of: maxConcurrent) {
            queue.maxConcurrentTransfers = maxConcurrent
        }
        .onChange(of: verifiesChecksums) {
            queue.verifiesChecksums = verifiesChecksums
        }
    }
}

private struct TransferRow: View {
    let job: TransferJob
    @State private var applyToAll = false

    private var queue: TransferQueue { AppServices.transfers }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: job.symbol)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(job.sizeSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 220, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    RouteChips(stops: job.stops)
                    Text(job.routeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                ProgressView(value: job.fractionCompleted)
                    .tint(job.tint)
                    .frame(width: 140)
                Text(job.percentText)
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
                Text(job.statusText)
                    .font(.caption)
                    .foregroundStyle(job.state == .failed ? .red : .secondary)
                    .lineLimit(1)
                    .frame(width: 150, alignment: .leading)
                controls
            }
            if let conflict = job.pendingConflict {
                conflictPrompt(conflict)
            }
            if !job.failures.isEmpty {
                failureNote
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 4) {
            if job.state == .paused {
                Button { queue.resume(job) } label: { Image(systemName: "play.fill") }
                    .help("재개")
            } else if job.isActive {
                Button { queue.pause(job) } label: { Image(systemName: "pause.fill") }
                    .help("일시정지")
            }
            if job.state.hasEnded {
                Button { queue.remove(job) } label: { Image(systemName: "xmark") }
                    .help("목록에서 지우기")
            } else {
                Button { queue.cancel(job) } label: { Image(systemName: "stop.fill") }
                    .help("취소")
            }
        }
        .buttonStyle(.borderless)
        .frame(width: 44, alignment: .trailing)
    }

    private func conflictPrompt(_ conflict: TransferConflict) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("같은 이름이 이미 있어요: \(conflict.existing.name)")
                    .font(.callout.weight(.medium))
                Text("있는 파일 \(describe(conflict.existing)) · 보낼 파일 \(describe(conflict.incoming))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("남은 항목에도 적용", isOn: $applyToAll)
                .toggleStyle(.checkbox)
            Button("건너뛰기") { queue.answer(.skip, for: job, applyingToAll: applyToAll) }
            Button("둘 다 유지") { queue.answer(.keepBoth, for: job, applyingToAll: applyToAll) }
            Button("덮어쓰기") { queue.answer(.overwrite, for: job, applyingToAll: applyToAll) }
        }
        .controlSize(.small)
        .padding(8)
        .background(.orange.opacity(0.08), in: .rect(cornerRadius: 6))
    }

    private var failureNote: some View {
        HStack(spacing: 10) {
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
            if let first = job.failures.first {
                Text("\(first.path.name): \(first.message)" + (job.failures.count > 1 ? " 외 \(job.failures.count - 1)개" : ""))
                    .font(.caption)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("다시 시도") { queue.retryFailures(of: job) }
            Button("실패한 항목 건너뛰기") { queue.skipFailures(of: job) }
        }
        .controlSize(.small)
        .padding(8)
        .background(.red.opacity(0.06), in: .rect(cornerRadius: 6))
    }

    private func describe(_ item: FileItem) -> String {
        [item.formattedSize, item.formattedModified].joined(separator: " · ")
    }
}

/// "외부 편집 2" with the files being edited in other apps.
private struct ExternalEditsButton: View {
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
                        .font(.headline)
                    Text("임시 폴더에 받아 두고, 저장을 감지하면 자동으로 올려요.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(edits.sessions) { session in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.item.name)
                                Text("\(session.provider.displayName) · \(session.status)")
                                    .font(.caption)
                                    .foregroundStyle(session.blockedByServerChange ? .orange : .secondary)
                            }
                            Spacer()
                            if session.blockedByServerChange {
                                Button("그래도 올리기") { edits.uploadAnyway(session) }
                            }
                            Button("열기") { NSWorkspace.shared.open(session.localURL) }
                            Button("그만") { edits.stop(session) }
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
