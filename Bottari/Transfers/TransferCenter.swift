import BottariCore
import BottariSFTP
import BottariTransfer
import SwiftUI

/// Every transfer, filtered by state, with the queue's settings below and the
/// selected one's route and safety steps on the right.
struct TransferCenter: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var filter = Filter.all
    @State private var selection: TransferJob.ID?

    @AppStorage(TransferSettings.maxConcurrentKey) private var maxConcurrent = 3
    @AppStorage(TransferSettings.conflictPolicyKey) private var policy: ConflictPolicy = .ask
    @AppStorage(TransferSettings.verifiesChecksumsKey) private var verifiesChecksums = false

    private var queue: TransferQueue { AppServices.transfers }
    private var records: TransferRecords { AppServices.transferRecords }

    enum Filter: CaseIterable {
        case all, active, paused, finished, failed

        var title: String {
            switch self {
            case .all: String(localized: "전체")
            case .active: String(localized: "진행 중")
            case .paused: String(localized: "filter.paused", defaultValue: "일시정지")
            case .finished: String(localized: "완료")
            case .failed: String(localized: "실패")
            }
        }

        func includes(_ job: TransferJob) -> Bool {
            switch self {
            case .all: true
            case .active: job.isActive
            case .paused: job.state == .paused
            case .finished: job.state == .finished
            case .failed: job.state == .failed || job.state == .cancelled
            }
        }
    }

    private var shown: [TransferJob] { queue.jobs.filter(filter.includes) }
    private var selected: TransferJob? {
        queue.jobs.first { $0.id == selection } ?? shown.first { $0.isActive } ?? shown.first
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                filterBar
                Rectangle().fill(Palette.line).frame(height: 1)
                if shown.isEmpty, records.interrupted.isEmpty {
                    ContentUnavailableView(filter == .all ? String(localized: "전송 기록 없음") : String(localized: "\(filter.title) 항목 없음"), systemImage: "arrow.up.arrow.down")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            if !records.interrupted.isEmpty {
                                InterruptedTransfers(records: records)
                            }
                            ForEach(shown) { job in
                                TransferRow(job: job, isSelected: job.id == selected?.id)
                                    .onTapGesture { selection = job.id }
                            }
                        }
                        .padding(8)
                    }
                }
                Rectangle().fill(Palette.line).frame(height: 1)
                settings
            }
            .card()

            ScrollView {
                if let selected {
                    TransferDetail(job: selected)
                        .padding(16)
                } else {
                    Text("선택한 전송 없음")
                        .font(.ui(.callout))
                        .foregroundStyle(.secondary)
                        .padding(16)
                }
            }
            .frame(width: 380)
            .card()
        }
        .padding(12)
        .background(Palette.background)
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                BackButton(title: String(localized: "메인으로")) { dismissWindow(id: "transfers") }
                WindowHeading(title: String(localized: "전송 센터"))
            }
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 14) {
                    speed(String(localized: "합계 속도"), queue.jobs.filter { $0.state == .running }.map(\.bytesPerSecond).reduce(0, +))
                    speed(String(localized: "Mac 경유 대역폭"), queue.jobs.filter { $0.state == .running && $0.route == .viaMac }.map(\.bytesPerSecond).reduce(0, +))
                }
                .padding(.horizontal, 8)
            }
        }
        .themed()
        .onChange(of: maxConcurrent) { queue.maxConcurrentTransfers = maxConcurrent }
        .onChange(of: verifiesChecksums) { queue.verifiesChecksums = verifiesChecksums }
    }

    private func speed(_ label: String, _ bytesPerSecond: Double) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(label).font(.ui(.caption)).foregroundStyle(.secondary)
            Text(ByteFormat.rate(bytesPerSecond)).font(.themeMono(.body)).fontWeight(.semibold)
        }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(Filter.allCases, id: \.self) { option in
                    let count = queue.jobs.filter(option.includes).count
                    Button {
                        filter = option
                    } label: {
                        HStack(spacing: 5) {
                            Text(option.title).font(.ui(.callout, weight: filter == option ? .semibold : .regular))
                            Text("\(count)").font(.themeMono(.caption)).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(filter == option ? Palette.panel : .clear, in: .rect(cornerRadius: 6))
                        .shadow(color: filter == option ? .black.opacity(0.08) : .clear, radius: 1, y: 1)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(Palette.panel2, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line))
            Spacer()
            Group {
                Button("모두 일시정지") { queue.pauseAll() }
                Button("모두 재개") { queue.resumeAll() }
                Button("완료 항목 제거") { queue.removeEnded() }
            }
            .buttonStyle(PanelButtonStyle())
            .fixedSize()
        }
        .padding(12)
    }

    private var settings: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(String(localized: "동시 전송"))
                HStack(spacing: 8) {
                    Button { maxConcurrent = max(1, maxConcurrent - 1) } label: { Image(systemName: "minus") }
                        .iconHelp(String(localized: "동시 전송 줄이기"))
                    Text("\(maxConcurrent)").font(.themeMono(.body)).frame(minWidth: 20)
                    Button { maxConcurrent = min(8, maxConcurrent + 1) } label: { Image(systemName: "plus") }
                        .iconHelp(String(localized: "동시 전송 늘리기"))
                }
                .buttonStyle(IconButtonStyle())
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(String(localized: "같은 이름의 파일"))
                HStack(spacing: 6) {
                    ForEach(ConflictPolicy.allCases, id: \.self) { option in
                        Button(option.label) { policy = option }
                            .buttonStyle(ChoiceButtonStyle(isOn: policy == option))
                            .fixedSize()
                    }
                }
            }
            .help("새 전송부터 적용")
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(String(localized: "무결성 확인"))
                Toggle("전송 후 체크섬 비교", isOn: $verifiesChecksums)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.ui(.callout))
                    .help("양쪽의 SHA-256 비교 (명령을 실행할 수 있는 서버만)")
            }
            Spacer()
        }
        .padding(14)
    }
}

