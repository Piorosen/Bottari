import _CryptoExtras
import Crypto
import Foundation
import NIOCore
import NIOSSH

/// A kind of key Bottari offers through its own NIOSSH key type, needed for
/// RSA keys, which NIOSSH does not know and Citadel only signs with SHA-1.
protocol OfferedKeyKind: Sendable {
    /// The algorithm name. NIOSSH writes it as the request's algorithm and as
    /// the type at the start of the public key blob.
    static var name: String { get }
    /// Whether `signature` (the blob after its type name) signs `data` for the
    /// public key whose blob, after its type name, is `body`.
    static func isValid(signature: Data, for data: Data, publicKey body: Data) -> Bool
}

/// A key Bottari signs with itself.
struct OfferedPrivateKey<Kind: OfferedKeyKind>: NIOSSHPrivateKeyProtocol {
    static var keyPrefix: String { Kind.name }

    /// The public key blob after its type name.
    let body: Data
    /// Signs `data`, returning the signature blob after its type name.
    let sign: @Sendable (Data) throws -> Data

    var publicKey: NIOSSHPublicKeyProtocol {
        OfferedPublicKey<Kind>(body: body)
    }

    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        OfferedSignature<Kind>(rawRepresentation: try sign(Data(data)))
    }

    var asNIOSSHKey: NIOSSHPrivateKey {
        NIOSSHPrivateKey(custom: self)
    }
}

struct OfferedPublicKey<Kind: OfferedKeyKind>: NIOSSHPublicKeyProtocol {
    static var publicKeyPrefix: String { Kind.name }
    let body: Data

    var rawRepresentation: Data { body }

    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
        Kind.isValid(signature: signature.rawRepresentation, for: Data(data), publicKey: body)
    }

    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeBytes(body)
    }

    /// These types are never registered with NIOSSH, so it never reads one off
    /// the wire; this keeps whatever is left as the body.
    static func read(from buffer: inout ByteBuffer) throws -> Self {
        Self(body: Data(buffer.readBytes(length: buffer.readableBytes) ?? []))
    }
}

struct OfferedSignature<Kind: OfferedKeyKind>: NIOSSHSignatureProtocol {
    static var signaturePrefix: String { Kind.name }
    /// The signature blob after its type name: the raw signature for Ed25519
    /// and RSA, `mpint r, mpint s` for ECDSA.
    let rawRepresentation: Data

    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeSSHString(rawRepresentation)
    }

    static func read(from buffer: inout ByteBuffer) throws -> Self {
        Self(rawRepresentation: try buffer.readSSHString())
    }
}

// MARK: - Kinds

enum Ed25519Kind: OfferedKeyKind {
    static let name = "ssh-ed25519"

    static func isValid(signature: Data, for data: Data, publicKey body: Data) -> Bool {
        var wire = SSHWire(body)
        guard let raw = try? wire.readString(), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return false }
        return key.isValidSignature(signature, for: data)
    }
}

/// RSA signed with SHA-512 (RFC 8332), which OpenSSH 8.8 and later require
/// by default. RFC 8332 keeps `ssh-rsa` as the blob's type, but NIOSSH writes
/// the algorithm name there; OpenSSH reads either name as an RSA key, and a
/// server that does not is offered `ssh-rsa` next.
enum RSASHA512Kind: OfferedKeyKind {
    static let name = "rsa-sha2-512"

    static func isValid(signature: Data, for data: Data, publicKey body: Data) -> Bool {
        RSAKeyBody(body)?.isValid(signature: signature, for: SHA512.hash(data: data)) ?? false
    }
}

/// RSA signed with SHA-256 (RFC 8332), for servers that offer only that one.
enum RSASHA256Kind: OfferedKeyKind {
    static let name = "rsa-sha2-256"

    static func isValid(signature: Data, for data: Data, publicKey body: Data) -> Bool {
        RSAKeyBody(body)?.isValid(signature: signature, for: SHA256.hash(data: data)) ?? false
    }
}

