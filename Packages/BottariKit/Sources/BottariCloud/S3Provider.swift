import BottariCore
import Foundation

/// Where an S3 bucket lives and how to reach it.
public struct S3Configuration: Codable, Hashable, Sendable {
    public var bucket: String
    public var region: String
    /// Empty for AWS; e.g. `https://<account>.r2.cloudflarestorage.com` or a MinIO address.
    public var endpoint: String
    public var accessKey: String
    /// Bucket in the path (`host/bucket/key`) instead of the host name; MinIO wants this.
    public var usesPathStyle: Bool

    public init(bucket: String, region: String = "us-east-1", endpoint: String = "", accessKey: String, usesPathStyle: Bool = false) {
        self.bucket = bucket
        self.region = region
        self.endpoint = endpoint
        self.accessKey = accessKey
        self.usesPathStyle = usesPathStyle
    }

    /// The URL of `key` (empty for the bucket itself), with `query` already encoded.
    func url(for key: String, query: [(String, String)] = []) -> URL {
        let encodedKey = AWSSigner.encode(key, keepingSlashes: true)
        var base: String
        if endpoint.isEmpty {
            base = usesPathStyle ? "https://s3.\(region).amazonaws.com/\(bucket)" : "https://\(bucket).s3.\(region).amazonaws.com"
        } else {
            let trimmed = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
            if usesPathStyle {
                base = "\(trimmed)/\(bucket)"
            } else {
                var components = URLComponents(string: trimmed)
                let host = components?.host ?? ""
                components?.host = "\(bucket).\(host)"
                base = components?.string ?? trimmed
            }
        }
        var text = base + "/" + encodedKey
        if !query.isEmpty {
            text += "?" + query.map { "\(AWSSigner.encode($0.0))=\(AWSSigner.encode($0.1))" }.joined(separator: "&")
        }
        return URL(string: text)!
    }
}

/// A bucket as a file system: keys are paths, "/"-separated prefixes are folders.
public struct S3Provider: FileProvider {
    public let configuration: S3Configuration
    public let displayName: String
    let signer: AWSSigner
    let session: URLSession
    /// Objects bigger than this are copied in parts; S3 copies at most 5 GiB in one request.
    let largestSingleCopy: Int64

    /// Bytes per ranged read and per uploaded part (S3 parts must be at least 5 MB).
    static let chunkSize = 8 * 1024 * 1024
    /// Bytes per part when copying a big object in parts.
    static let copyPartSize: Int64 = 512 * 1024 * 1024

    public init(configuration: S3Configuration, secretKey: String, displayName: String? = nil, session: URLSession = .shared, largestSingleCopy: Int64 = 5 * 1024 * 1024 * 1024) {
        self.configuration = configuration
        self.displayName = displayName ?? configuration.bucket
        self.signer = AWSSigner(accessKey: configuration.accessKey, secretKey: secretKey, region: configuration.region)
        self.session = session
        self.largestSingleCopy = largestSingleCopy
    }

    /// The size of upload part `number` (from 1). An upload may have 10,000
    /// parts and its size is not known up front, so parts grow as it goes on:
    /// 8 MiB up to 8 GiB, 64 MiB up to 264 GiB, then 256 MiB, about 1.5 TiB in all.
    static func partSize(_ number: Int) -> Int {
        switch number {
        case ...1000: chunkSize
        case ...5000: 8 * chunkSize
        default: 32 * chunkSize
        }
    }

    public var locationID: String { "s3://\(configuration.bucket)@\(configuration.url(for: "").host() ?? "")" }
    public var capabilities: ProviderCapabilities { [.rangeRead, .serverSideCopy] }
    public var home: RemotePath { .root }

    static func key(_ path: RemotePath) -> String { path.components.joined(separator: "/") }
    static func prefix(_ path: RemotePath) -> String { path.isRoot ? "" : key(path) + "/" }

    // MARK: - Reading

    /// Keys whose name here is empty, "." or ".." (from "a//b" or "a/../b")
    /// cannot be a path and are left out; they would read as this folder or
    /// its parent, and walking them would never end.
    public func list(_ path: RemotePath) async throws -> [FileItem] {
        let prefix = Self.prefix(path)
        let page = try await listAll(prefix: prefix, delimiter: "/")
        func name(_ key: String) -> String? {
            var rest = key.dropFirst(prefix.count)
            if rest.hasSuffix("/") { rest = rest.dropLast() }
            return ["", ".", ".."].contains(rest) || rest.contains("/") ? nil : String(rest)
        }
        var items = page.folders.compactMap { folder in
            name(folder).map { FileItem(path: path.appending($0), kind: .directory) }
        }
        items += page.objects.filter { $0.key != prefix }.compactMap { object in
            name(object.key).map { FileItem(path: path.appending($0), kind: .file, size: object.size, modified: object.modified) }
        }
        return items.sorted(by: FileItem.finderOrder)
    }

