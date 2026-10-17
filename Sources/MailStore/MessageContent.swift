import Foundation

/// Picks readable bodies out of a parsed message.
public enum MessageContent {
    /// The first plain-text and HTML bodies that are not attachments. When a
    /// message only has HTML, `text` is derived from it.
    public static func bodies(_ root: MIMEPart) -> (text: String?, html: String?) {
        var text: String?
        var html: String?
        for leaf in root.leaves where !leaf.isAttachment && leaf.disposition?.type != "attachment" {
            if text == nil, leaf.contentType == "text/plain", leaf.hasInlineData {
                text = leaf.text()
            } else if html == nil, leaf.contentType == "text/html", leaf.hasInlineData {
                html = leaf.text()
            }
            if text != nil && html != nil { break }
        }
        if text == nil, let html { text = HTMLText.plainText(fromHTML: html) }
        return (text.map(normalizeNewlines), html)
    }

    /// Text used for body search and the full-text index.
    public static func searchableText(_ root: MIMEPart, maxCharacters: Int = 40_000) -> String {
        let body = bodies(root).text ?? ""
        return body.count > maxCharacters ? String(body.prefix(maxCharacters)) : body
    }

    static func normalizeNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// Drops quoted history (`>` lines and "On … wrote:" blocks) for compact display.
    public static func stripQuotedReply(_ text: String) -> String {
        var kept: [Substring] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(">") { break }
            if isAttributionLine(trimmed), lines.dropFirst(index + 1).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?
                .trimmingCharacters(in: .whitespaces).hasPrefix(">") ?? true
            {
                break
            }
            if trimmed.hasPrefix("-----Original Message-----") || trimmed.hasPrefix("________________________________") { break }
            kept.append(line)
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isAttributionLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        return (lower.hasPrefix("on ") && lower.hasSuffix("wrote:"))
            || (lower.hasPrefix("le ") && (lower.hasSuffix("a écrit :") || lower.hasSuffix("a écrit:")))
            || (lower.hasPrefix("am ") && lower.hasSuffix("schrieb:"))
            || (lower.hasPrefix("el ") && lower.hasSuffix("escribió:"))
    }
}
