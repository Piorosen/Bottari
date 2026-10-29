import BottariCore
import Foundation

/// Hands out a valid OAuth access token, refreshing it when needed.
public protocol AccessTokenSource: Sendable {
    func accessToken() async throws -> String
}

/// How Google Docs, Sheets and Slides come down, since they are not files.
public enum DriveExportFormat: String, Codable, CaseIterable, Sendable {
    case office, pdf, openDocument

    func export(for mimeType: String) -> (mime: String, ext: String)? {
        let kind = mimeType.replacingOccurrences(of: "application/vnd.google-apps.", with: "")
        switch (self, kind) {
        case (.pdf, "document"), (.pdf, "spreadsheet"), (.pdf, "presentation"), (_, "drawing"):
            return kind == "drawing" && self != .pdf ? ("image/png", "png") : ("application/pdf", "pdf")
        case (.office, "document"): return ("application/vnd.openxmlformats-officedocument.wordprocessingml.document", "docx")
        case (.office, "spreadsheet"): return ("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "xlsx")
        case (.office, "presentation"): return ("application/vnd.openxmlformats-officedocument.presentationml.presentation", "pptx")
        case (.openDocument, "document"): return ("application/vnd.oasis.opendocument.text", "odt")
        case (.openDocument, "spreadsheet"): return ("application/x-vnd.oasis.opendocument.spreadsheet", "ods")
        case (.openDocument, "presentation"): return ("application/vnd.oasis.opendocument.presentation", "odp")
        default: return nil
        }
    }
}

/// Google Drive as a file system. Drive finds files by ID and lets a folder
/// hold several files of the same name; paths are mapped onto IDs folder by
/// folder, and repeated names show as "name (2)", "name (3)".
public struct GoogleDriveProvider: FileProvider {
    public let displayName: String
    public let account: String
    public let exportFormat: DriveExportFormat
    let tokens: any AccessTokenSource
    let session: URLSession
    let index = DriveIndex()

    static let api = "https://www.googleapis.com/drive/v3"
    static let uploadAPI = "https://www.googleapis.com/upload/drive/v3"
    static let folderType = "application/vnd.google-apps.folder"
    static let fields = "id,name,mimeType,size,modifiedTime,sha256Checksum,parents"
    /// Bytes per ranged read and per upload chunk (a multiple of 256 KB, as Drive asks).
    static let chunkSize = 8 * 1024 * 1024

    public init(account: String, tokens: any AccessTokenSource, exportFormat: DriveExportFormat = .office, displayName: String? = nil, session: URLSession = .shared) {
        self.account = account
        self.tokens = tokens
        self.exportFormat = exportFormat
        self.displayName = displayName ?? "Google Drive"
        self.session = session
    }

    public var locationID: String { "gdrive://\(account)" }
    public var capabilities: ProviderCapabilities { [.rangeRead, .serverSideCopy, .trash, .checksum, .modificationTime] }
    public var home: RemotePath { .root }

    // MARK: - Reading

    public func list(_ path: RemotePath) async throws -> [FileItem] {
        let folder = try await resolve(path)
        guard folder.isFolder else { throw ProviderError.notADirectory(path) }
        return try await children(of: folder, at: path).map { $0.item }.sorted(by: FileItem.finderOrder)
    }

    public func stat(_ path: RemotePath) async throws -> FileItem {
        try await resolve(path).item(at: path)
    }

    public func read(_ path: RemotePath, range: Range<Int64>?) -> AsyncThrowingStream<Data, any Error> {
        let reader = RangeReader(start: range?.lowerBound ?? 0, end: range?.upperBound)
        let exported = ExportOnce()
        return AsyncThrowingStream(unfolding: { [self] in
            let file = try await resolve(path)
            guard !file.isFolder else { throw ProviderError.isADirectory(path) }
            if let export = exportFormat.export(for: file.mimeType), file.isGoogleDocument {
                // Converted documents come whole; there is no byte range to ask for.
                guard exported.claim() else { return nil }
                return try await request("GET", "\(Self.api)/files/\(file.id)/export", query: [("mimeType", export.mime)], path: path).0
            }
            guard let (from, to) = reader.nextRange(Self.chunkSize) else { return nil }
            let (data, status) = try await request("GET", "\(Self.api)/files/\(file.id)", query: [("alt", "media")], headers: ["Range": "bytes=\(from)-\(to)"], allowing: [416], path: path)
            guard status != 416, !data.isEmpty else {
                reader.finish()
                return nil
            }
            reader.advance(by: data.count, requested: Int(to - from + 1))
            return data
        })
    }