    public func stat(_ path: RemotePath) async throws -> FileItem {
        if path.isRoot { return FileItem(path: path, kind: .directory) }
        var request = URLRequest(url: configuration.url(for: Self.key(path)))
        request.httpMethod = "HEAD"
        let (_, response) = try await send(&request, path: path, allowing: [404])
        if response.statusCode == 200 {
            return FileItem(
                path: path,
                kind: .file,
                size: Int64(response.value(forHTTPHeaderField: "Content-Length") ?? ""),
                modified: response.value(forHTTPHeaderField: "Last-Modified").flatMap(Self.httpDate.date)
            )
        }
        // No object: a folder if anything lies below it.
        let below = try await listAll(prefix: Self.prefix(path), delimiter: "/", maxPages: 1)
        guard !below.objects.isEmpty || !below.folders.isEmpty else { throw ProviderError.notFound(path) }
        return FileItem(path: path, kind: .directory)
    }

    public func read(_ path: RemotePath, range: Range<Int64>?) -> AsyncThrowingStream<Data, any Error> {
        let reader = RangeReader(start: range?.lowerBound ?? 0, end: range?.upperBound)
        return AsyncThrowingStream(unfolding: { [self] in
            guard let (from, to) = reader.nextRange(Self.chunkSize) else { return nil }
            var request = URLRequest(url: configuration.url(for: Self.key(path)))
            request.setValue("bytes=\(from)-\(to)", forHTTPHeaderField: "Range")
            let (data, response) = try await send(&request, path: path, allowing: [416])
            // 416: asked past the end, which happens when the size was unknown.
            guard response.statusCode != 416, !data.isEmpty else {
                reader.finish()
                return nil
            }
            reader.advance(by: data.count, requested: Int(to - from + 1))
            return data
        })
    }

    // MARK: - Writing

    /// Small files go up in one request; bigger ones as a multipart upload,
    /// which only appears once it is complete.
    public func write(_ path: RemotePath, from data: AsyncThrowingStream<Data, any Error>) async throws {
        let key = Self.key(path)
        var buffer = Data()
        var uploadID: String?
        var parts: [(Int, String)] = []
        do {
            for try await chunk in data {
                buffer.append(chunk)
                while buffer.count >= Self.partSize(parts.count + 1) {
                    if uploadID == nil { uploadID = try await startMultipart(key, path: path) }
                    let part = buffer.prefix(Self.partSize(parts.count + 1))
                    buffer.removeFirst(part.count)
                    parts.append((parts.count + 1, try await uploadPart(key, uploadID: uploadID!, number: parts.count + 1, data: Data(part), path: path)))
                }
            }
            // A stream read by a cancelled task (a paused or cancelled
            // transfer) just stops, as if the file had ended there.
            try Task.checkCancellation()
            guard let uploadID else {
                var request = URLRequest(url: configuration.url(for: key))
                request.httpMethod = "PUT"
                request.httpBody = buffer
                _ = try await send(&request, path: path, payload: buffer)
                return
            }
            if !buffer.isEmpty || parts.isEmpty {
                parts.append((parts.count + 1, try await uploadPart(key, uploadID: uploadID, number: parts.count + 1, data: buffer, path: path)))
            }
            try await completeMultipart(key, uploadID: uploadID, parts: parts, path: path)
        } catch {
            if let uploadID { await abortMultipart(key, uploadID: uploadID, path: path) }
            throw error
        }
    }

    /// S3 can answer 200 and still have failed, with the error in the body.
    private func completeMultipart(_ key: String, uploadID: String, parts: [(Int, String)], path: RemotePath) async throws {
        let body = "<CompleteMultipartUpload>" + parts.map { "<Part><PartNumber>\($0.0)</PartNumber><ETag>\($0.1)</ETag></Part>" }.joined() + "</CompleteMultipartUpload>"
        var request = URLRequest(url: configuration.url(for: key, query: [("uploadId", uploadID)]))
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        let (data, _) = try await send(&request, path: path, payload: request.httpBody!)
        try Self.checkForError(in: data, path: path)
    }

    /// Throws away the parts sent so far, which would otherwise stay (and be
    /// billed) unseen. The upload may have stopped because its task was
    /// cancelled, so this runs in a task of its own that is not.
    private func abortMultipart(_ key: String, uploadID: String, path: RemotePath) async {
        await Task.detached { [self] in
            var abort = URLRequest(url: configuration.url(for: key, query: [("uploadId", uploadID)]))
            abort.httpMethod = "DELETE"
            _ = try? await send(&abort, path: path, allowing: [404])
        }.value
    }

