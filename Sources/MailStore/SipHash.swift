/// SipHash-2-4 (Aumasson & Bernstein): a fast keyed PRF with a 128-bit key and 64-bit output.
/// The body index uses it to turn words into opaque tokens that mean nothing without the key.
struct SipHash24: Sendable {
    private let k0: UInt64
    private let k1: UInt64

    /// `key` must be 16 bytes.
    init(key: [UInt8]) {
        precondition(key.count == 16, "SipHash needs a 16-byte key")
        k0 = Self.load(key, 0)
        k1 = Self.load(key, 8)
    }

    private static func load(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 { value |= UInt64(bytes[offset + index]) << (8 * UInt64(index)) }
        return value
    }

    func hash(_ data: some Collection<UInt8>) -> UInt64 {
        var v0: UInt64 = 0x736f_6d65_7073_6575 ^ k0
        var v1: UInt64 = 0x646f_7261_6e64_6f6d ^ k1
        var v2: UInt64 = 0x6c79_6765_6e65_7261 ^ k0
        var v3: UInt64 = 0x7465_6462_7974_6573 ^ k1

        @inline(__always) func round() {
            v0 &+= v1; v1 = (v1 << 13) | (v1 >> 51); v1 ^= v0; v0 = (v0 << 32) | (v0 >> 32)
            v2 &+= v3; v3 = (v3 << 16) | (v3 >> 48); v3 ^= v2
            v0 &+= v3; v3 = (v3 << 21) | (v3 >> 43); v3 ^= v0
            v2 &+= v1; v1 = (v1 << 17) | (v1 >> 47); v1 ^= v2; v2 = (v2 << 32) | (v2 >> 32)
        }
        @inline(__always) func compress(_ m: UInt64) {
            v3 ^= m
            round(); round()
            v0 ^= m
        }

        var word: UInt64 = 0
        var filled: UInt64 = 0
        for byte in data {
            word |= UInt64(byte) << (8 * filled)
            filled += 1
            if filled == 8 {
                compress(word)
                word = 0
                filled = 0
            }
        }
        let length = UInt64(truncatingIfNeeded: data.count)
        compress(word | (length << 56))
        v2 ^= 0xff
        round(); round(); round(); round()
        return v0 ^ v1 ^ v2 ^ v3
    }
}
