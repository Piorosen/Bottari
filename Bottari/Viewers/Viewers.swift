import BottariCore
import BottariSFTP
import Foundation
import UniformTypeIdentifiers

/// What a file opens in when activated.
enum FileKind {
    case image, text, video, other

    init(_ item: FileItem) {
        guard !item.isDirectory else {
            self = .other
            return
        }
        let name = item.name.lowercased()
        if Self.textNames.contains(name) || name.hasPrefix(".env") {
            self = .text
            return
        }
        let ext = item.path.pathExtension.lowercased()
        if Self.textExtensions.contains(ext) {
            self = .text
            return
        }
        guard let type = UTType(filenameExtension: ext) else {
            self = .other
            return
        }
        if type.conforms(to: .image) {
            self = .image
        } else if type.conforms(to: .audiovisualContent) {
            self = .video
        } else if type.conforms(to: .text) || type.conforms(to: .sourceCode) {
            self = .text
        } else {
            self = .other
        }
    }

    private static let textNames: Set<String> = [
        "dockerfile", "makefile", "procfile", "gemfile", "rakefile", "vagrantfile", "jenkinsfile",
        "readme", "license", "authorized_keys", "known_hosts", "config", "hosts", "crontab", ".gitignore", ".bashrc", ".zshrc", ".profile",
    ]

    /// Configuration and code that UTType does not know as text.
    private static let textExtensions: Set<String> = [
        "conf", "cfg", "ini", "env", "toml", "yml", "yaml", "json", "jsonc", "xml", "plist", "properties",
        "service", "timer", "socket", "log", "lock", "sql", "graphql", "proto", "tf", "hcl", "nix",
        "vue", "svelte", "tsx", "jsx", "ts", "mjs", "cjs", "go", "rs", "kt", "kts", "gradle", "dart", "lua",
        "sh", "bash", "zsh", "fish", "ps1", "bat", "cmake", "mk", "md", "rst", "adoc", "csv", "tsv",
    ]
}

/// A file opened in its own window, with what the window needs to reach it.
/// Windows get only an ID (window values must be Codable); the rest waits here.
struct ViewerContext {
    let provider: any FileProvider
    let site: SavedSite?
    /// The file to show first.
    let item: FileItem
    /// Its neighbours, for stepping through a folder of images.
    let siblings: [FileItem]
}

enum Viewers {
    private static var contexts: [UUID: ViewerContext] = [:]
    /// Editors in open windows, so quitting can ask about unsaved changes.
    private static var editors: [UUID: EditorModel] = [:]

    static func register(_ context: ViewerContext) -> UUID {
        let id = UUID()
        contexts[id] = context
        return id
    }

    static func context(_ id: UUID) -> ViewerContext? {
        contexts[id]
    }

    static func close(_ id: UUID) {
        contexts[id] = nil
        editors[id] = nil
    }

    static func track(_ editor: EditorModel, in id: UUID) {
        editors[id] = editor
    }

    static var unsavedEditors: [EditorModel] {
        editors.values.filter(\.isDirty)
    }
}

/// Opens a viewer window; set by the main window, which can reach `openWindow`.
struct ViewerOpener {
    let open: (_ windowID: String, _ context: UUID) -> Void
}
