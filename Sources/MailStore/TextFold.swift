import Foundation

/// Case- and diacritic-insensitive substring search over UTF-8 bytes.
///
/// Folding maps ASCII to lowercase and Latin letters with diacritics
/// (U+00C0–U+024F) to their base letters, then compares bytes. That covers
/// the European languages mail is mostly written in at a fraction of the
/// cost of `String.range(of:options:[.caseInsensitive, .diacriticInsensitive])`.
public enum TextFold {
    /// Folded UTF-8 bytes for U+00C0...U+024F, computed once.
    private static let latinTable: [[UInt8]] = (0xC0...0x24F).map { value in
        guard let scalar = Unicode.Scalar(value) else { return [] }
        let folded = String(Character(scalar)).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return Array(folded.utf8)
    }

    public static func fold(_ text: String) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if value < 0x80 {
                let b = UInt8(value)
                out.append(b >= 0x41 && b <= 0x5A ? b + 32 : b)
            } else if value >= 0xC0 && value <= 0x24F {
                out += latinTable[Int(value) - 0xC0]
            } else if value == 0xA0 {
                out.append(0x20)
            } else {
                UTF8.encode(scalar) { out.append($0) }
            }
        }
        return out
    }

    /// Precompiled needle.
    public struct Pattern: Sendable {
        let bytes: [UInt8]

        public init(_ needle: String) { bytes = TextFold.fold(needle) }

        public var isEmpty: Bool { bytes.isEmpty }

        public func matches(_ haystack: String) -> Bool {
            matches(folded: TextFold.fold(haystack))
        }
    }

    static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        let n = haystack.count, m = needle.count
        guard m > 0 else { return true }
        guard n >= m else { return false }
        return haystack.withUnsafeBufferPointer { h in
            needle.withUnsafeBufferPointer { p in
                memmem(h.baseAddress, n, p.baseAddress, m) != nil
            }
        }
    }
}

extension TextFold.Pattern {
    /// `matches` for text already folded.
    public func matches(folded: [UInt8]) -> Bool {
        bytes.isEmpty || TextFold.contains(folded, bytes)
    }
}
