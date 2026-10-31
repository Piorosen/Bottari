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
    /// The wait before retrying a request Drive asked to slow down; doubles each time.
    let retryDelay: Duration

    static let api = "https://www.googleapis.com/drive/v3"
    static let uploadAPI = "https://www.googleapis.com/upload/drive/v3"
    static let folderType = "application/vnd.google-apps.folder"
    static let fields = "id,name,mimeType,size,modifiedTime,sha256Checksum,parents"
    /// Bytes per ranged read and per upload chunk (a multiple of 256 KB, as Drive asks).
    static let chunkSize = 8 * 1024 * 1024

    public init(account: String, tokens: any AccessTokenSource, exportFormat: DriveExportFormat = .office, displayName: String? = nil, session: URLSession = .shared, retryDelay: Duration = .milliseconds(500)) {
        self.retryDelay = retryDelay
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

    /// Always asks Drive, so files added or removed elsewhere show up on refresh.
    public func list(_ path: RemotePath) async throws -> [FileItem] {
        let folder = try await resolve(path)
        guard folder.isFolder else { throw ProviderError.notADirectory(path) }
        return try await children(of: folder, at: path, fresh: true).map { $0.item(in: path) }.sorted(by: FileItem.finderOrder)
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
        let finished = try await uploadChunk(buffer, to: session, at: sent, total: sent + Int64(buffer.count), path: path)
        // The folder's listing takes the new file in, instead of being fetched
        // again for each of a thousand uploads into it.
        if let file = try? JSONDecoder.drive.decode(DriveFile.self, from: finished) {
            await index.put(file, in: parent.id)
        } else {
            await index.forget(children: parent.id)
        }
    }

    private func startUpload(_ method: String, _ url: String, metadata: [String: Any], path: RemotePath) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: metadata)
        let (_, _, headers) = try await requestWithHeaders(method, url, query: [("uploadType", "resumable"), ("supportsAllDrives", "true"), ("fields", Self.fields)], headers: ["Content-Type": "application/json; charset=UTF-8"], body: body, path: path)
        guard let location = headers["Location"] ?? headers["location"] else { throw ProviderError.io(String(localized: "Drive 업로드를 시작할 수 없습니다")) }
        return location
    }

    /// Drive answers the last chunk with the file it made.
    @discardableResult
    private func uploadChunk(_ data: Data, to session: String, at offset: Int64, total: Int64?, path: RemotePath) async throws -> Data {
        let range: String
        if data.isEmpty {
            range = "bytes */\(total ?? offset)"
        } else {
            range = "bytes \(offset)-\(offset + Int64(data.count) - 1)/\(total.map(String.init) ?? "*")"
        }
        return try await request("PUT", session, headers: ["Content-Range": range], body: data, allowing: [308], path: path).0
    }

    public func makeDirectory(_ path: RemotePath) async throws {
        try await makeFolder(named: path.name, at: path)
    }

    /// A folder at `path`, stored on Drive under `name`.
    private func makeFolder(named name: String, at path: RemotePath) async throws {
        guard let parentPath = path.parent else { throw ProviderError.alreadyExists(path) }
        let parent = try await resolve(parentPath)
        if try await children(of: parent, at: parentPath).contains(where: { $0.displayName == path.name }) {
            throw ProviderError.alreadyExists(path)
        }
        let body = try JSONSerialization.data(withJSONObject: ["name": name, "mimeType": Self.folderType, "parents": [parent.id]] as [String: Any])
        let (data, _) = try await request("POST", "\(Self.api)/files", query: [("supportsAllDrives", "true"), ("fields", Self.fields)], headers: ["Content-Type": "application/json"], body: body, path: path)
        if let folder = try? JSONDecoder.drive.decode(DriveFile.self, from: data) {
            await index.put(folder, in: parent.id)
        } else {
            await index.forget(children: parent.id)
        }
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
        let body = try JSONSerialization.data(withJSONObject: ["name": driveName(for: to.name, from: file, shownAs: from.name)])
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
        let name = driveName(for: to.name, from: file, shownAs: from.name)
        if file.isFolder {
            try await makeFolder(named: name, at: to)
            for child in try await children(of: file, at: from) {
                try await copy(child.item(in: from).path, to: to.appending(child.displayName))
            }
            return
        }
        let body = try JSONSerialization.data(withJSONObject: ["name": name, "parents": [newParent.id]] as [String: Any])
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

    /// The name to store on Drive for `target`, made from `file`, which shows
    /// as `shown` now. Unchanged, the file keeps its own name, including any
    /// character a path cannot hold; renamed, a converted document loses the
    /// export extension it only shows with.
    func driveName(for target: String, from file: DriveFile, shownAs shown: String) -> String {
        if target == shown { return file.name }
        if file.isGoogleDocument, let export = exportFormat.export(for: file.mimeType), target.hasSuffix("." + export.ext) {
            return String(target.dropLast(export.ext.count + 1))
        }
        return target
    }

    /// A folder's children with the names they show under (see `entries`),
    /// from a listing at most `DriveIndex.lifetime` old unless `fresh`.
    func children(of folder: DriveFile, at path: RemotePath, fresh: Bool = false) async throws -> [DriveEntry] {
        if !fresh, let cached = await index.files(in: folder.id) { return entries(cached) }
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
        await index.store(files, in: folder.id)
        return entries(files)
    }

    /// Names as they show in a path: converted documents get their export
    /// extension; "/", "." and ".." (which Drive allows in a name) become
    /// look-alikes; repeats get " (2)", " (3)", skipping names already taken.
    func entries(_ files: [DriveFile]) -> [DriveEntry] {
        let shown = files.map { file in
            var name = Self.pathSafe(file.name)
            if file.isGoogleDocument, let export = exportFormat.export(for: file.mimeType) {
                name += "." + export.ext
            }
            return name
        }
        var used = Set<String>()
        let taken = Set(shown)
        return zip(files, shown).map { file, name in
            var display = name
            if used.contains(display) {
                let ext = file.isFolder ? "" : RemotePath("/" + name).pathExtension
                let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
                var count = 2
                repeat {
                    display = ext.isEmpty ? "\(stem) (\(count))" : "\(stem) (\(count)).\(ext)"
                    count += 1
                } while used.contains(display) || taken.contains(display)
            }
            used.insert(display)
            return DriveEntry(file: file, displayName: display)
        }
    }

    /// A name that stays one path component.
    static func pathSafe(_ name: String) -> String {
        switch name {
        case "": "_"
        case ".": "\u{2024}"
        case "..": "\u{2025}"
        default: name.replacingOccurrences(of: "/", with: "\u{2215}")
        }
    }

    // MARK: - HTTP

    @discardableResult
    func request(_ method: String, _ url: String, query: [(String, String)] = [], headers: [String: String] = [:], body: Data? = nil, allowing: Set<Int> = [], path: RemotePath) async throws -> (Data, Int) {
        let (data, status, _) = try await requestWithHeaders(method, url, query: query, headers: headers, body: body, allowing: allowing, path: path)
        return (data, status)
    }

    /// Retries Drive's "slow down" answers (and server errors on reads) a few
    /// times, waiting longer each time, as Google asks clients to.
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
        var attempt = 0
        while true {
            request.setValue("Bearer \(try await tokens.accessToken())", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ProviderError.io(String(localized: "Drive 응답이 올바르지 않습니다")) }
            let status = http.statusCode
            let fields = http.allHeaderFields.reduce(into: [String: String]()) { $0["\($1.key)"] = "\($1.value)" }
            if (200..<300).contains(status) || allowing.contains(status) { return (data, status, fields) }
            let detail = (try? JSONDecoder().decode(DriveError.self, from: data))?.error
            let reason = detail?.errors?.first?.reason ?? ""
            let slowDown = status == 429 || (status == 403 && Self.rateLimitReasons.contains(reason))
            if slowDown || (method == "GET" && (500...504).contains(status)), attempt < Self.retries {
                try await Task.sleep(for: retryDelay * (1 << attempt) + .milliseconds(Int.random(in: 0..<50)))
                attempt += 1
                continue
            }
            let message = detail?.message ?? HTTPURLResponse.localizedString(forStatusCode: status)
            switch status {
            case 404: throw ProviderError.notFound(path)
            case 401: throw ProviderError.permissionDenied(path)
            // A 403 is also a full drive, an export too big, or a limit that
            // did not lift: say which.
            case 403 where reason.isEmpty || Self.permissionReasons.contains(reason): throw ProviderError.permissionDenied(path)
            default: throw ProviderError.io(String(localized: "Drive 오류 \(status): \(message)"))
            }
        }
    }

    static let rateLimitReasons: Set<String> = ["rateLimitExceeded", "userRateLimitExceeded"]
    static let permissionReasons: Set<String> = ["forbidden", "insufficientFilePermissions", "insufficientPermissions", "appNotAuthorizedToFile", "domainPolicy"]
    static let retries = 5
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

    /// The item as it shows in `folder`, built each time so a renamed or
    /// moved folder's children carry its current path.
    func item(in folder: RemotePath) -> FileItem {
        file.item(at: folder.appending(displayName))
    }
}

private struct FileList: Decodable {
    let files: [DriveFile]
    let nextPageToken: String?
}

private struct DriveError: Decodable {
    struct Reason: Decodable { let reason: String? }
    struct Detail: Decodable {
        let message: String
        let errors: [Reason]?
    }
    let error: Detail
}

/// Folder listings by folder ID, so a path is not looked up folder by folder
/// on every request. They are kept briefly, since Drive changes from elsewhere.
actor DriveIndex {
    static let lifetime: Duration = .seconds(30)
    private var listings: [String: (files: [DriveFile], at: ContinuousClock.Instant)] = [:]

    func files(in id: String) -> [DriveFile]? {
        guard let listing = listings[id], .now - listing.at < Self.lifetime else { return nil }
        return listing.files
    }

    func store(_ files: [DriveFile], in id: String) { listings[id] = (files, .now) }

    /// Adds or updates one file in a folder's listing, if it is kept.
    func put(_ file: DriveFile, in id: String) {
        guard var listing = listings[id] else { return }
        if let index = listing.files.firstIndex(where: { $0.id == file.id }) {
            listing.files[index] = file
        } else {
            listing.files.append(file)
        }
        listings[id] = listing
    }

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
