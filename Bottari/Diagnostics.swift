import AppKit
import BottariCore
import BottariSFTP
import BottariTransfer
import UniformTypeIdentifiers

/// A text file to attach to a bug report: the app and Mac, the saved
/// connections without their secrets, the transfers, and the recent log.
enum Diagnostics {
    /// Where the log is written: `~/Library/Logs/Bottari`, which Console.app lists too.
    static let logFile = URL.libraryDirectory.appending(path: "Logs/Bottari/bottari.log")

    static func startLogging() {
        Log.writeToFile(at: logFile)
        Log.app.info("Bottari \(version) 시작, macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    }

    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
    }

    @MainActor
    static func report() -> String {
        var lines = [
            String(localized: "Bottari 진단 정보"),
            String(localized: "만든 시각: \(Date().formatted(.iso8601))"),
            String(localized: "버전: \(version)"),
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            String(localized: "기기: \(hardwareModel)"),
            "",
            String(localized: "저장된 연결 (비밀번호, 키, 토큰은 넣지 않음)"),
        ]
        for site in AppServices.sites.sites {
            lines.append("- " + describe(site))
        }
        lines += ["", String(localized: "전송")]
        for job in AppServices.transfers.jobs {
            lines.append(String(localized: "- \(job.name): \(job.source.name) → \(job.destination.name), \(String(describing: job.state)), 파일 \(job.completedFiles)/\(job.totalFiles), 실패 \(job.failures.count)"))
            for failure in job.failures.prefix(10) {
                lines.append("    \(failure.path): \(failure.message)")
            }
        }
        for record in AppServices.transferRecords.interrupted {
            lines.append(String(localized: "- (지난번에 끝나지 않음) \(record.name): \(record.source.name) → \(record.destination.name), 완료 \(record.done.count)/\(record.totalFiles)"))
        }
        lines += ["", String(localized: "최근 로그 (\(logFile.path))")]
        lines += Log.recentLines()
        return lines.joined(separator: "\n") + "\n"
    }

    /// Asks where to save the report, then saves it.
    @MainActor
    static func save() {
        let panel = NSSavePanel()
        panel.title = String(localized: "진단 정보 저장")
        panel.message = String(localized: "서버 이름과 주소가 들어 있습니다. 비밀번호와 키는 들어 있지 않습니다.")
        panel.nameFieldStringValue = String(localized: "Bottari-진단-\(Date().formatted(.iso8601.year().month().day())).txt")
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try report().write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private static func describe(_ site: SavedSite) -> String {
        switch site.kind {
        case .s3(let settings):
            return "\(site.name): S3 \(settings.bucket) (\(settings.endpoint.isEmpty ? settings.region : settings.endpoint))"
        case .googleDrive:
            return "\(site.name): Google Drive"
        case .sftp:
            let auth = switch site.authentication {
            case .defaultKeys: String(localized: "기본 키")
            case .keyFile: String(localized: "키 파일")
            case .password: String(localized: "비밀번호")
            }
            var parts = ["\(site.name): SFTP \(site.endpoint.username)@\(site.endpoint.hostKeyID)", auth]
            if !site.proxyJump.isEmpty { parts.append(String(localized: "경유 \(site.proxyJump.joined(separator: " → "))")) }
            if site.readOnly { parts.append(String(localized: "읽기 전용")) }
            return parts.joined(separator: ", ")
        }
    }

    private static var hardwareModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(decoding: model.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