    public func checksum(_ path: RemotePath) async throws -> String {
        guard let sha = try await resolve(path).sha256 else { throw ProviderError.unsupported(String(localized: "체크섬")) }
        return sha.lowercased()
    }

    // MARK: - Writing

    /// A resumable upload, so a big file goes up in pieces; an existing file
    /// gets new content (a new revision) instead of a twin of the same name.
    public func write(_ path: RemotePath, from data: AsyncThrowingStream<Data, any Error>) async throws {
        guard let parentPath = path.parent else { throw ProviderError.permissionDenied(path) }
        let parent = try await resolve(parentPath)
        let existing = try await children(of: parent, at: parentPath).first { $0.displayName == path.name }
        if existing?.file.isFolder == true { throw ProviderError.isADirectory(path) }
        let session: String
        if let existing {
            session = try await startUpload("PATCH", "\(Self.uploadAPI)/files/\(existing.file.id)", metadata: [:], path: path)
        } else {
            session = try await startUpload("POST", "\(Self.uploadAPI)/files", metadata: ["name": path.name, "parents": [parent.id]], path: path)
        }
        var buffer = Data()
        var sent: Int64 = 0
        for try await chunk in data {
            buffer.append(chunk)
            while buffer.count > Self.chunkSize {
                let piece = buffer.prefix(Self.chunkSize)
                try await uploadChunk(Data(piece), to: session, at: sent, total: nil, path: path)
                sent += Int64(piece.count)
                buffer.removeFirst(piece.count)
            }
        }
        try await uploadChunk(buffer, to: session, at: sent, total: sent + Int64(buffer.count), path: path)
        await index.forget(children: parent.id)
    }