/// An option among several, outlined in the accent when chosen.
struct ChoiceButtonStyle: ButtonStyle {
    var isOn: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(.callout, weight: isOn ? .medium : .regular))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(isOn ? AnyShapeStyle(Color.themeAccent) : AnyShapeStyle(.primary))
            .background(isOn ? Palette.selection : configuration.isPressed ? Palette.panel2 : Palette.panel, in: .rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isOn ? Color.themeAccent.opacity(0.7) : Palette.line))
            .contentShape(.rect)
    }
}

/// One job: what, the route, progress and state, with its clash or failures below.
struct TransferRow: View {
    let job: TransferJob
    var isSelected = false
    @State private var applyToAll = false
    @State private var hovering = false

    private var queue: TransferQueue { AppServices.transfers }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Image(systemName: job.items.count == 1 ? job.items[0].glyph : "folder")
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(Palette.panel2, in: .rect(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.line))
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.name)
                        .font(.ui(.body, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(job.sizeSummary)
                        .font(.themeMono(.caption))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 210, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    RouteChips(stops: job.stops)
                    Text(job.routeDescription)
                        .font(.ui(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(minWidth: 200, alignment: .leading)
                Spacer(minLength: 8)
                ProgressStrip(value: job.fractionCompleted, tint: job.tint)
                    .frame(width: 180)
                Text(job.percentText)
                    .font(.themeMono(.callout))
                    .fontWeight(.semibold)
                    .frame(width: 44, alignment: .trailing)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(job.stateTitle)
                        .font(.ui(.callout, weight: .medium))
                        .foregroundStyle(job.pendingConflict != nil ? Color.orange : job.tint)
                    Text(job.stateDetail)
                        .font(.ui(.caption))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 96, alignment: .trailing)
                controls
            }
            if let conflict = job.pendingConflict {
                conflictPrompt(conflict)
            }
            if !job.failures.isEmpty {
                failureNote
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isSelected ? Palette.selection : hovering ? Palette.panel2 : .clear, in: .rect(cornerRadius: 8))
        .contentShape(.rect)
        .onHover { hovering = $0 }
    }

    private var controls: some View {
        HStack(spacing: 2) {
            if job.state == .paused {
                Button { queue.resume(job) } label: { Image(systemName: "play.fill") }
                    .iconHelp(String(localized: "재개"))
            } else if job.isActive {
                Button { queue.pause(job) } label: { Image(systemName: "pause.fill") }
                    .iconHelp(String(localized: "일시정지"))
            }
            if job.state.hasEnded {
                Button { queue.remove(job) } label: { Image(systemName: "xmark") }
                    .iconHelp(String(localized: "목록에서 제거"))
            } else {
                Button { queue.cancel(job) } label: { Image(systemName: "stop.fill") }
                    .iconHelp(String(localized: "취소"))
            }
        }
        .font(.system(size: 11))
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .frame(width: 44, alignment: .trailing)
    }

    private func conflictPrompt(_ conflict: TransferConflict) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("같은 이름의 파일이 이미 있습니다: \(conflict.existing.name)")
                    .font(.ui(.callout, weight: .medium))
                Text("기존 파일 \(describe(conflict.existing)) · 보내는 파일 \(describe(conflict.incoming))")
                    .font(.ui(.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("남은 항목에도 적용", isOn: $applyToAll)
                .toggleStyle(.checkbox)
                .font(.ui(.caption))
            Group {
                Button("건너뛰기") { queue.answer(.skip, for: job, applyingToAll: applyToAll) }
                Button("둘 다 유지") { queue.answer(.keepBoth, for: job, applyingToAll: applyToAll) }
                Button("덮어쓰기") { queue.answer(.overwrite, for: job, applyingToAll: applyToAll) }
            }
            .buttonStyle(PanelButtonStyle())
            .fixedSize()
        }
        .padding(10)
        .background(Color.orange.opacity(0.08), in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.35)))
    }

    private var failureNote: some View {
        HStack(spacing: 10) {
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
            if let first = job.failures.first {
                Text("\(first.path.name): \(first.message)" + (job.failures.count > 1 ? String(localized: " 외 \(job.failures.count - 1)개") : ""))
                    .font(.ui(.caption))
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer()
            Group {
                Button("다시 시도") { queue.retryFailures(of: job) }
                Button("실패한 항목 건너뛰기") { queue.skipFailures(of: job) }
            }
            .buttonStyle(PanelButtonStyle())
            .fixedSize()
        }
        .padding(10)
        .background(Color.red.opacity(0.06), in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.red.opacity(0.3)))
    }

    private func describe(_ item: FileItem) -> String {
        [item.formattedSize, item.formattedModified].joined(separator: " · ")
    }
}

