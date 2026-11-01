import _CryptoExtras
import Crypto
import Foundation

/// A key pair Bottari makes for a server, as `ssh-keygen` would: the private
/// key in OpenSSH's format, unencrypted (it goes into the Keychain), and the
/// line for the server's `authorized_keys`.
public struct NewSSHKey: Sendable, Equatable {
    public enum Kind: String, CaseIterable, Sendable {
        /// Short, fast, and what OpenSSH itself suggests.
        case ed25519
        /// ECDSA on P-256, for servers that take no Ed25519 (FIPS builds and the like).
        case ecdsa
        /// RSA 4096, for old servers and appliances. Bottari signs with
        /// rsa-sha2-512 or rsa-sha2-256, and SHA-1 (`ssh-rsa`) only as a last resort.
        case rsa
    }

    public let kind: Kind
    public let privateKey: String
    public let publicKey: String

    /// A key kept earlier, read back from its private half; nil if it is not
    /// one Bottari can use.
    public init?(privateKey text: String, comment: String = "bottari") {
        guard let key = try? PrivateKeyFile(text, passphrase: nil) else { return nil }
        kind = switch key {
        case .ed25519: .ed25519
        case .p256, .p384, .p521: .ecdsa
        case .rsa: .rsa
        }
        privateKey = text
        publicKey = key.publicKeyLine(comment: comment)
    }

    private init(kind: Kind, privateKey: String, publicKey: String) {
        self.kind = kind
        self.privateKey = privateKey
        self.publicKey = publicKey
    }

    /// `SHA256:…`, as `ssh-keygen -l` prints it.
    public var fingerprint: String {
        KnownHosts.fingerprint(ofOpenSSHKey: publicKey)
    }

    /// A new key; `comment` ends the public key line, e.g. `bottari@MacBook`.
    public static func generate(_ kind: Kind, comment: String) throws -> NewSSHKey {
        let key: PrivateKeyFile = switch kind {
        case .ed25519: .ed25519(Curve25519.Signing.PrivateKey())
        case .ecdsa: .p256(P256.Signing.PrivateKey())
        case .rsa: try rsa(_RSA.Signing.PrivateKey(keySize: .bits4096))
        }
        return NewSSHKey(kind: kind, privateKey: try key.openSSHText(comment: comment), publicKey: key.publicKeyLine(comment: comment))
    }

    private static func rsa(_ key: _RSA.Signing.PrivateKey) throws -> PrivateKeyFile {
        let primitives = try key.publicKey.getKeyPrimitives()
        return .rsa(key, body: RSAKeyBody.encode(e: primitives.publicExponent, n: primitives.modulus))
    }
}

