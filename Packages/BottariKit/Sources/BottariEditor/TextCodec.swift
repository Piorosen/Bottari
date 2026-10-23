import Foundation

/// How a text file was stored, so saving writes it back the same way.
public struct TextFormat: Equatable, Sendable {
    public enum Encoding: Sendable {
        case utf8
        case utf8WithBOM
        case utf16LittleEndian
        case utf16BigEndian
        /// CP949, which older Korean servers and Windows files still use.
        case eucKR
    }

    public enum LineEnding: String, Sendable {
        case lf = "LF"
        case crlf = "CRLF"
        case cr = "CR"

        var characters: String {
            switch self {
            case .lf: "\n"
            case .crlf: "\r\n"
            case .cr: "\r"
            }
        }
    }

    public var encoding: Encoding
    public var lineEnding: LineEnding

    public init(encoding: Encoding = .utf8, lineEnding: LineEnding = .lf) {
        self.encoding = encoding
        self.lineEnding = lineEnding
    }

    /// "UTF-8 LF", as the editor's status bar shows it.
    public var label: String {
        let name = switch encoding {
        case .utf8: "UTF-8"
        case .utf8WithBOM: "UTF-8 BOM"
        case .utf16LittleEndian: "UTF-16 LE"
        case .utf16BigEndian: "UTF-16 BE"
        case .eucKR: "EUC-KR"
        }
        return "\(name) \(lineEnding.rawValue)"
    }
}

/// Turns file bytes into editable text (with `\n` line endings) and back.
public enum TextCodec {
    private static let eucKR = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))

    /// The text and how it was stored, or nil when the bytes are not text.
    public static func decode(_ data: Data) -> (text: String, format: TextFormat)? {
        let bytes = [UInt8](data.prefix(3))
        let decoded: (String, TextFormat.Encoding)?
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            decoded = String(data: data.dropFirst(3), encoding: .utf8).map { ($0, .utf8WithBOM) }
        } else if bytes.starts(with: [0xFF, 0xFE]) {
            decoded = String(data: data.dropFirst(2), encoding: .utf16LittleEndian).map { ($0, .utf16LittleEndian) }
        } else if bytes.starts(with: [0xFE, 0xFF]) {
            decoded = String(data: data.dropFirst(2), encoding: .utf16BigEndian).map { ($0, .utf16BigEndian) }
        } else if data.prefix(8192).contains(0) {
            // NUL bytes without a UTF-16 mark: a binary file.
            decoded = nil
        } else if let text = String(data: data, encoding: .utf8) {
            decoded = (text, .utf8)
        } else {
            decoded = String(data: data, encoding: eucKR).map { ($0, .eucKR) }
        }
        guard let (raw, encoding) = decoded else { return nil }
        let lineEnding = lineEnding(of: raw)
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return (text, TextFormat(encoding: encoding, lineEnding: lineEnding))
    }

    /// The bytes to save, or nil when the text has characters the encoding cannot hold.
    public static func encode(_ text: String, as format: TextFormat) -> Data? {
        let lines = format.lineEnding == .lf ? text : text.replacingOccurrences(of: "\n", with: format.lineEnding.characters)
        switch format.encoding {
        case .utf8:
            return Data(lines.utf8)
        case .utf8WithBOM:
            return Data([0xEF, 0xBB, 0xBF]) + Data(lines.utf8)
        case .utf16LittleEndian:
            return lines.data(using: .utf16LittleEndian).map { Data([0xFF, 0xFE]) + $0 }
        case .utf16BigEndian:
            return lines.data(using: .utf16BigEndian).map { Data([0xFE, 0xFF]) + $0 }
        case .eucKR:
            return lines.data(using: eucKR, allowLossyConversion: false)
        }
    }

    /// The most common line ending, LF when there are none.
    private static func lineEnding(of text: String) -> TextFormat.LineEnding {
        let units = Array(text.utf16)
        var crlf = 0, lf = 0, cr = 0
        var index = 0
        while index < units.count {
            switch units[index] {
            case 13 where index + 1 < units.count && units[index + 1] == 10:
                crlf += 1
                index += 1
            case 13:
                cr += 1
            case 10:
                lf += 1
            default:
                break
            }
            index += 1
        }
        if crlf > lf && crlf >= cr { return .crlf }
        if cr > lf && cr > crlf { return .cr }
        return .lf
    }
}