    static func checkForError(in data: Data, path: RemotePath) throws {
        let reply = S3XML.parse(data)
        guard reply.root == "Error" else { return }
        let message = reply.values["Message"]?.first ?? reply.values["Code"]?.first ?? ""
        throw ProviderError.io(String(localized: "S3 오류: \(message)"))
    }

    private func startMultipart(_ key: String, path: RemotePath) async throws -> String {
        var request = URLRequest(url: configuration.url(for: key, query: [("uploads", "")]))
        request.httpMethod = "POST"
        let (data, _) = try await send(&request, path: path)
        guard let id = S3XML.parse(data).values["UploadId"]?.first else { throw ProviderError.io(String(localized: "S3 업로드를 시작할 수 없습니다")) }
        return id
    }

    private func uploadPart(_ key: String, uploadID: String, number: Int, data: Data, path: RemotePath) async throws -> String {
        var request = URLRequest(url: configuration.url(for: key, query: [("partNumber", String(number)), ("uploadId", uploadID)]))
        request.httpMethod = "PUT"
        request.httpBody = data
        let (_, response) = try await send(&request, path: path, payload: data)
        return response.value(forHTTPHeaderField: "ETag") ?? ""
    }

    /// An empty "folder/" object, as the AWS console makes.
    public func makeDirectory(_ path: RemotePath) async throws {
        if (try? await stat(path)) != nil { throw ProviderError.alreadyExists(path) }
        var request = URLRequest(url: configuration.url(for: Self.prefix(path)))
        request.httpMethod = "PUT"
        request.httpBody = Data()
        _ = try await send(&request, path: path, payload: Data())
    }

    public func copy(_ from: RemotePath, to: RemotePath) async throws {
        if (try? await stat(to)) != nil { throw ProviderError.alreadyExists(to) }
        let source = try await stat(from)
        if source.isDirectory {
            // The folder exists at the destination even if the source had no marker.
            var marker = URLRequest(url: configuration.url(for: Self.prefix(to)))
            marker.httpMethod = "PUT"
            marker.httpBody = Data()
            _ = try await send(&marker, path: to, payload: Data())
        }
        for (old, new, size) in try await keys(of: source, movingTo: to) where !(source.isDirectory && old == Self.prefix(from)) {
            if let size, size > largestSingleCopy {
                try await copyInParts(old, to: new, size: size, path: from)
            } else {
                var request = URLRequest(url: configuration.url(for: new))
                request.httpMethod = "PUT"
                request.setValue(copySource(old), forHTTPHeaderField: "x-amz-copy-source")
                let (data, _) = try await send(&request, path: from)
                // A copy can fail after S3 has already answered 200; moving on
                // would let `move` delete the only copy.
                try Self.checkForError(in: data, path: from)
            }
        }
    }

    private func copySource(_ key: String) -> String {
        "/\(configuration.bucket)/\(AWSSigner.encode(key, keepingSlashes: true))"
    }