extension PrivateKeyFile {
    /// The key's type as a `.pub` file starts with it.
    var publicKeyType: String {
        var wire = SSHWire(publicKeyBlob)
        return (try? wire.readString()).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// `type base64 comment`, a line for `authorized_keys`.
    func publicKeyLine(comment: String) -> String {
        [publicKeyType, publicKeyBlob.base64EncodedString(), comment].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The key as `ssh-keygen` writes it without a passphrase:
    /// `-----BEGIN OPENSSH PRIVATE KEY-----`, readable by `ssh` and by Bottari.
    func openSSHText(comment: String) throws -> String {
        var secret = Data()
        let check = UInt32.random(in: .min ... .max)
        secret.appendUInt32(check)
        secret.appendUInt32(check)
        secret.appendSSHString(Data(publicKeyType.utf8))
        switch self {
        case .ed25519(let key):
            let point = key.publicKey.rawRepresentation
            secret.appendSSHString(point)
            secret.appendSSHString(key.rawRepresentation + point)
        case .p256(let key):
            secret.appendSSHString(Data("nistp256".utf8))
            secret.appendSSHString(key.publicKey.x963Representation)
            secret.appendSSHString(key.rawRepresentation.asMPInt)
        case .p384(let key):
            secret.appendSSHString(Data("nistp384".utf8))
            secret.appendSSHString(key.publicKey.x963Representation)
            secret.appendSSHString(key.rawRepresentation.asMPInt)
        case .p521(let key):
            secret.appendSSHString(Data("nistp521".utf8))
            secret.appendSSHString(key.publicKey.x963Representation)
            secret.appendSSHString(key.rawRepresentation.asMPInt)
        case .rsa(let key, _):
            let parts = try RSAPrivateParts(der: key.derRepresentation)
            for value in [parts.n, parts.e, parts.d, parts.iqmp, parts.p, parts.q] {
                secret.appendSSHString(value.asMPInt)
            }
        }
        secret.appendSSHString(Data(comment.utf8))
        // Padded to the "none" cipher's block of 8 with 1, 2, 3, ….
        var pad: UInt8 = 1
        while secret.count % 8 != 0 {
            secret.append(pad)
            pad += 1
        }

        var file = Data("openssh-key-v1".utf8) + Data([0])
        file.appendSSHString(Data("none".utf8))
        file.appendSSHString(Data("none".utf8))
        file.appendSSHString(Data())
        file.appendUInt32(1)
        file.appendSSHString(publicKeyBlob)
        file.appendSSHString(secret)
        let base64 = file.base64EncodedString()
        let lines = stride(from: 0, to: base64.count, by: 70).map { start in
            let from = base64.index(base64.startIndex, offsetBy: start)
            return String(base64[from..<(base64.index(from, offsetBy: 70, limitedBy: base64.endIndex) ?? base64.endIndex)])
        }
        return (["-----BEGIN OPENSSH PRIVATE KEY-----"] + lines + ["-----END OPENSSH PRIVATE KEY-----"]).joined(separator: "\n") + "\n"
    }
}

/// The numbers of an RSA private key, from its PKCS#1 or PKCS#8 DER form.
struct RSAPrivateParts {
    let n, e, d, p, q, iqmp: Data

    init(der: Data) throws {
        var elements = try DER(der).sequenceElements()
        // PKCS#8 wraps PKCS#1: version, algorithm, then the key as an octet string.
        if elements.count == 3, elements[1].tag == 0x30, elements[2].tag == 0x04 {
            elements = try DER(elements[2].content).sequenceElements()
        }
        let integers = elements.filter { $0.tag == 0x02 }.map(\.content.mpintMagnitude)
        // version, n, e, d, p, q, d mod (p-1), d mod (q-1), q⁻¹ mod p
        guard elements.count >= 9, integers.count == elements.count else { throw SFTPConnectError.unreadableKey }
        (n, e, d, p, q, iqmp) = (integers[1], integers[2], integers[3], integers[4], integers[5], integers[8])
    }

    /// Just enough DER for the above: tag, length, content.
    private struct DER {
        private let data: Data
        private var offset: Data.Index

        init(_ data: Data) {
            self.data = data
            offset = data.startIndex
        }

        /// The elements of the SEQUENCE this starts with.
        func sequenceElements() throws -> [(tag: UInt8, content: Data)] {
            var reader = self
            let element = try reader.next()
            guard element.tag == 0x30 else { throw SFTPConnectError.unreadableKey }
            var inner = DER(element.content)
            var elements: [(tag: UInt8, content: Data)] = []
            while !inner.isAtEnd { elements.append(try inner.next()) }
            return elements
        }

        var isAtEnd: Bool { offset >= data.endIndex }

        mutating func next() throws -> (tag: UInt8, content: Data) {
            guard offset + 2 <= data.endIndex else { throw SFTPConnectError.unreadableKey }
            let tag = data[offset]
            var length = Int(data[offset + 1])
            offset += 2
            if length & 0x80 != 0 {
                let count = length & 0x7F
                guard count <= 4, offset + count <= data.endIndex else { throw SFTPConnectError.unreadableKey }
                length = data[offset..<offset + count].reduce(0) { $0 << 8 | Int($1) }
                offset += count
            }
            guard offset + length <= data.endIndex else { throw SFTPConnectError.unreadableKey }
            defer { offset += length }
            return (tag, Data(data[offset..<offset + length]))
        }
    }
}
