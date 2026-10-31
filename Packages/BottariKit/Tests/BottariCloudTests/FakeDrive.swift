import Crypto
import Foundation
import Synchronization
@testable import BottariCloud

/// Google Drive v3 in memory, behind URLSession: listings (two per page),
/// media and export downloads, resumable uploads, metadata patches and copies.
/// Each access token is its own drive, so tests do not see each other.
final class FakeDrive: URLProtocol, @unchecked Sendable {
    struct File {
        var id: String
        var name: String
        var parents: [String]
        var mimeType: String
        var data = Data()
        var modified = Date(timeIntervalSince1970: 1_800_000_000)
        var created: Int
        var trashed = false
    }

    struct Upload {
        var fileID: String?
        var name: String
        var parents: [String]
        var received = Data()
    }

    struct Drive {
        var files: [String: File] = [:]
        var uploads: [String: Upload] = [:]
        var log: [String] = []
        var counter = 0
        /// Requests still to be refused with "rate limit exceeded".
        var throttled = 0
    }

    static let state = Mutex<[String: Drive]>([:])

    struct Token: AccessTokenSource {
        let value: String
        func accessToken() async throws -> String { value }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeDrive.self]
        return URLSession(configuration: configuration)
    }

    @discardableResult
    static func add(_ drive: String, name: String, in parent: String = "root", mimeType: String = "application/octet-stream", data: Data = Data()) -> String {
        state.withLock { state in
            state[drive, default: Drive()].counter += 1
            let counter = state[drive]!.counter
            let id = "id\(counter)"
            state[drive]!.files[id] = File(id: id, name: name, parents: [parent], mimeType: mimeType, data: data, created: counter)
            return id
        }
    }

    static func throttle(_ drive: String, times: Int) {
        state.withLock { $0[drive, default: Drive()].throttled = times }
    }

    static func drive(_ name: String) -> Drive {
        state.withLock { $0[name] ?? Drive() }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let token = request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: ""), token != "expired" else {
            return respond(401, json: ["error": ["message": "Invalid Credentials"]])
        }
        let url = request.url!
        let path = url.path(percentEncoded: false)
        let query = Dictionary(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map { ($0.name, $0.value ?? "") } ?? [], uniquingKeysWith: { a, _ in a })
        let method = request.httpMethod ?? "GET"
        let body = request.httpBody ?? Self.read(request.httpBodyStream)
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        Self.state.withLock { $0[token, default: Drive()].log.append("\(method) \(path)") }
        let throttled = Self.state.withLock { state in
            guard state[token, default: Drive()].throttled > 0 else { return false }
            state[token]!.throttled -= 1
            return true
        }
        if throttled {
            return respond(403, json: ["error": ["message": "Rate Limit Exceeded", "errors": [["reason": "userRateLimitExceeded"]]]])
        }
        let parts = path.split(separator: "/").map(String.init)

        if let uploadID = query["upload_id"], method == "PUT" {
            return receiveChunk(token, uploadID, body)
        }
        switch (method, parts) {
        case ("GET", ["drive", "v3", "files"]):
            list(token, query)
        case ("GET", let p) where p.count == 4 && p[2] == "files":
            guard let file = Self.drive(token).files[p[3]] else { return respond(404, json: ["error": ["message": "File not found"]]) }
            guard query["alt"] == "media" else { return respond(200, json: Self.describe(file)) }
            if let range = request.value(forHTTPHeaderField: "Range"), range.hasPrefix("bytes=") {
                let bounds = range.dropFirst(6).split(separator: "-").compactMap { Int($0) }
                guard bounds.count == 2, bounds[0] < file.data.count else { return respond(416, data: Data()) }
                respond(206, data: file.data.subdata(in: bounds[0]..<min(bounds[1], file.data.count - 1) + 1))
            } else {
                respond(200, data: file.data)
            }
        case ("GET", let p) where p.count == 5 && p[4] == "export":
            guard let file = Self.drive(token).files[p[3]] else { return respond(404, data: Data()) }
            respond(200, data: Data("exported \(file.name) as \(query["mimeType"] ?? "")".utf8))
        case ("POST", ["drive", "v3", "files"]):
            let id = Self.add(token, name: json["name"] as? String ?? "", in: (json["parents"] as? [String])?.first ?? "root", mimeType: json["mimeType"] as? String ?? "application/octet-stream")
            respond(200, json: Self.describe(Self.drive(token).files[id]!))
        case ("POST", let p) where p.count == 5 && p[4] == "copy":
            guard let source = Self.drive(token).files[p[3]] else { return respond(404, data: Data()) }
            let id = Self.add(token, name: json["name"] as? String ?? source.name, in: (json["parents"] as? [String])?.first ?? source.parents[0], mimeType: source.mimeType, data: source.data)
            respond(200, json: Self.describe(Self.drive(token).files[id]!))
        case ("POST", ["upload", "drive", "v3", "files"]):
            startUpload(token, Upload(fileID: nil, name: json["name"] as? String ?? "", parents: json["parents"] as? [String] ?? ["root"]))
        case ("PATCH", let p) where p.first == "upload":
            startUpload(token, Upload(fileID: p.last, name: "", parents: []))
        case ("PATCH", let p) where p.count == 4:
            Self.state.withLock { state in
                guard var file = state[token]?.files[p[3]] else { return }
                if let name = json["name"] as? String { file.name = name }
                if json["trashed"] as? Bool == true { file.trashed = true }
                if let text = json["modifiedTime"] as? String, let date = try? Date.ISO8601FormatStyle().parse(text) { file.modified = date }
                if let add = query["addParents"], let remove = query["removeParents"] {
                    file.parents = file.parents.filter { $0 != remove } + [add]
                }
                state[token]!.files[p[3]] = file
            }
            guard let file = Self.drive(token).files[p[3]] else { return respond(404, data: Data()) }
            respond(200, json: Self.describe(file))
        case ("DELETE", let p) where p.count == 4:
            Self.state.withLock { state in
                // Removes the folder's descendants as well.
                var doomed = [p[3]]
                while let id = doomed.popLast() {
                    state[token]?.files[id] = nil
                    doomed += state[token]?.files.values.filter { $0.parents.contains(id) }.map(\.id) ?? []
                }
            }
            respond(204, data: Data())
        default:
            respond(400, json: ["error": ["message": "unexpected \(method) \(path)"]])
        }
    }

    private func list(_ token: String, _ query: [String: String]) {
        // "'<id>' in parents and trashed = false"
        let parent = query["q"].map { $0.components(separatedBy: "'") }.flatMap { $0.count > 1 ? $0[1] : nil } ?? "root"
        let children = Self.drive(token).files.values
            .filter { $0.parents.contains(parent) && !$0.trashed }
            .sorted { $0.name == $1.name ? $0.created < $1.created : $0.name < $1.name }
        let start = Int(query["pageToken"] ?? "") ?? 0
        let page = Array(children.dropFirst(start).prefix(2))
        var result: [String: Any] = ["files": page.map(Self.describe)]
        if start + page.count < children.count { result["nextPageToken"] = String(start + page.count) }
        respond(200, json: result)
    }

    private func startUpload(_ token: String, _ upload: Upload) {
        let id = UUID().uuidString
        Self.state.withLock { $0[token, default: Drive()].uploads[id] = upload }
        respond(200, headers: ["Location": "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&upload_id=\(id)"], data: Data())
    }

    private func receiveChunk(_ token: String, _ id: String, _ body: Data) {
        let range = request.value(forHTTPHeaderField: "Content-Range") ?? ""
        let total = range.split(separator: "/").last.flatMap { Int($0) }
        let done: Upload? = Self.state.withLock { state in
            guard var upload = state[token]?.uploads[id] else { return nil }
            upload.received.append(body)
            state[token]!.uploads[id] = upload
            guard let total, upload.received.count == total else { return nil }
            state[token]!.uploads[id] = nil
            return upload
        }
        guard let done else { return respond(308, data: Data()) }
        let fileID: String
        if let existing = done.fileID {
            Self.state.withLock { state in
                state[token]!.files[existing]?.data = done.received
                state[token]!.files[existing]?.modified = Date()
            }
            fileID = existing
        } else {
            fileID = Self.add(token, name: done.name, in: done.parents.first ?? "root", data: done.received)
        }
        respond(200, json: Self.describe(Self.drive(token).files[fileID]!))
    }

    private static func describe(_ file: File) -> [String: Any] {
        var fields: [String: Any] = [
            "id": file.id, "name": file.name, "mimeType": file.mimeType, "parents": file.parents,
            "modifiedTime": file.modified.formatted(.iso8601),
        ]
        if !file.mimeType.hasPrefix("application/vnd.google-apps.") {
            fields["size"] = String(file.data.count)
            fields["sha256Checksum"] = SHA256.hash(data: file.data).map { String(format: "%02x", $0) }.joined()
        }
        return fields
    }

    private func respond(_ status: Int, headers: [String: String] = [:], json: [String: Any]) {
        respond(status, headers: headers.merging(["Content-Type": "application/json"]) { a, _ in a }, data: (try? JSONSerialization.data(withJSONObject: json)) ?? Data())
    }

    private func respond(_ status: Int, headers: [String: String] = [:], data: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func read(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
