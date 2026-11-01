import Foundation
import NIOCore

/// Bytes ended before what the SSH encoding promised.
enum SSHWireError: Error, Equatable {
    case truncated
}

/// Reads the SSH binary encoding: big-endian integers and length-prefixed strings.
struct SSHWire {
    private var data: Data
    private var offset: Data.Index

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    mutating func readByte() throws -> UInt8 {
        guard offset < data.endIndex else { throw SSHWireError.truncated }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readUInt32() throws -> UInt32 {
        guard data.endIndex - offset >= 4 else { throw SSHWireError.truncated }
        let value = data[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        offset += 4
        return value
    }

    /// Everything not read yet.
    var remainder: Data {
        Data(data[offset...])
    }

    mutating func readString() throws -> Data {
        let length = Int(try readUInt32())
        guard data.endIndex - offset >= length else { throw SSHWireError.truncated }
        defer { offset += length }
        return Data(data[offset..<offset + length])
    }
}

extension Data {
    mutating func appendUInt32(_ value: UInt32) {
        append(contentsOf: [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    mutating func appendSSHString(_ bytes: Data) {
        appendUInt32(UInt32(bytes.count))
        append(bytes)
    }
}

extension ByteBuffer {
    @discardableResult
    mutating func writeSSHString(_ bytes: Data) -> Int {
        writeInteger(UInt32(bytes.count)) + writeBytes(bytes)
    }

    mutating func readSSHString() throws -> Data {
        guard let length = readInteger(as: UInt32.self), let bytes = readBytes(length: Int(length)) else {
            throw SSHWireError.truncated
        }
        return Data(bytes)
    }
}