    /// A multipart upload whose parts are ranges of the original, copied by S3.
    private func copyInParts(_ old: String, to new: String, size: Int64, path: RemotePath) async throws {
        let uploadID = try await startMultipart(new, path: path)
        do {
            var parts: [(Int, String)] = []
            var offset: Int64 = 0
            while offset < size {
                let end = min(offset + Self.copyPartSize, size) - 1
                let number = parts.count + 1
                var request = URLRequest(url: configuration.url(for: new, query: [("partNumber", String(number)), ("uploadId", uploadID)]))
                request.httpMethod = "PUT"
                request.setValue(copySource(old), forHTTPHeaderField: "x-amz-copy-source")
                request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "x-amz-copy-source-range")
                let (data, _) = try await send(&request, path: path)
                try Self.checkForError(in: data, path: path)
                guard let tag = S3XML.parse(data).values["ETag"]?.first else { throw ProviderError.io(String(localized: "S3 복사 응답이 올바르지 않습니다")) }
                parts.append((number, tag))
                offset = end + 1
            }
            try await completeMultipart(new, uploadID: uploadID, parts: parts, path: path)
        } catch {
            await abortMultipart(new, uploadID: uploadID, path: path)
            throw error
        }
    }

    /// S3 has no rename: copy, then delete the originals.
    public func move(_ from: RemotePath, to: RemotePath) async throws {
        try await copy(from, to: to)
        try await delete(from)
    }

    public func delete(_ path: RemotePath) async throws {
        let item = try await stat(path)
        for (key, _, _) in try await keys(of: item, movingTo: path) {
            var request = URLRequest(url: configuration.url(for: key))
            request.httpMethod = "DELETE"
            _ = try await send(&request, path: path, allowing: [404])
        }
    }

    /// Every object under `item` (itself for a file; for a folder its contents
    /// and its marker, if it has one) paired with where it lands below
    /// `destination`, and its size.
    private func keys(of item: FileItem, movingTo destination: RemotePath) async throws -> [(String, String, Int64?)] {
        guard item.isDirectory else { return [(Self.key(item.path), Self.key(destination), item.size)] }
        let prefix = Self.prefix(item.path)
        let newPrefix = Self.prefix(destination)
        return try await listAll(prefix: prefix, delimiter: nil).objects.map { ($0.key, newPrefix + $0.key.dropFirst(prefix.count), $0.size) }
    }

    // MARK: - Requests

    struct Listing {
        var folders: [String] = []
        var objects: [(key: String, size: Int64?, modified: Date?)] = []
    }

    func listAll(prefix: String, delimiter: String?, maxPages: Int = .max) async throws -> Listing {
        var listing = Listing()
        var token: String?
        var pages = 0
        repeat {
            var query = [("list-type", "2"), ("prefix", prefix)]
            if let delimiter { query.append(("delimiter", delimiter)) }
            if let token { query.append(("continuation-token", token)) }
            var request = URLRequest(url: configuration.url(for: "", query: query))
            let (data, _) = try await send(&request, path: RemotePath("/" + prefix))
            let page = S3XML.parse(data)
            listing.folders += page.values["Prefix", default: []].filter { $0 != prefix }
            listing.objects += page.objects
            token = page.values["IsTruncated"]?.first == "true" ? page.values["NextContinuationToken"]?.first : nil
            pages += 1
        } while token != nil && pages < maxPages
        return listing
    }

    @discardableResult
    func send(_ request: inout URLRequest, path: RemotePath, payload: Data? = nil, allowing allowed: Set<Int> = []) async throws -> (Data, HTTPURLResponse) {
        signer.sign(&request, payloadHash: payload.map(AWSSigner.hash) ?? AWSSigner.emptyPayloadHash)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.io(String(localized: "S3 응답이 올바르지 않습니다")) }
        if (200..<300).contains(http.statusCode) || allowed.contains(http.statusCode) { return (data, http) }
        let reply = S3XML.parse(data)
        let message = reply.values["Message"]?.first ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
        // The bucket lives in another region than the one saved: say which.
        if let region = http.value(forHTTPHeaderField: "x-amz-bucket-region") ?? reply.values["Region"]?.first,
           region != configuration.region, [301, 307, 400].contains(http.statusCode) {
            throw ProviderError.io(String(localized: "‘\(configuration.bucket)’ 버킷은 \(region) 리전에 있습니다. 연결 관리에서 리전을 \(region)(으)로 바꾸십시오."))
        }
        switch http.statusCode {
        case 404: throw ProviderError.notFound(path)
        case 403: throw ProviderError.permissionDenied(path)
        default: throw ProviderError.io(String(localized: "S3 오류 \(http.statusCode): \(message)"))
        }
    }

    static let httpDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
}

/// Which byte ranges to ask for next. The stream asks from one task at a
/// time, which is what makes the mutable state safe.
final class RangeReader: @unchecked Sendable {
    private var offset: Int64
    private let end: Int64?
    private var done = false

    init(start: Int64, end: Int64?) {
        offset = start
        self.end = end
    }

    func nextRange(_ size: Int) -> (Int64, Int64)? {
        guard !done else { return nil }
        let last = offset + Int64(size) - 1
        if let end {
            guard offset < end else { return nil }
            return (offset, min(last, end - 1))
        }
        return (offset, last)
    }

    func advance(by count: Int, requested: Int) {
        offset += Int64(count)
        if count < requested { done = true }
    }

    func finish() {
        done = true
    }
}

/// Just enough of S3's XML: every element's text by name, and the objects of a listing.
struct S3XML {
    /// The outermost element, e.g. "Error".
    var root: String?
    var values: [String: [String]] = [:]
    var objects: [(key: String, size: Int64?, modified: Date?)] = []

    static func parse(_ data: Data) -> S3XML {
        let delegate = Collector()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.result
    }

    private final class Collector: NSObject, XMLParserDelegate {
        var result = S3XML()
        private var text = ""
        private var object: [String: String]?

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            if result.root == nil { result.root = name }
            if name == "Contents" { object = [:] }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "Contents", let current = object, let key = current["Key"] {
                result.objects.append((key, current["Size"].flatMap { Int64($0) }, current["LastModified"].flatMap(Self.date)))
                object = nil
            } else if object != nil {
                object?[name] = text
            } else {
                result.values[name, default: []].append(text)
            }
            text = ""
        }

        /// "2009-10-12T17:50:30.000Z", with or without the fraction.
        static func date(_ text: String) -> Date? {
            (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text)) ?? (try? Date.ISO8601FormatStyle().parse(text))
        }
    }
}
