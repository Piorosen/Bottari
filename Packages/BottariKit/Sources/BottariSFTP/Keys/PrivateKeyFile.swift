import _CryptoExtras
import Citadel
import CommonCrypto
import Crypto
import Foundation
import NIOCore
import NIOSSH

/// A private key file as `ssh-keygen` and other tools write it: OpenSSH's own
/// format, with or without a passphrase, or an unencrypted PEM key.
enum PrivateKeyFile {
    case ed25519(Curve25519.Signing.PrivateKey)
    case p256(P256.Signing.PrivateKey)
    case p384(P384.Signing.PrivateKey)
    case p521(P521.Signing.PrivateKey)
    /// `body` is the public key blob after its type name.
    case rsa(_RSA.Signing.PrivateKey, body: Data)

    /// Reads `text`. A missing or wrong passphrase and anything that is not a
    /// key read as `unreadableKey`; key kinds Bottari cannot use as `unsupportedKey`.
    init(_ text: String, passphrase: String?) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----") {
            self = try Self.openSSH(Self.payload(of: trimmed), passphrase: passphrase)
        } else if trimmed.hasPrefix("-----BEGIN") {
            self = try Self.pem(trimmed)
        } else {
            throw SFTPConnectError.unreadableKey
        }
    }

    /// One authentication attempt per way to offer the key. RSA goes with
    /// SHA-512 first, then SHA-256 (servers and appliances that know only
    /// that one), and SHA-1 for servers too old for either.
    func attempts(username: String) -> [SSHAuthenticationMethod] {
        switch self {
        case .ed25519(let key): [.ed25519(username: username, privateKey: key)]
        case .p256(let key): [.p256(username: username, privateKey: key)]
        case .p384(let key): [.p384(username: username, privateKey: key)]
        case .p521(let key): [.p521(username: username, privateKey: key)]
        case .rsa(let key, let body):
            [
                Self.offer(OfferedPrivateKey<RSASHA512Kind>(body: body) { data in
                    try key.signature(for: SHA512.hash(data: data), padding: .insecurePKCS1v1_5).rawRepresentation
                }, username: username),
                Self.offer(OfferedPrivateKey<RSASHA256Kind>(body: body) { data in
                    try key.signature(for: SHA256.hash(data: data), padding: .insecurePKCS1v1_5).rawRepresentation
                }, username: username),
                Self.offer(OfferedPrivateKey<RSASHA1Kind>(body: body) { data in
                    try key.signature(for: Insecure.SHA1.hash(data: data), padding: .insecurePKCS1v1_5).rawRepresentation
                }, username: username),
            ]
        }
    }

    /// The public key blob, as the base64 part of a `.pub` file holds it.
    var publicKeyBlob: Data {
        var blob = Data()
        func curve(_ name: String, _ curve: String, _ point: Data) {
            blob.appendSSHString(Data(name.utf8))
            blob.appendSSHString(Data(curve.utf8))
            blob.appendSSHString(point)
        }
        switch self {
        case .ed25519(let key):
            blob.appendSSHString(Data(Ed25519Kind.name.utf8))
            blob.appendSSHString(key.publicKey.rawRepresentation)
        case .p256(let key): curve(ECDSAP256Kind.name, "nistp256", key.publicKey.x963Representation)
        case .p384(let key): curve(ECDSAP384Kind.name, "nistp384", key.publicKey.x963Representation)
        case .p521(let key): curve(ECDSAP521Kind.name, "nistp521", key.publicKey.x963Representation)
        case .rsa(_, let body):
            blob.appendSSHString(Data(RSASHA1Kind.name.utf8))
            blob.append(body)
        }
        return blob
    }

    static func offer<Kind>(_ key: OfferedPrivateKey<Kind>, username: String) -> SSHAuthenticationMethod {
        .custom(SingleKeyOffer(username: username, key: key.asNIOSSHKey))
    }

    // MARK: - OpenSSH format

    private static func payload(of text: String) throws -> Data {
        let base64 = text
            .split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()
            .filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: base64) else { throw SFTPConnectError.unreadableKey }
        return data
    }

    /// `openssh-key-v1`: cipher, KDF and its options, one public key, then the
    /// private part, encrypted unless the cipher is `none`.
    private static func openSSH(_ data: Data, passphrase: String?) throws -> PrivateKeyFile {
        let magic = Data("openssh-key-v1".utf8) + Data([0])
        guard data.starts(with: magic) else { throw SFTPConnectError.unreadableKey }
        var wire = SSHWire(data.dropFirst(magic.count))
        do {
            let cipher = String(decoding: try wire.readString(), as: UTF8.self)
            let kdf = String(decoding: try wire.readString(), as: UTF8.self)
            var kdfOptions = SSHWire(try wire.readString())
            guard try wire.readUInt32() == 1 else { throw SFTPConnectError.unsupportedKey(String(localized: "여러 키가 든 파일")) }
            _ = try wire.readString()
            let sealed = try wire.readString()
            let trailer = wire.remainder

            let plain: Data
            if cipher == "none" {
                plain = sealed
            } else {
                guard kdf == "bcrypt" else { throw SFTPConnectError.unsupportedKey(String(localized: "키 암호화 방식 \(kdf)")) }
                guard let spec = CipherSpec(cipher) else { throw SFTPConnectError.unsupportedKey(String(localized: "키 암호화 방식 \(cipher)")) }
                guard let passphrase, !passphrase.isEmpty else { throw SFTPConnectError.unreadableKey }
                let salt = try kdfOptions.readString()
                let rounds = Int(try kdfOptions.readUInt32())
                guard let derived = BcryptPBKDF.derive(passphrase: Data(passphrase.utf8), salt: salt, rounds: rounds, keyLength: spec.keyLength + spec.ivLength) else {
                    throw SFTPConnectError.unreadableKey
                }
                plain = try spec.decrypt(sealed, tag: trailer.prefix(spec.tagLength), key: derived.prefix(spec.keyLength), iv: derived.suffix(spec.ivLength))
            }
            return try privateSection(plain)
        } catch let error as SFTPConnectError {
            throw error
        } catch {
            throw SFTPConnectError.unreadableKey
        }
    }

    /// Two equal check words (unequal means a wrong passphrase), the key type
    /// and the key, then the comment and padding.
    private static func privateSection(_ data: Data) throws -> PrivateKeyFile {
        var wire = SSHWire(data)
        guard try wire.readUInt32() == wire.readUInt32() else { throw SFTPConnectError.unreadableKey }
        let type = String(decoding: try wire.readString(), as: UTF8.self)
        switch type {
        case "ssh-ed25519":
            _ = try wire.readString()
            let secret = try wire.readString()
            guard secret.count == 64 else { throw SFTPConnectError.unreadableKey }
            return .ed25519(try Curve25519.Signing.PrivateKey(rawRepresentation: secret.prefix(32)))
        case "ssh-rsa":
            let n = try wire.readString().mpintMagnitude
            let e = try wire.readString().mpintMagnitude
            let d = try wire.readString().mpintMagnitude
            _ = try wire.readString() // iqmp
            let p = try wire.readString().mpintMagnitude
            let q = try wire.readString().mpintMagnitude
            return .rsa(try _RSA.Signing.PrivateKey(n: n, e: e, d: d, p: p, q: q), body: RSAKeyBody.encode(e: e, n: n))
        case ECDSAP256Kind.name:
            return .p256(try P256.Signing.PrivateKey(rawRepresentation: try ecdsaScalar(&wire, size: 32)))
        case ECDSAP384Kind.name:
            return .p384(try P384.Signing.PrivateKey(rawRepresentation: try ecdsaScalar(&wire, size: 48)))
        case ECDSAP521Kind.name:
            return .p521(try P521.Signing.PrivateKey(rawRepresentation: try ecdsaScalar(&wire, size: 66)))
        default:
            throw SFTPConnectError.unsupportedKey(type)
        }
    }

    /// `string curve, string Q, mpint d`, returning `d` padded to the curve's size.
    private static func ecdsaScalar(_ wire: inout SSHWire, size: Int) throws -> Data {
        _ = try wire.readString()
        _ = try wire.readString()
        let d = try wire.readString().mpintMagnitude
        guard d.count <= size else { throw SFTPConnectError.unreadableKey }
        return Data(count: size - d.count) + d
    }

    /// The ciphers `ssh-keygen` can protect a key with, apart from ChaCha20.
    private struct CipherSpec {
        enum Mode { case ctr, cbc, gcm }
        let mode: Mode
        let keyLength: Int

        init?(_ name: String) {
            switch name {
            case "aes128-ctr": (mode, keyLength) = (.ctr, 16)
            case "aes192-ctr": (mode, keyLength) = (.ctr, 24)
            case "aes256-ctr": (mode, keyLength) = (.ctr, 32)
            case "aes128-cbc": (mode, keyLength) = (.cbc, 16)
            case "aes192-cbc": (mode, keyLength) = (.cbc, 24)
            case "aes256-cbc": (mode, keyLength) = (.cbc, 32)
            case "aes128-gcm@openssh.com": (mode, keyLength) = (.gcm, 16)
            case "aes256-gcm@openssh.com": (mode, keyLength) = (.gcm, 32)
            default: return nil
            }
        }

        var ivLength: Int { mode == .gcm ? 12 : 16 }
        var tagLength: Int { mode == .gcm ? 16 : 0 }

        func decrypt(_ data: Data, tag: Data, key: Data, iv: Data) throws -> Data {
            switch mode {
            case .gcm:
                let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: data, tag: tag)
                return try AES.GCM.open(box, using: SymmetricKey(data: key))
            case .ctr:
                return try Self.commonCrypto(CCMode(kCCModeCTR), data, key: key, iv: iv)
            case .cbc:
                return try Self.commonCrypto(CCMode(kCCModeCBC), data, key: key, iv: iv)
            }
        }

        private static func commonCrypto(_ mode: CCMode, _ data: Data, key: Data, iv: Data) throws -> Data {
            var cryptor: CCCryptorRef?
            let created = key.withUnsafeBytes { key in
                iv.withUnsafeBytes { iv in
                    CCCryptorCreateWithMode(
                        CCOperation(kCCDecrypt), mode, CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                        iv.baseAddress, key.baseAddress, key.count, nil, 0, 0, 0, &cryptor
                    )
                }
            }
            guard created == kCCSuccess, let cryptor else { throw SFTPConnectError.unreadableKey }
            defer { CCCryptorRelease(cryptor) }
            var output = Data(count: data.count)
            var moved = 0
            let status = output.withUnsafeMutableBytes { output in
                data.withUnsafeBytes { input in
                    CCCryptorUpdate(cryptor, input.baseAddress, data.count, output.baseAddress, data.count, &moved)
                }
            }
            guard status == kCCSuccess else { throw SFTPConnectError.unreadableKey }
            return output.prefix(moved)
        }
    }

    // MARK: - PEM

    /// PKCS#1 (`RSA PRIVATE KEY`), SEC1 (`EC PRIVATE KEY`) and PKCS#8
    /// (`PRIVATE KEY`), as older `ssh-keygen -m PEM` and OpenSSL write them.
    private static func pem(_ text: String) throws -> PrivateKeyFile {
        if text.contains("ENCRYPTED") {
            throw SFTPConnectError.unsupportedKey(String(localized: "암호가 걸린 PEM 키. ssh-keygen -p로 OpenSSH 형식으로 바꾸십시오"))
        }
        if let key = try? _RSA.Signing.PrivateKey(unsafePEMRepresentation: text) {
            let primitives = try key.publicKey.getKeyPrimitives()
            return .rsa(key, body: RSAKeyBody.encode(e: primitives.publicExponent, n: primitives.modulus))
        }
        if let key = try? P256.Signing.PrivateKey(pemRepresentation: text) { return .p256(key) }
        if let key = try? P384.Signing.PrivateKey(pemRepresentation: text) { return .p384(key) }
        if let key = try? P521.Signing.PrivateKey(pemRepresentation: text) { return .p521(key) }
        if text.hasPrefix("-----BEGIN EC PRIVATE KEY-----"), let key = try? sec1(payload(of: text)) { return key }
        throw SFTPConnectError.unreadableKey
    }

    /// SEC1's `ECPrivateKey` with the curve spelled out as parameters rather
    /// than named, which is how `ssh-keygen -m PEM` on macOS writes it and
    /// CryptoKit will not read: `SEQUENCE { INTEGER 1, OCTET STRING d,
    /// [0] parameters, [1] BIT STRING publicKey }`. The curve follows from the
    /// size of the public point, or of `d` without one.
    private static func sec1(_ der: Data) throws -> PrivateKeyFile {
        var outer = DERReader(der)
        var key = DERReader(try outer.read(tag: 0x30))
        guard try key.read(tag: 0x02) == Data([1]) else { throw SFTPConnectError.unreadableKey }
        let d = try key.read(tag: 0x04)
        var size = d.count
        while !key.isAtEnd {
            let (tag, value) = try key.next()
            if tag == 0xA1 {
                var point = DERReader(value)
                // A BIT STRING starts with the count of unused bits, then `04 ‖ x ‖ y`.
                size = (try point.read(tag: 0x03).count - 2) / 2
            }
        }
        let scalar = d.mpintMagnitude
        guard scalar.count <= size else { throw SFTPConnectError.unreadableKey }
        let raw = Data(count: size - scalar.count) + scalar
        switch size {
        case 32: return .p256(try P256.Signing.PrivateKey(rawRepresentation: raw))
        case 48: return .p384(try P384.Signing.PrivateKey(rawRepresentation: raw))
        case 66: return .p521(try P521.Signing.PrivateKey(rawRepresentation: raw))
        default: throw SFTPConnectError.unsupportedKey(String(localized: "\(size * 8)비트 EC 키"))
        }
    }
}