    private func startUpload(_ method: String, _ url: String, metadata: [String: Any], path: RemotePath) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: metadata)
        let (_, _, headers) = try await requestWithHeaders(method, url, query: [("uploadType", "resumable"), ("supportsAllDrives", "true")], headers: ["Content-Type": "application/json; charset=UTF-8"], body: body, path: path)
        guard let location = headers["Location"] ?? headers["location"] else { throw ProviderError.io(String(localized: "Drive 업로드를 시작할 수 없습니다")) }
        return location
    }

    private func uploadChunk(_ data: Data, to session: String, at offset: Int64, total: Int64?, path: RemotePath) async throws {
        let range: String
        if data.isEmpty {
            range = "bytes */\(total ?? offset)"
        } else {
            range = "bytes \(offset)-\(offset + Int64(data.count) - 1)/\(total.map(String.init) ?? "*")"
        }
        _ = try await request("PUT", session, headers: ["Content-Range": range], body: data, allowing: [308], path: path)
    }

    public func makeDirectory(_ path: RemotePath) async throws {
        guard let parentPath = path.parent else { throw ProviderError.alreadyExists(path) }
        let parent = try await resolve(parentPath)
        if try await children(of: parent, at: parentPath).contains(where: { $0.displayName == path.name }) {
            throw ProviderError.alreadyExists(path)
        }
        let body = try JSONSerialization.data(withJSONObject: ["name": path.name, "mimeType": Self.folderType, "parents": [parent.id]] as [String: Any])
        _ = try await request("POST", "\(Self.api)/files", query: [("supportsAllDrives", "true")], headers: ["Content-Type": "application/json"], body: body, path: path)
        await index.forget(children: parent.id)
    }

    public func move(_ from: RemotePath, to: RemotePath) async throws {
        let file = try await resolve(from)
        guard let oldParent = from.parent, let newParentPath = to.parent else { throw ProviderError.permissionDenied(from) }
        let newParent = try await resolve(newParentPath)
        if try await children(of: newParent, at: newParentPath).contains(where: { $0.displayName == to.name }) {
            throw ProviderError.alreadyExists(to)
        }
        let previous = try await resolve(oldParent)
        var query = [("supportsAllDrives", "true")]
        if previous.id != newParent.id {
            query += [("addParents", newParent.id), ("removeParents", previous.id)]
        }
        let body = try JSONSerialization.data(withJSONObject: ["name": to.name])
        _ = try await request("PATCH", "\(Self.api)/files/\(file.id)", query: query, headers: ["Content-Type": "application/json"], body: body, path: from)
        await index.forget(children: previous.id)
        await index.forget(children: newParent.id)
    }

    /// Drive copies files itself; folders are copied file by file.
    public func copy(_ from: RemotePath, to: RemotePath) async throws {
        let file = try await resolve(from)
        guard let newParentPath = to.parent else { throw ProviderError.permissionDenied(to) }
        let newParent = try await resolve(newParentPath)
        if try await children(of: newParent, at: newParentPath).contains(where: { $0.displayName == to.name }) {
            throw ProviderError.alreadyExists(to)
        }
        if file.isFolder {
            try await makeDirectory(to)
            for child in try await children(of: file, at: from) {
                try await copy(from.appending(child.displayName), to: to.appending(child.displayName))
            }
            return
        }
        let body = try JSONSerialization.data(withJSONObject: ["name": to.name, "parents": [newParent.id]] as [String: Any])
        _ = try await request("POST", "\(Self.api)/files/\(file.id)/copy", query: [("supportsAllDrives", "true")], headers: ["Content-Type": "application/json"], body: body, path: from)
        await index.forget(children: newParent.id)
    }

    public func delete(_ path: RemotePath) async throws {
        let file = try await resolve(path)
        _ = try await request("DELETE", "\(Self.api)/files/\(file.id)", query: [("supportsAllDrives", "true")], path: path)
        if let parent = path.parent { await index.forget(children: try await resolve(parent).id) }
    }

    public func trash(_ path: RemotePath) async throws {
        try await patchMetadata(path, ["trashed": true])
    }

    public func setModified(_ date: Date, at path: RemotePath) async throws {
        try await patchMetadata(path, ["modifiedTime": date.formatted(.iso8601)])
    }

    private func patchMetadata(_ path: RemotePath, _ fields: [String: Any]) async throws {
        let file = try await resolve(path)
        let body = try JSONSerialization.data(withJSONObject: fields)
        _ = try await request("PATCH", "\(Self.api)/files/\(file.id)", query: [("supportsAllDrives", "true")], headers: ["Content-Type": "application/json"], body: body, path: path)
        if let parent = path.parent { await index.forget(children: try await resolve(parent).id) }
    }

    // MARK: - Paths and IDs

    /// The file at `path`, found folder by folder from the root.
    func resolve(_ path: RemotePath) async throws -> DriveFile {
        if path.isRoot { return DriveFile.root }
        guard let parentPath = path.parent else { return DriveFile.root }
        let parent = try await resolve(parentPath)
        guard parent.isFolder else { throw ProviderError.notADirectory(parentPath) }
        guard let match = try await children(of: parent, at: parentPath).first(where: { $0.displayName == path.name }) else {
            throw ProviderError.notFound(path)
        }
        return match.file
    }

    /// A folder's children with the names they show under: converted
    /// documents get their export extension, repeats get " (2)", " (3)".
    func children(of folder: DriveFile, at path: RemotePath) async throws -> [DriveEntry] {
        if let cached = await index.children(of: folder.id) { return cached }
        var files: [DriveFile] = []
        var token: String?
        repeat {
            var query = [
                ("q", "'\(folder.id)' in parents and trashed = false"),
                ("fields", "nextPageToken,files(\(Self.fields))"),
                ("pageSize", "1000"),
                ("orderBy", "name,createdTime"),
                ("supportsAllDrives", "true"),
                ("includeItemsFromAllDrives", "true"),
            ]
            if let token { query.append(("pageToken", token)) }
            let (data, _) = try await request("GET", "\(Self.api)/files", query: query, path: path)
            let page = try JSONDecoder.drive.decode(FileList.self, from: data)
            files += page.files.filter { $0.mimeType != "application/vnd.google-apps.shortcut" }
            token = page.nextPageToken
        } while token != nil
        var seen: [String: Int] = [:]
        let entries = files.map { file in
            var name = file.name
            if file.isGoogleDocument, let export = exportFormat.export(for: file.mimeType) {
                name += "." + export.ext
            }
            seen[name, default: 0] += 1
            if let count = seen[name], count > 1 {
                let ext = file.isFolder ? "" : RemotePath("/" + name).pathExtension
                name = ext.isEmpty ? "\(name) (\(count))" : "\(name.dropLast(ext.count + 1)) (\(count)).\(ext)"
            }
            return DriveEntry(file: file, displayName: name, item: file.item(at: path.appending(name)))
        }
        await index.store(entries, for: folder.id)
        return entries
    }

    // MARK: - HTTP

    @discardableResult
    func request(_ method: String, _ url: String, query: [(String, String)] = [], headers: [String: String] = [:], body: Data? = nil, allowing: Set<Int> = [], path: RemotePath) async throws -> (Data, Int) {
        let (data, status, _) = try await requestWithHeaders(method, url, query: query, headers: headers, body: body, allowing: allowing, path: path)
        return (data, status)
    }

    func requestWithHeaders(_ method: String, _ url: String, query: [(String, String)] = [], headers: [String: String] = [:], body: Data? = nil, allowing: Set<Int> = [], path: RemotePath) async throws -> (Data, Int, [String: String]) {
        var components = URLComponents(string: url)!
        if !query.isEmpty {
            components.queryItems = (components.queryItems ?? []) + query.map { URLQueryItem(name: $0.0, value: $0.1) }
            // "+" means a space to Google; keep a literal plus as %2B.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.httpBody = body
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("Bearer \(try await tokens.accessToken())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.io(String(localized: "Drive 응답이 올바르지 않습니다")) }
        let fields = http.allHeaderFields.reduce(into: [String: String]()) { $0["\($1.key)"] = "\($1.value)" }
        if (200..<300).contains(http.statusCode) || allowing.contains(http.statusCode) { return (data, http.statusCode, fields) }
        let message = (try? JSONDecoder().decode(DriveError.self, from: data))?.error.message ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
        switch http.statusCode {
        case 404: throw ProviderError.notFound(path)
        case 401, 403: throw ProviderError.permissionDenied(path)
        default: throw ProviderError.io(String(localized: "Drive 오류 \(http.statusCode): \(message)"))
        }
    }
}

struct DriveFile: Decodable, Sendable, Equatable {
    let id: String
    let name: String
    let mimeType: String
    let size: String?
    let modifiedTime: Date?
    let sha256Checksum: String?

    static let root = DriveFile(id: "root", name: "", mimeType: GoogleDriveProvider.folderType, size: nil, modifiedTime: nil, sha256Checksum: nil)

    var isFolder: Bool { mimeType == GoogleDriveProvider.folderType }
    var isGoogleDocument: Bool { mimeType.hasPrefix("application/vnd.google-apps.") && !isFolder }
    var sha256: String? { sha256Checksum }

    func item(at path: RemotePath) -> FileItem {
        FileItem(path: path, kind: isFolder ? .directory : .file, size: size.flatMap { Int64($0) }, modified: modifiedTime)
    }
}

struct DriveEntry: Sendable {
    let file: DriveFile
    let displayName: String
    let item: FileItem
}

private struct FileList: Decodable {
    let files: [DriveFile]
    let nextPageToken: String?
}

private struct DriveError: Decodable {
    struct Detail: Decodable { let message: String }
    let error: Detail
}

/// Folder listings by folder ID, so a path is not looked up again and again.
actor DriveIndex {
    private var listings: [String: [DriveEntry]] = [:]

    func children(of id: String) -> [DriveEntry]? { listings[id] }
    func store(_ entries: [DriveEntry], for id: String) { listings[id] = entries }
    func forget(children id: String) { listings[id] = nil }
}

/// A converted document is fetched once per stream.
private final class ExportOnce: @unchecked Sendable {
    private var done = false
    func claim() -> Bool {
        defer { done = true }
        return !done
    }
}

extension JSONDecoder {
    static let drive: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text)) ?? (try? Date.ISO8601FormatStyle().parse(text)) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: text))
        }
        return decoder
    }()
}
