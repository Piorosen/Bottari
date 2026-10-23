import Foundation

/// Errors every provider reports in the same shape, so the UI can explain them
/// without knowing whether they came from the Mac, SFTP or a cloud API.
public enum ProviderError: Error, Equatable, Sendable {
    case notFound(RemotePath)
    case alreadyExists(RemotePath)
    case notADirectory(RemotePath)
    case isADirectory(RemotePath)
    case permissionDenied(RemotePath)
    /// The provider cannot do this at all; the associated value names the operation.
    case unsupported(String)
    case io(String)
}

extension ProviderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notFound(let path): "찾을 수 없어요: \(path)"
        case .alreadyExists(let path): "같은 이름이 이미 있어요: \(path)"
        case .notADirectory(let path): "폴더가 아니에요: \(path)"
        case .isADirectory(let path): "파일이 아니라 폴더예요: \(path)"
        case .permissionDenied(let path): "권한이 없어요: \(path)"
        case .unsupported(let operation): "이 위치에서는 지원하지 않아요: \(operation)"
        case .io(let message): message
        }
    }
}
