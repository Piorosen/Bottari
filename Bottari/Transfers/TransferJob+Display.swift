import BottariCore
import BottariTransfer
import SwiftUI

extension TransferJob {
    /// "186 MB · 214개 파일", or how much preparation has found so far.
    var sizeSummary: String {
        let bytes = totalBytes.formatted(.byteCount(style: .file))
        if state == .preparing { return "준비 중 · \(totalFiles)개 찾음" }
        if totalFiles <= 1 { return totalBytes > 0 ? bytes : "" }
        return totalBytes > 0 ? "\(bytes) · \(totalFiles)개 파일" : "\(totalFiles)개 항목"
    }

    var routeLabel: String {
        let verb = kind == .move ? "이동" : "복사"
        return switch route {
        case .withinLocation: source.provider.isLocal ? "Mac 안에서 \(verb)" : "서버 안에서 \(verb)"
        case .upload: "업로드 · \(verb)"
        case .download: "다운로드 · \(verb)"
        case .viaMac: "Mac 경유 · \(verb)"
        case .local: "Mac 안에서 \(verb)"
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
            return "대기"
        case .preparing:
            return "준비 중"
        case .running:
            if pendingConflict != nil { return "확인이 필요해요" }
            var parts: [String] = []
            if bytesPerSecond > 0 { parts.append("\(Int64(bytesPerSecond).formatted(.byteCount(style: .file)))/s") }
            if let seconds = secondsRemaining { parts.append(Self.remaining(seconds)) }
            return parts.isEmpty ? "전송 중" : parts.joined(separator: " · ")
        case .paused:
            return "일시정지"
        case .finished:
            return skippedFiles > 0 ? "완료 · \(skippedFiles)개 건너뜀" : "완료"
        case .failed:
            return "\(failures.count)개 실패"
        case .cancelled:
            return "취소됨"
        }
    }

    var percentText: String {
        "\(Int((fractionCompleted * 100).rounded(.down)))%"
    }

    var tint: Color {
        switch state {
        case .failed: .red
        case .finished: .green
        case .paused, .cancelled: .secondary
        default: .accentColor
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
        if total < 60 { return "약 \(total)초 남음" }
        let minutes = total / 60
        if minutes < 60 { return "약 \(minutes)분 남음" }
        return "약 \(minutes / 60)시간 \(minutes % 60)분 남음"
    }
}

struct RouteStop: Hashable {
    let name: String
    /// The Mac relaying between two servers, drawn dashed.
    var passingThrough = false
}

/// `prod-web → Mac → dev-api`, as small chips.
struct RouteChips: View {
    let stops: [RouteStop]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(stops.enumerated()), id: \.offset) { index, stop in
                if index > 0 {
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(stop.name)
                    .font(.caption)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .foregroundStyle(stop.passingThrough ? .secondary : .primary)
                    .background {
                        if stop.passingThrough {
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        } else {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(.quaternary)
                        }
                    }
            }
        }
    }
}