/// RSA signed with SHA-1, for servers older than OpenSSH 7.2.
enum RSASHA1Kind: OfferedKeyKind {
    static let name = "ssh-rsa"

    static func isValid(signature: Data, for data: Data, publicKey body: Data) -> Bool {
        RSAKeyBody(body)?.isValid(signature: signature, for: Insecure.SHA1.hash(data: data)) ?? false
    }
}

enum ECDSAP256Kind: OfferedKeyKind {
    static let name = "ecdsa-sha2-nistp256"

    static func isValid(signature: Data, for data: Data, publicKey body: Data) -> Bool {
        guard let (point, raw) = ECDSAParts(body: body, signature: signature, size: 32),
              let key = try? P256.Signing.PublicKey(x963Representation: point),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: raw) else { return false }
        return key.isValidSignature(signature, for: data)
    }
}

enum ECDSAP384Kind: OfferedKeyKind {
    static let name = "ecdsa-sha2-nistp384"

    static func isValid(signature: Data, for data: Data, publicKey body: Data) -> Bool {
        guard let (point, raw) = ECDSAParts(body: body, signature: signature, size: 48),
              let key = try? P384.Signing.PublicKey(x963Representation: point),
              let signature = try? P384.Signing.ECDSASignature(rawRepresentation: raw) else { return false }
        return key.isValidSignature(signature, for: data)
    }
}

enum ECDSAP521Kind: OfferedKeyKind {
    static let name = "ecdsa-sha2-nistp521"

    static func isValid(signature: Data, for data: Data, publicKey body: Data) -> Bool {
        guard let (point, raw) = ECDSAParts(body: body, signature: signature, size: 66),
              let key = try? P521.Signing.PublicKey(x963Representation: point),
              let signature = try? P521.Signing.ECDSASignature(rawRepresentation: raw) else { return false }
        return key.isValidSignature(signature, for: data)
    }
}

// MARK: - Wire helpers

/// An RSA public key blob after its type name: `mpint e, mpint n`.
struct RSAKeyBody {
    let e: Data
    let n: Data

    init?(_ body: Data) {
        var wire = SSHWire(body)
        guard let e = try? wire.readString(), let n = try? wire.readString() else { return nil }
        self.e = e.mpintMagnitude
        self.n = n.mpintMagnitude
    }

    static func encode(e: Data, n: Data) -> Data {
        var body = Data()
        body.appendSSHString(e.asMPInt)
        body.appendSSHString(n.asMPInt)
        return body
    }

    func isValid(signature: Data, for digest: some Digest) -> Bool {
        guard let key = try? _RSA.Signing.PublicKey(n: n, e: e) else { return false }
        return key.isValidSignature(_RSA.Signing.RSASignature(rawRepresentation: signature), for: digest, padding: .insecurePKCS1v1_5)
    }
}

/// The curve point from an ECDSA public key body (`string curve, string Q`)
/// and `r ‖ s` from a signature blob (`mpint r, mpint s`), each `size` bytes.
private func ECDSAParts(body: Data, signature: Data, size: Int) -> (point: Data, raw: Data)? {
    var key = SSHWire(body)
    var parts = SSHWire(signature)
    guard (try? key.readString()) != nil, let point = try? key.readString(),
          let r = try? parts.readString().mpintMagnitude, let s = try? parts.readString().mpintMagnitude,
          r.count <= size, s.count <= size else { return nil }
    return (point, Data(count: size - r.count) + r + Data(count: size - s.count) + s)
}

extension Data {
    /// An SSH mpint's bytes without the sign byte or leading zeros.
    var mpintMagnitude: Data {
        Data(drop { $0 == 0 })
    }

    /// Unsigned big-endian bytes as an SSH mpint: no leading zeros, plus one
    /// when the top bit is set so the number stays positive.
    var asMPInt: Data {
        let magnitude = mpintMagnitude
        guard let first = magnitude.first else { return Data() }
        return first & 0x80 != 0 ? Data([0]) + magnitude : magnitude
    }
}
