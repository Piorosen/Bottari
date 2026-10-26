import Foundation

/// Rules for names the user types, the same on every provider.
public enum FileNames {
    /// Why `name` cannot be used for a file or folder, or nil if it can.
    public static func problem(with name: String) -> String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "이름을 입력하십시오." }
        if name.contains("/") { return "이름에 /를 사용할 수 없습니다." }
        if name == "." || name == ".." { return "사용할 수 없는 이름입니다." }
        if name.utf8.count > 255 { return "이름이 너무 깁니다." }
        return nil
    }

    /// `name` itself when nothing in `taken` uses it, otherwise the first free "name 2", "name 3" ….
    public static func available(_ name: String, isDirectory: Bool, taken: Set<String>) -> String {
        taken.contains(name) ? RemotePath.freeName(for: name, isDirectory: isDirectory, taken: taken) : name
    }
}

extension RemotePath {
    /// `name` with " 2", " 3" … added before the extension until it is not in
    /// `taken`, the way Finder's "keep both" names things.
    public static func freeName(for name: String, isDirectory: Bool, taken: Set<String>) -> String {
        let ext = isDirectory ? "" : RemotePath("/" + name).pathExtension
        let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        var number = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            if !taken.contains(candidate) { return candidate }
            number += 1
        }
    }
}
