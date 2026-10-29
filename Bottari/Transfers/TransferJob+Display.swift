import BottariCore
import BottariTransfer
import SwiftUI

extension TransferJob {
    /// "186 MB · 214개 파일", or how much preparation has found so far.
    var sizeSummary: String {
        let bytes = ByteFormat.string(totalBytes)
        if state == .preparing { return String(localized: "준비 중 · \(totalFiles)개 찾음") }
        if totalFiles <= 1 { return totalBytes > 0 ? bytes : "" }
        return totalBytes > 0 ? String(localized: "\(bytes) · \(totalFiles)개 파일") : String(localized: "\(totalFiles)개 항목")
    }

    var routeLabel: String {
        let verb = kind == .move ? String(localized: "이동") : String(localized: "복사")
        return switch route {
        case .withinLocation: source.provider.isLocal ? String(localized: "Mac 안에서 \(verb)") : String(localized: "서버 안에서 \(verb)")
        case .upload: String(localized: "업로드 · \(verb)")
        case .download: String(localized: "다운로드 · \(verb)")
        case .viaMac: String(localized: "Mac 경유 · \(verb)")
        case .local: String(localized: "Mac 안에서 \(verb)")
        }
    }

    /// The places the bytes pass through, for the route chips.
    var stops: [RouteStop] {
        switch route {
        case .withinLocation, .local:
            [RouteStop(name: source.name)]
        case .upload, .download:
            [RouteStop(name: source.name), RouteStop(name: destination.name)]
        case .viaMac:
            [RouteStop(name: source.name), RouteStop(name: "Mac", passingThrough: true), RouteStop(name: destination.name)]
        }
    }

    var statusText: String {
        switch state {
        case .queued:
            return String(localized: "대기")
        case .preparing:
            return String(localized: "준비 중")
        case .running:
            if pendingConflict != nil { return String(localized: "확인 필요") }
            var parts: [String] = []
            if bytesPerSecond > 0 { parts.append("\(ByteFormat.rate(bytesPerSecond))") }
            if let seconds = secondsRemaining { parts.append(Self.remaining(seconds)) }
            return parts.isEmpty ? String(localized: "전송 중") : parts.joined(separator: " · ")
        case .paused:
            return String(localized: "일시정지")
        case .finished:
            var parts = [String(localized: "완료")]
            if verifiedFiles > 0 { parts.append(verifiedFiles == completedFiles ? String(localized: "체크섬 일치") : String(localized: "체크섬 \(verifiedFiles)개 일치")) }
            if skippedFiles > 0 { parts.append(String(localized: "\(skippedFiles)개 건너뜀")) }
            return parts.joined(separator: " · ")
        case .failed:
            return String(localized: "\(failures.count)개 실패")
        case .cancelled:
            return String(localized: "취소됨")
        }
    }

    var percentText: String {
        "\(Int((fractionCompleted * 100).rounded(.down)))%"
    }

    var tint: Color {
        switch state {
        case .failed: Color(light: 0xB42318, dark: 0xF07A6E)
        case .finished: Color(light: 0x0F7C5A, dark: 0x3CC48E)
        case .paused, .cancelled, .queued: Color(light: 0x5F6776, dark: 0x8F97A4)
        default: .themeAccent
        }
    }

    /// "전송 중", "일시정지", "실패", "완료": the word in the status column.
    var stateTitle: String {
        switch state {
        case .queued: String(localized: "대기")
        case .preparing: String(localized: "준비 중")
        case .running: pendingConflict != nil ? String(localized: "확인 필요") : String(localized: "전송 중")
        case .paused: String(localized: "일시정지")
        case .finished: String(localized: "완료")
        case .failed: String(localized: "실패")
        case .cancelled: String(localized: "취소됨")
        }
    }

    /// The line under it: time left, why it stopped, whether checksums matched.
    var stateDetail: String {
        switch state {
        case .running:
            if pendingConflict != nil { return String(localized: "같은 이름 있음") }
            return secondsRemaining.map(Self.remaining) ?? (bytesPerSecond > 0 ? ByteFormat.rate(bytesPerSecond) : "")
        case .paused: return String(localized: "대기")
        case .failed: return String(localized: "\(failures.count)개 파일 실패")
        case .finished:
            if verifiedFiles > 0 { return verifiedFiles == completedFiles ? String(localized: "체크섬 일치") : String(localized: "체크섬 \(verifiedFiles)개 일치") }
            return skippedFiles > 0 ? String(localized: "\(skippedFiles)개 건너뜀") : ""
        default: return ""
        }
    }

    var symbol: String {
        items.count == 1 && !items[0].isDirectory ? "doc" : "folder"
    }

    var isActive: Bool {
        [.queued, .preparing, .running].contains(state)
    }

    static func remaining(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return String(localized: "약 \(total)초 남음") }
        let minutes = total / 60
        if minutes < 60 { return String(localized: "약 \(minutes)분 남음") }
        return String(localized: "약 \(minutes / 60)시간 \(minutes % 60)분 남음")
    }
}

struct RouteStop: Hashable {
    let name: String
    /// The Mac relaying between two servers, drawn dashed.
    var passingThrough = false
}

/// `prod-web → Mac → dev-api`, as small mono chips; the Mac relaying is dashed.
struct RouteChips: View {
    let stops: [RouteStop]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(stops.enumerated()), id: \.offset) { index, stop in
                if index > 0 {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                MonoChip(text: stop.name, dashed: stop.passingThrough)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "경로: ") + stops.map { $0.passingThrough ? String(localized: "\($0.name) 경유") : $0.name }.joined(separator: ", "))
    }
}

/// A thin rounded progress bar in the job's colour.
struct ProgressStrip: View {
    let value: Double
    var tint: Color = .themeAccent

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.line)
                Capsule().fill(tint).frame(width: max(0, min(1, value)) * geometry.size.width)
            }
        }
        .frame(height: 5)
        .accessibilityElement()
        .accessibilityLabel("진행률")
        .accessibilityValue("\(Int((max(0, min(1, value)) * 100).rounded()))%")
    }
}
