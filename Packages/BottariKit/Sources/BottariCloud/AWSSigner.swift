import Crypto
import Foundation

/// AWS Signature Version 4 for S3 requests, so any S3-compatible store
/// (AWS, Cloudflare R2, MinIO) works without an SDK.
public struct AWSSigner: Sendable {
    public let accessKey: String
    let secretKey: String
    public let region: String
    public let service: String

    public static let emptyPayloadHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    public init(accessKey: String, secretKey: String, region: String, service: String = "s3") {
        self.accessKey = accessKey
        self.secretKey = secretKey
        self.region = region
        self.service = service
    }

    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).hex
    }

    /// Adds x-amz-date, x-amz-content-sha256 and Authorization to `request`.
    /// Every header already on the request is signed.
    public func sign(_ request: inout URLRequest, payloadHash: String, date: Date = Date()) {
        let amzDate = Self.timestamp.string(from: date)
        let day = String(amzDate.prefix(8))
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        let (canonical, signedHeaders) = canonicalRequest(request, payloadHash: payloadHash)
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope, Self.hash(Data(canonical.utf8))].joined(separator: "\n")
        var key = SymmetricKey(data: Data("AWS4\(secretKey)".utf8))
        for part in [day, region, service, "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
        }
        let signature = HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key).hex
        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
    }

    func canonicalRequest(_ request: URLRequest, payloadHash: String) -> (String, String) {
        let url = request.url!
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = components?.percentEncodedPath.isEmpty == false ? components!.percentEncodedPath : "/"
        // Re-encode from the decoded form so "/" and "+" come out as AWS wants.
        var pairs: [(name: String, value: String)] = []
        for item in components?.percentEncodedQueryItems ?? [] {
            let name = item.name.removingPercentEncoding ?? item.name
            let value = item.value?.removingPercentEncoding ?? ""
            pairs.append((Self.encode(name), Self.encode(value)))
        }
        pairs.sort { $0.name == $1.name ? $0.value < $1.value : $0.name < $1.name }
        let query = pairs.map { "\($0.name)=\($0.value)" }.joined(separator: "&")
        var headers: [String: String] = [:]
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            headers[name.lowercased()] = value.trimmingCharacters(in: .whitespaces)
                .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        }
        if headers["host"] == nil, let host = url.host() {
            headers["host"] = url.port.map { "\(host):\($0)" } ?? host
        }
        let names = headers.keys.sorted()
        let canonicalHeaders = names.map { "\($0):\(headers[$0]!)\n" }.joined()
        let signedHeaders = names.joined(separator: ";")
        let canonical = [request.httpMethod ?? "GET", path, query, canonicalHeaders, signedHeaders, payloadHash].joined(separator: "\n")
        return (canonical, signedHeaders)
    }

    /// RFC 3986 encoding: unreserved characters stay, everything else is %XX.
    public static func encode(_ text: String, keepingSlashes: Bool = false) -> String {
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        if keepingSlashes { allowed.insert("/") }
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()
}

extension Sequence where Element == UInt8 {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
