import BottariCore
import Foundation

extension FileItem {
    var formattedSize: String {
        guard let size, !isDirectory else { return "—" }
        return size.formatted(.byteCount(style: .file))
    }

    var formattedModified: String {
        guard let modified else { return "—" }
        return modified.formatted(date: .numeric, time: .shortened)
    }
}
