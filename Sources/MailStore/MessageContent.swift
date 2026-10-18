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
        if let html {
            if text == nil {
                text = HTMLText.plainText(fromHTML: html)
            } else if let stub = text, isPlaceholder(stub) {
                // "This is an HTML message." and the like: the real content is only in the HTML part.
                let fromHTML = HTMLText.plainText(fromHTML: html)
                if fromHTML.count > stub.count * 2 { text = fromHTML }
            }
        }
        return (text.map(normalizeNewlines), html)
    }

    /// A plain-text part too short to be the message: senders that write only HTML often add a one-line
    /// stub ("This is an HTML message.", "View this email in your browser").
    static func isPlaceholder(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).count < 160
    }

    /// Text used for body search and the full-text index.
    public static func searchableText(_ root: MIMEPart, maxCharacters: Int = 40_000) -> String {
        let body = bodies(root).text ?? ""
        return body.count > maxCharacters ? String(body.prefix(maxCharacters)) : body
    }

    /// Subject without reply/forward prefixes (`Re:`, `Fwd:`, `TR:`, `AW:`…), repeated or not.
    public static func normalizeSubject(_ subject: String) -> String {
        var text = subject.trimmingCharacters(in: .whitespaces)
        let prefixes = ["re:", "fwd:", "fw:", "tr:", "aw:", "wg:", "rv:", "res:", "sv:", "vs:"]
        var changed = true
        while changed {
            changed = false
            for prefix in prefixes where text.lowercased().hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                changed = true
            }
        }
        return text
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
