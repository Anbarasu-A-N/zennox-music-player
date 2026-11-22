import Foundation

/// Dependency-free MD5 (RFC 1321). Used only to compare local files with Google Drive's
/// md5Checksum for duplicate detection — never for security.
public struct MD5 {
    private static let s: [UInt32] = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
                                      5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
                                      4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
                                      6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21]
    private static let k: [UInt32] = [
        0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
        0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
        0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
        0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
        0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
        0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
        0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
        0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
    ]

    private var state: [UInt32] = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476]
    private var buffer: [UInt8] = []
    private var length: UInt64 = 0

    public init() {}

    public mutating func update(_ bytes: [UInt8]) {
        length &+= UInt64(bytes.count)
        buffer.append(contentsOf: bytes)
        var offset = 0
        while buffer.count - offset >= 64 { compress(buffer, at: offset); offset += 64 }
        if offset > 0 { buffer.removeFirst(offset) }
    }

    public mutating func finalize() -> [UInt8] {
        let bitLength = length &* 8
        var tail = buffer
        tail.append(0x80)
        while tail.count % 64 != 56 { tail.append(0) }
        for shift in stride(from: 0, to: 64, by: 8) { tail.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift))) }
        var offset = 0
        while offset < tail.count { compress(tail, at: offset); offset += 64 }
        buffer = []
        return state.flatMap { word -> [UInt8] in
            [UInt8(truncatingIfNeeded: word), UInt8(truncatingIfNeeded: word >> 8),
             UInt8(truncatingIfNeeded: word >> 16), UInt8(truncatingIfNeeded: word >> 24)]
        }
    }

    public static func hex(_ bytes: [UInt8]) -> String {
        var hasher = MD5()
        hasher.update(bytes)
        return hasher.finalizeHex()
    }

    public mutating func finalizeHex() -> String {
        finalize().map { byte in
            let s = String(byte, radix: 16)
            return s.count == 1 ? "0" + s : s
        }.joined()
    }

    private mutating func compress(_ block: [UInt8], at offset: Int) {
        var m = [UInt32](repeating: 0, count: 16)
        for i in 0..<16 {
            let j = offset + i * 4
            let b0: UInt32 = UInt32(block[j])
            let b1: UInt32 = UInt32(block[j + 1]) << 8
            let b2: UInt32 = UInt32(block[j + 2]) << 16
            let b3: UInt32 = UInt32(block[j + 3]) << 24
            m[i] = b0 | b1 | b2 | b3
        }
        var a = state[0], b = state[1], c = state[2], d = state[3]
        for i in 0..<64 {
            var f: UInt32
            var g: Int
            switch i {
            case 0..<16: f = (b & c) | (~b & d); g = i
            case 16..<32: f = (d & b) | (~d & c); g = (5 * i + 1) % 16
            case 32..<48: f = b ^ c ^ d; g = (3 * i + 5) % 16
            default: f = c ^ (b | ~d); g = (7 * i) % 16
            }
            f = f &+ a &+ Self.k[i] &+ m[g]
            a = d; d = c; c = b
            b = b &+ ((f << Self.s[i]) | (f >> (32 - Self.s[i])))
        }
        state[0] = state[0] &+ a; state[1] = state[1] &+ b; state[2] = state[2] &+ c; state[3] = state[3] &+ d
    }
}
