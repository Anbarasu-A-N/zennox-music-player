import Foundation

enum MetadataError: Error { case truncated }

/// Bounds-checked cursor over untrusted bytes. Every read throws instead of trapping.
struct ByteReader {
    let bytes: [UInt8]
    private(set) var offset: Int

    init(_ bytes: [UInt8], offset: Int = 0) {
        self.bytes = bytes
        self.offset = max(0, offset)
    }

    var remaining: Int { max(0, bytes.count - offset) }

    mutating func take(_ count: Int) throws -> [UInt8] {
        guard count >= 0, count <= remaining else { throw MetadataError.truncated }
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }

    mutating func skip(_ count: Int) throws {
        guard count >= 0, count <= remaining else { throw MetadataError.truncated }
        offset += count
    }

    mutating func u8() throws -> UInt8 { try take(1)[0] }

    mutating func u16be() throws -> UInt16 {
        let b = try take(2)
        return (UInt16(b[0]) << 8) | UInt16(b[1])
    }

    mutating func u24be() throws -> UInt32 {
        let b = try take(3)
        return (UInt32(b[0]) << 16) | (UInt32(b[1]) << 8) | UInt32(b[2])
    }

    mutating func u32be() throws -> UInt32 {
        let b = try take(4)
        return (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
    }

    mutating func u16le() throws -> UInt16 {
        let b = try take(2)
        return UInt16(b[0]) | (UInt16(b[1]) << 8)
    }

    mutating func u32le() throws -> UInt32 {
        let b = try take(4)
        return UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
    }

    mutating func fourCC() throws -> String {
        String(decoding: try take(4), as: UTF8.self)
    }
}

extension Array where Element == UInt8 {
    func hasPrefix(_ ascii: String, at index: Int = 0) -> Bool {
        let pattern = Array(ascii.utf8)
        guard index >= 0, index + pattern.count <= count else { return false }
        return Array(self[index..<(index + pattern.count)]) == pattern
    }
}