/// The selected job: how the bytes flow, the work being done, and the steps
/// that keep the destination file whole.
private struct TransferDetail: View {
    let job: TransferJob
    private var queue: TransferQueue { AppServices.transfers }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    SectionLabel(String(localized: "선택한 전송"))
                    Text(job.name).font(.ui(.title3, weight: .bold)).lineLimit(2)
                    Text([job.sizeSummary, "\(job.stateTitle) \(job.percentText)"].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.themeMono(.caption))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if job.state == .paused {
                    Button("재개") { queue.resume(job) }.buttonStyle(PanelButtonStyle()).fixedSize()
                } else if job.isActive {
                    Button("일시정지") { queue.pause(job) }.buttonStyle(PanelButtonStyle()).fixedSize()
                } else if job.state == .failed {
                    Button("다시 시도") { queue.retryFailures(of: job) }.buttonStyle(PanelButtonStyle()).fixedSize()
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(String(localized: "데이터 흐름"))
                flow
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(String(localized: "경로"))
                routeCard(title: String(localized: "서버 간 직접"), detail: String(localized: "서버 간 SSH 에이전트 포워딩이 필요해 아직 지원하지 않음"), chosen: false, available: false)
                routeCard(title: job.route == .viaMac ? String(localized: "Mac 경유") : job.routeTitle, detail: job.routeExplanation, chosen: true, available: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(String(localized: "실행되는 작업"))
                Text(commands)
                    .font(.themeMono(.caption))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .well()
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(String(localized: "쓰기 단계"))
                ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                    HStack(alignment: .top, spacing: 10) {
                        StepMark(state: step.state)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(step.title).font(.ui(.callout))
                                .foregroundStyle(step.state == .waiting ? AnyShapeStyle(.secondary) : AnyShapeStyle(Palette.text))
                            if let note = step.note {
                                Text(note).font(.themeMono(.caption2)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private var flow: some View {
        HStack(spacing: 4) {
            ForEach(Array(job.stops.enumerated()), id: \.offset) { index, stop in
                if index > 0 {
                    VStack(spacing: 2) {
                        Text("스트림").font(.ui(.caption2)).foregroundStyle(.secondary)
                        HStack(spacing: 0) {
                            Rectangle().fill(.clear).frame(height: 1)
                                .overlay(Rectangle().stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 3])).foregroundStyle(.secondary))
                            Image(systemName: "arrowtriangle.right.fill").font(.system(size: 7)).foregroundStyle(.secondary)
                        }
                    }
                    .frame(minWidth: 30)
                }
                VStack(spacing: 6) {
                    Glyph(symbol(for: stop, at: index), size: 20)
                        .frame(width: 40, height: 40)
                        .background(Palette.panel, in: .rect(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.line))
                    Text(stop.name).font(.ui(.caption, weight: .semibold)).lineLimit(1)
                    Text(caption(for: stop, at: index)).font(.ui(.caption2)).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(minWidth: 70)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .well()
    }

    private func symbol(for stop: RouteStop, at index: Int) -> String {
        if stop.passingThrough { return "bt.mac" }
        let provider = index == 0 ? job.source.provider : job.destination.provider
        return provider.symbol
    }

    private func caption(for stop: RouteStop, at index: Int) -> String {
        if stop.passingThrough { return String(localized: "중계") }
        let provider = index == 0 ? job.source.provider : job.destination.provider
        let verb = index == 0 && job.stops.count > 1 ? String(localized: "읽기") : String(localized: "쓰기")
        if job.stops.count == 1 { return job.kind == .move ? String(localized: "이름 바꾸기") : String(localized: "서버에서 복사") }
        return "\(provider.isLocal ? String(localized: "파일") : provider.kindLabel) \(verb)"
    }

    private func routeCard(title: String, detail: String, chosen: Bool, available: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: chosen ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(chosen ? Color.themeAccent : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.ui(.callout, weight: .semibold))
                Text(detail).font(.ui(.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(chosen ? Palette.selection : Palette.panel, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(chosen ? Color.themeAccent.opacity(0.7) : Palette.line))
        .opacity(available ? 1 : 0.6)
    }

    private var commands: String {
        let from = job.items.first.map { "\(job.source.name):\($0.path.string)" } ?? job.source.name
        let to = "\(job.destination.name):\(job.destinationFolder.appending(job.items.first?.name ?? "").string)"
        switch job.route {
        case .withinLocation:
            return job.kind == .move ? "rename \(from)\n  → \(to)" : String(localized: "cp -a \(from)\n  → \(to)\n다운로드 없이 서버에서 복사")
        case .local:
            return "read  \(from)\n  ↳ write \(to)"
        default:
            let reader = job.source.provider.isLocal ? "read " : "\(job.source.provider.kindLabel) read "
            let writer = job.destination.provider.isLocal ? "write" : "\(job.destination.provider.kindLabel) write"
            return String(localized: "\(reader) \(from)\n  ↳ \(writer) \(to)\n실패 시 받은 부분부터 이어서 전송")
        }
    }

    private struct Step {
        let title: String
        var note: String?
        let state: StepState
    }

    private var steps: [Step] {
        let started = job.state != .queued && job.state != .preparing
        let finished = job.state == .finished
        let partName = job.items.first.map { RemotePath("/").appending($0.name).partialWritePath.name } ?? ".bottari-part"
        var steps = [
            Step(title: String(localized: "대상 크기 및 권한 확인"), state: started ? .done : job.state == .preparing ? .current : .waiting),
            Step(title: String(localized: "임시 이름으로 쓰기"), note: partName, state: finished ? .done : started ? .current : .waiting),
        ]
        if job.verifiesChecksums {
            steps.append(Step(title: String(localized: "체크섬 비교 (SHA-256)"), state: finished ? .done : .waiting))
        }
        steps.append(Step(title: String(localized: "원래 이름으로 바꾸기 (rename)"), note: String(localized: "중단되어도 기존 파일 유지"), state: finished ? .done : .waiting))
        return steps
    }
}

private enum StepState {
    case done, current, waiting
}

private struct StepMark: View {
    let state: StepState

    var body: some View {
        ZStack {
            Circle()
                .fill(state == .done ? Color(light: 0x0F7C5A, dark: 0x3CC48E) : state == .current ? Palette.selection : .clear)
            Circle()
                .strokeBorder(state == .done ? .clear : state == .current ? Color.themeAccent : Palette.line, lineWidth: 1.5)
            if state == .done {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
            }
        }
        .frame(width: 18, height: 18)
    }
}

extension TransferJob {
    /// "Mac 경유 · prod-web → Google Drive"
    var routeDescription: String {
        let names = "\(source.name) → \(destination.name)"
        return switch route {
        case .withinLocation: source.provider.isLocal ? String(localized: "Mac 안에서 · \(source.name)") : String(localized: "서버 안에서 \(kind == .move ? String(localized: "이동") : String(localized: "복사")) · \(source.name)")
        case .upload: String(localized: "업로드 · \(names)")
        case .download: String(localized: "다운로드 · \(names)")
        case .viaMac: String(localized: "Mac 경유 · \(names)")
        case .local: String(localized: "Mac 안에서 · \(names)")
        }
    }

    var routeTitle: String {
        switch route {
        case .withinLocation: source.provider.isLocal ? String(localized: "Mac 안에서") : String(localized: "서버 안에서")
        case .upload: String(localized: "업로드")
        case .download: String(localized: "다운로드")
        case .viaMac: String(localized: "Mac 경유")
        case .local: String(localized: "Mac 안에서")
        }
    }

    var routeExplanation: String {
        switch route {
        case .viaMac: String(localized: "Mac이 중계하며 Mac의 대역폭 사용")
        case .withinLocation: String(localized: "다운로드 없이 서버에서 직접 처리")
        case .upload: String(localized: "Mac에서 읽어 바로 업로드")
        case .download: String(localized: "서버에서 받아 Mac에 저장")
        case .local: String(localized: "Mac 안에서 복사")
        }
    }
}

/// Transfers the app was in the middle of when it last quit, each ready to
/// carry on from where it stopped.
struct InterruptedTransfers: View {
    let records: TransferRecords

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("지난번에 끝나지 않은 전송")
                .font(.ui(.caption, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            ForEach(records.interrupted) { record in
                row(record)
            }
        }
        .padding(.bottom, 8)
    }

    private func row(_ record: TransferRecord) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.clockwise")
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(Palette.panel2, in: .rect(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.line))
            VStack(alignment: .leading, spacing: 2) {
                Text(record.name)
                    .font(.ui(.body, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(record.source.name) → \(record.destination.name) · \(record.folder.string)")
                    .font(.themeMono(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let problem = records.problems[record.id] {
                    Text(problem)
                        .font(.ui(.caption))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Text(progress(record))
                .font(.ui(.caption))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if records.resuming.contains(record.id) {
                ProgressView().controlSize(.small)
            } else {
                Button("이어서 전송") { Task { await records.resume(record) } }
                    .buttonStyle(PanelButtonStyle())
                    .fixedSize()
            }
            Button { records.forget(record) } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .iconHelp(String(localized: "목록에서 지우기"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Palette.panel2, in: .rect(cornerRadius: 8))
    }

    private func progress(_ record: TransferRecord) -> String {
        var parts = [String(localized: "파일 \(record.done.count)/\(max(record.totalFiles, record.done.count))개 완료")]
        if record.totalBytes > 0 {
            parts.append("\(ByteFormat.string(record.transferredBytes)) / \(ByteFormat.string(record.totalBytes))")
        }
        return parts.joined(separator: " · ")
    }
}