/// Just enough DER to take apart a SEC1 key.
private struct DERReader {
    private let data: Data
    private var offset: Data.Index

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    var isAtEnd: Bool { offset >= data.endIndex }

    mutating func next() throws -> (tag: UInt8, value: Data) {
        guard data.endIndex - offset >= 2 else { throw SFTPConnectError.unreadableKey }
        let tag = data[offset]
        var length = Int(data[offset + 1])
        offset += 2
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count <= 4, data.endIndex - offset >= count else { throw SFTPConnectError.unreadableKey }
            length = data[offset..<offset + count].reduce(0) { $0 << 8 | Int($1) }
            offset += count
        }
        guard data.endIndex - offset >= length else { throw SFTPConnectError.unreadableKey }
        defer { offset += length }
        return (tag, Data(data[offset..<offset + length]))
    }

    mutating func read(tag expected: UInt8) throws -> Data {
        let (tag, value) = try next()
        guard tag == expected else { throw SFTPConnectError.unreadableKey }
        return value
    }
}

/// Offers exactly one key. Citadel asks a custom delegate only once, so trying
/// several keys means one connection attempt per key.
final class SingleKeyOffer: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    let username: String
    let key: NIOSSHPrivateKey

    init(username: String, key: NIOSSHPrivateKey) {
        self.username = username
        self.key = key
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        // NIOSSH calls delegates on the connection's event loop.
        let promise = nextChallengePromise.assumeIsolated()
        guard availableMethods.contains(.publicKey) else {
            promise.succeed(nil)
            return
        }
        promise.succeed(
            NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: .privateKey(.init(privateKey: key)))
        )
    }
}
