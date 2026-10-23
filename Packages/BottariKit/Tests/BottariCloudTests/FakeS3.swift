import Foundation
import Synchronization
@testable import BottariCloud

/// An S3 endpoint in memory, behind URLSession. It checks every request's
/// signature against `FakeS3.signer`, pages listings two entries at a time
/// and handles multipart uploads and server-side copies.
final class FakeS3: URLProtocol, @unchecked Sendable {
    struct Bucket {
        var objects: [String: (data: Data, modified: Date)] = [:]
        var uploads: [String: [Int: Data]] = [:]
        var log: [String] = []
    }

    static let state = Mutex<[String: Bucket]>([:])
    static let signer = AWSSigner(accessKey: "AKIDBOTTARI", secretKey: "bottari-secret", region: "us-east-1")

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeS3.self]
        return URLSession(configuration: configuration)
    }

    static func bucket(_ name: String) -> Bucket {
        state.withLock { $0[name] ?? Bucket() }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        let host = url.host() ?? ""
        var pathParts = url.path(percentEncoded: false).split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
        // Virtual-hosted (bucket.s3.…) or path style (s3.…/bucket/key).
        let bucket: String
        if host.hasPrefix("s3.") || host == "127.0.0.1" || host == "minio.local" {
            bucket = pathParts.first ?? ""
            pathParts = Array(pathParts.dropFirst())
        } else {
            bucket = String(host.split(separator: ".").first ?? "")
        }
        let key = pathParts.joined(separator: "/")
        let query = Dictionary(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map { ($0.name, $0.value ?? "") } ?? [], uniquingKeysWith: { a, _ in a })
        let body = request.httpBody ?? Self.read(request.httpBodyStream)
        let method = request.httpMethod ?? "GET"

        guard verifySignature(body: body) else {
            return respond(403, xml: "<Error><Code>SignatureDoesNotMatch</Code><Message>The request signature we calculated does not match</Message></Error>")
        }
        Self.state.withLock { $0[bucket, default: Bucket()].log.append("\(method) \(key)\(query.isEmpty ? "" : "?" + query.keys.sorted().joined(separator: "&"))") }

        switch (method, key.isEmpty) {
        case ("GET", true) where query["list-type"] == "2":
            list(bucket, query)
        case ("HEAD", false):
            guard let object = Self.bucket(bucket).objects[key] else { return respond(404) }
            respond(200, headers: ["Content-Length": String(object.data.count), "Last-Modified": S3Provider.httpDate.string(from: object.modified)])
        case ("GET", false):
            guard let object = Self.bucket(bucket).objects[key] else { return respond(404, xml: "<Error><Message>NoSuchKey</Message></Error>") }
            if let range = request.value(forHTTPHeaderField: "Range"), range.hasPrefix("bytes=") {
                let bounds = range.dropFirst(6).split(separator: "-").compactMap { Int($0) }
                guard bounds.count == 2, bounds[0] < object.data.count else { return respond(416) }
                let upper = min(bounds[1], object.data.count - 1)
                respond(206, data: object.data.subdata(in: bounds[0]..<upper + 1))
            } else {
                respond(200, data: object.data)
            }
        case ("PUT", false):
            if let source = request.value(forHTTPHeaderField: "x-amz-copy-source") {
                // "/bucket/key/with/slashes"
                let sourceKey = source.drop { $0 == "/" }.split(separator: "/", maxSplits: 1).last.map { String($0).removingPercentEncoding ?? String($0) } ?? ""
                guard let object = Self.bucket(bucket).objects[sourceKey] else { return respond(404) }
                Self.state.withLock { $0[bucket]!.objects[key] = (object.data, Date()) }
                respond(200, xml: "<CopyObjectResult><ETag>\"x\"</ETag></CopyObjectResult>")
            } else if let part = query["partNumber"].flatMap(Int.init), let upload = query["uploadId"] {
                Self.state.withLock { $0[bucket]!.uploads[upload]?[part] = body }
                respond(200, headers: ["ETag": "\"part-\(part)\""])
            } else {
                Self.state.withLock { $0[bucket, default: Bucket()].objects[key] = (body, Date()) }
                respond(200)
            }
        case ("POST", false) where query["uploads"] != nil:
            let id = UUID().uuidString
            Self.state.withLock { $0[bucket, default: Bucket()].uploads[id] = [:] }
            respond(200, xml: "<InitiateMultipartUploadResult><UploadId>\(id)</UploadId></InitiateMultipartUploadResult>")
        case ("POST", false) where query["uploadId"] != nil:
            let id = query["uploadId"]!
            Self.state.withLock { state in
                let parts = state[bucket]!.uploads.removeValue(forKey: id) ?? [:]
                state[bucket]!.objects[key] = (parts.keys.sorted().reduce(Data()) { $0 + parts[$1]! }, Date())
            }
            respond(200, xml: "<CompleteMultipartUploadResult/>")
        case ("DELETE", false):
            if let id = query["uploadId"] {
                Self.state.withLock { _ = $0[bucket]?.uploads.removeValue(forKey: id) }
            } else {
                Self.state.withLock { _ = $0[bucket]?.objects.removeValue(forKey: key) }
            }
            respond(204)
        default:
            respond(400)
        }
    }

    private func list(_ bucket: String, _ query: [String: String]) {
        let prefix = query["prefix"] ?? ""
        let delimiter = query["delimiter"]
        let keys = Self.bucket(bucket).objects.keys.filter { $0.hasPrefix(prefix) }.sorted()
        var entries: [(isPrefix: Bool, value: String)] = []
        for key in keys {
            let rest = key.dropFirst(prefix.count)
            if let delimiter, let cut = rest.range(of: delimiter) {
                let common = prefix + rest[..<cut.upperBound]
                if !entries.contains(where: { $0.isPrefix && $0.value == common }) { entries.append((true, common)) }
            } else {
                entries.append((false, key))
            }
        }
        let start = Int(query["continuation-token"] ?? "") ?? 0
        let page = entries.dropFirst(start).prefix(2)
        let truncated = start + page.count < entries.count
        let objects = Self.bucket(bucket).objects
        var xml = "<ListBucketResult><Prefix>\(prefix)</Prefix><IsTruncated>\(truncated)</IsTruncated>"
        if truncated { xml += "<NextContinuationToken>\(start + page.count)</NextContinuationToken>" }
        for entry in page {
            if entry.isPrefix {
                xml += "<CommonPrefixes><Prefix>\(Self.escape(entry.value))</Prefix></CommonPrefixes>"
            } else {
                let object = objects[entry.value]!
                xml += "<Contents><Key>\(Self.escape(entry.value))</Key><Size>\(object.data.count)</Size><LastModified>2026-10-23T05:00:00.000Z</LastModified></Contents>"
            }
        }
        respond(200, xml: xml + "</ListBucketResult>")
    }

    /// Signs a copy of the request with the same date and headers and compares.
    private func verifySignature(body: Data) -> Bool {
        guard let authorization = request.value(forHTTPHeaderField: "Authorization"),
              let amzDate = request.value(forHTTPHeaderField: "x-amz-date"),
              let payload = request.value(forHTTPHeaderField: "x-amz-content-sha256"),
              let date = AWSSigner.timestamp.date(from: amzDate),
              let signed = authorization.components(separatedBy: "SignedHeaders=").last?.components(separatedBy: ",").first
        else { return false }
        guard payload == AWSSigner.hash(body) else { return false }
        var copy = URLRequest(url: request.url!)
        copy.httpMethod = request.httpMethod
        for name in signed.split(separator: ";").map(String.init) where !["host", "x-amz-date", "x-amz-content-sha256"].contains(name) {
            copy.setValue(request.value(forHTTPHeaderField: name), forHTTPHeaderField: name)
        }
        Self.signer.sign(&copy, payloadHash: payload, date: date)
        return copy.value(forHTTPHeaderField: "Authorization") == authorization
    }

    private func respond(_ status: Int, headers: [String: String] = [:], data: Data = Data(), xml: String? = nil) {
        let body = xml.map { Data($0.utf8) } ?? data
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
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

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
    }
}
