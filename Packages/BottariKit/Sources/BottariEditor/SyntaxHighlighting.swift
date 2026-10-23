import AppKit
import Highlightr

/// highlight.js language names for file names, and text storage that colours
/// code as it is edited (only the changed paragraphs are highlighted again).
public enum SyntaxHighlighting {
    public static func language(forFileNamed name: String) -> String? {
        let lower = name.lowercased()
        switch lower {
        case "dockerfile": return "dockerfile"
        case "makefile", "gnumakefile": return "makefile"
        case "nginx.conf": return "nginx"
        case ".bashrc", ".zshrc", ".profile", ".bash_profile": return "bash"
        default: break
        }
        if lower.hasPrefix(".env") { return "bash" }
        let ext = (lower as NSString).pathExtension
        if lower.contains("nginx"), ext == "conf" { return "nginx" }
        return extensions[ext]
    }

    private static let extensions: [String: String] = [
        "swift": "swift", "py": "python", "rb": "ruby", "php": "php", "go": "go", "rs": "rust",
        "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "javascript",
        "ts": "typescript", "tsx": "typescript", "json": "json", "jsonc": "json",
        "yml": "yaml", "yaml": "yaml", "toml": "ini", "ini": "ini", "cfg": "ini", "conf": "ini", "service": "ini",
        "xml": "xml", "plist": "xml", "html": "xml", "htm": "xml", "svg": "xml", "vue": "xml",
        "css": "css", "scss": "scss", "less": "less", "md": "markdown", "markdown": "markdown",
        "sh": "bash", "bash": "bash", "zsh": "bash", "fish": "bash",
        "c": "c", "h": "c", "cc": "cpp", "cpp": "cpp", "hpp": "cpp", "m": "objectivec", "mm": "objectivec",
        "java": "java", "kt": "kotlin", "kts": "kotlin", "gradle": "gradle", "dart": "dart", "lua": "lua",
        "sql": "sql", "diff": "diff", "patch": "diff", "properties": "properties", "pl": "perl",
        "cs": "csharp", "ex": "elixir", "exs": "elixir", "erl": "erlang", "hs": "haskell", "scala": "scala",
        "graphql": "graphql", "proto": "protobuf", "tf": "ini", "cmake": "cmake", "ps1": "powershell",
    ]

    /// Text storage for an NSTextView that highlights `language` in a theme
    /// matching light or dark mode. Without a language it stays plain.
    public static func makeStorage(language: String?, dark: Bool, font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)) -> NSTextStorage {
        let storage = CodeAttributedString()
        storage.language = language
        apply(dark: dark, font: font, to: storage)
        return storage
    }

    /// Switches the theme, e.g. when the system appearance or the font changes.
    public static func apply(dark: Bool, font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular), to storage: NSTextStorage) {
        guard let storage = storage as? CodeAttributedString else { return }
        storage.highlightr.setTheme(to: dark ? "atom-one-dark" : "xcode")
        storage.highlightr.theme.setCodeFont(font)
        storage.highlightr.theme.themeBackgroundColor = .clear
        // Re-colour what is already there.
        let language = storage.language
        storage.language = language
    }
}
