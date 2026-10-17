import Foundation

/// Fast HTML → plain text for email bodies. Not a browser: it drops
/// `<head>`/`<style>`/`<script>`, turns block elements into line breaks,
/// decodes entities and collapses whitespace. Works on UTF-8 bytes in one
/// pass, so it is safe off the main thread (unlike `NSAttributedString(html:)`)
/// and runs at memory speed.
public enum HTMLText {
    private static let lineBreakTags: Set<[UInt8]> = Set(
        ["br", "div", "tr", "ul", "ol", "dd", "dt", "pre", "section", "article", "header", "footer", "center"]
            .map { Array($0.utf8) })
    private static let paragraphTags: Set<[UInt8]> = Set(
        ["p", "table", "blockquote", "h1", "h2", "h3", "h4", "h5", "h6", "hr"].map { Array($0.utf8) })
    private static let skippedContentTags: Set<[UInt8]> = Set(
        ["script", "style", "head", "title", "template", "noscript"].map { Array($0.utf8) })

    public static func plainText(fromHTML html: String) -> String {
        var source = html
        return source.withUTF8 { plainText(fromUTF8: $0) }
    }

    public static func plainText(fromUTF8 bytes: UnsafeBufferPointer<UInt8>) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count / 4)
        var trailingNewlines = 0  // newlines at the end of `out`
        var pendingSpace = false
        var i = 0
        let n = bytes.count

        @inline(__always) func emitByte(_ b: UInt8) {
            if pendingSpace, !out.isEmpty, trailingNewlines == 0 { out.append(0x20) }
            pendingSpace = false
            out.append(b)
            trailingNewlines = 0
        }

        func breakLines(_ count: Int) {
            pendingSpace = false
            while out.last == 0x20 { out.removeLast() }
            guard !out.isEmpty else { return }
            while trailingNewlines < count {
                out.append(0x0A)
                trailingNewlines += 1
            }
        }

        func emitScalar(_ value: UInt32) {
            guard let scalar = Unicode.Scalar(value) else { return }
            if scalar == "\u{A0}" || scalar == " " || scalar == "\t" || scalar == "\n" {
                pendingSpace = true
                return
            }
            if value == 0x200B || value == 0x200C || value == 0x200D || value == 0xAD || value == 0xFEFF { return }
            var buffer: [UInt8] = []
            UTF8.encode(scalar) { buffer.append($0) }
            for b in buffer { emitByte(b) }
        }

        func lowercaseASCII(_ b: UInt8) -> UInt8 { (b >= 0x41 && b <= 0x5A) ? b + 32 : b }

        while i < n {
            let b = bytes[i]
            switch b {
            case 0x3C:  // <
                // Comments and doctype.
                if i + 3 < n, bytes[i + 1] == 0x21, bytes[i + 2] == 0x2D, bytes[i + 3] == 0x2D {
                    var j = i + 4
                    while j + 2 < n, !(bytes[j] == 0x2D && bytes[j + 1] == 0x2D && bytes[j + 2] == 0x3E) { j += 1 }
                    i = j + 3
                    continue
                }
                var j = i + 1
                let closing = j < n && bytes[j] == 0x2F
                if closing { j += 1 }
                var name: [UInt8] = []
                while j < n, name.count < 16 {
                    let c = bytes[j]
                    let isAlnum = (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39)
                    guard isAlnum else { break }
                    name.append(lowercaseASCII(c))
                    j += 1
                }
                if name.isEmpty && !closing {
                    // A literal "<" in text.
                    emitByte(b)
                    i += 1
                    continue
                }
                // Find the end of the tag, honouring quoted attribute values.
                var quote: UInt8 = 0
                while j < n {
                    let c = bytes[j]
                    if quote != 0 {
                        if c == quote { quote = 0 }
                    } else if c == 0x22 || c == 0x27 {
                        quote = c
                    } else if c == 0x3E {
                        break
                    }
                    j += 1
                }
                let selfClosing = j > 0 && j - 1 < n && bytes[j - 1] == 0x2F
                i = j + 1
                if !closing && !selfClosing && skippedContentTags.contains(name) {
                    // Skip to the matching close tag.
                    let close = [0x3C, 0x2F] + name
                    var k = i
                    outer: while k + close.count <= n {
                        if bytes[k] == 0x3C {
                            var matches = true
                            for (offset, expected) in close.enumerated() where lowercaseASCII(bytes[k + offset]) != expected {
                                matches = false
                                break
                            }
                            if matches { break outer }
                        }
                        k += 1
                    }
                    while k < n, bytes[k] != 0x3E { k += 1 }
                    i = k + 1
                    continue
                }
                if name == [0x6C, 0x69] {  // li
                    if !closing {
                        breakLines(1)
                        for c in "• ".utf8 { emitByte(c) }
                    }
                } else if name == [0x74, 0x64] || name == [0x74, 0x68] {  // td, th
                    if !closing { pendingSpace = true }
                } else if paragraphTags.contains(name) {
                    breakLines(2)
                } else if lineBreakTags.contains(name) {
                    breakLines(1)
                }
            case 0x26:  // &
                var j = i + 1
                while j < n, j - i <= 10, bytes[j] != 0x3B, bytes[j] != 0x20, bytes[j] != 0x3C { j += 1 }
                if j < n, bytes[j] == 0x3B, j > i + 1, let value = entityValue(bytes, from: i + 1, to: j) {
                    emitScalar(value)
                    i = j + 1
                } else {
                    emitByte(b)
                    i += 1
                }
            case 0x20, 0x09, 0x0A, 0x0D, 0x0C:
                pendingSpace = true
                i += 1
            case 0xC2 where i + 1 < n && bytes[i + 1] == 0xA0:  // U+00A0 no-break space
                pendingSpace = true
                i += 2
            default:
                emitByte(b)
                i += 1
            }
        }
        while let last = out.last, last == 0x0A || last == 0x20 { out.removeLast() }
        return String(decoding: out, as: UTF8.self)
    }

    private static let namedEntities: [String: UInt32] = [
        "amp": 0x26, "lt": 0x3C, "gt": 0x3E, "quot": 0x22, "apos": 0x27, "nbsp": 0xA0, "ensp": 0x20, "emsp": 0x20,
        "thinsp": 0x20, "zwnj": 0x200C, "zwj": 0x200D, "shy": 0xAD, "ndash": 0x2013, "mdash": 0x2014,
        "hellip": 0x2026, "lsquo": 0x2018, "rsquo": 0x2019, "ldquo": 0x201C, "rdquo": 0x201D, "laquo": 0xAB,
        "raquo": 0xBB, "bull": 0x2022, "middot": 0xB7, "copy": 0xA9, "reg": 0xAE, "trade": 0x2122, "euro": 0x20AC,
        "pound": 0xA3, "yen": 0xA5, "cent": 0xA2, "deg": 0xB0, "times": 0xD7, "divide": 0xF7, "eacute": 0xE9,
        "egrave": 0xE8, "ecirc": 0xEA, "euml": 0xEB, "agrave": 0xE0, "aacute": 0xE1, "acirc": 0xE2, "auml": 0xE4,
        "ccedil": 0xE7, "ocirc": 0xF4, "oacute": 0xF3, "ouml": 0xF6, "ucirc": 0xFB, "ugrave": 0xF9, "uacute": 0xFA,
        "uuml": 0xFC, "icirc": 0xEE, "iacute": 0xED, "iuml": 0xEF, "ntilde": 0xF1, "szlig": 0xDF, "Eacute": 0xC9,
        "Egrave": 0xC8, "Agrave": 0xC0, "Ccedil": 0xC7, "rarr": 0x2192, "larr": 0x2190, "check": 0x2713,
    ]

    private static func entityValue(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int) -> UInt32? {
        if bytes[start] == 0x23 {  // #
            var index = start + 1
            var radix: UInt32 = 10
            if index < end, bytes[index] == 0x78 || bytes[index] == 0x58 {
                radix = 16
                index += 1
            }
            var value: UInt32 = 0
            guard index < end else { return nil }
            while index < end {
                let c = bytes[index]
                let digit: UInt32
                switch c {
                case 0x30...0x39: digit = UInt32(c - 0x30)
                case 0x61...0x66 where radix == 16: digit = UInt32(c - 0x61 + 10)
                case 0x41...0x46 where radix == 16: digit = UInt32(c - 0x41 + 10)
                default: return nil
                }
                value = value &* radix &+ digit
                if value > 0x10FFFF { return nil }
                index += 1
            }
            return value
        }
        let name = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<end]), as: UTF8.self)
        return namedEntities[name]
    }

    /// Decodes entities in a plain string (used for header-ish snippets).
    public static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        // Escape tag delimiters so the HTML pass only decodes entities.
        let escaped = text.replacingOccurrences(of: "<", with: "&lt;")
        return plainText(fromHTML: escaped)
    }
}
