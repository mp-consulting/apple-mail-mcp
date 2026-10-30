#if os(macOS)
import AppKit
#endif
import Foundation

/// HTML → RTF for Mail's `content`. Mail turns rich text into a proper multipart HTML email
/// (bold, italics, links, lists, tables, colours), so no clipboard or keystrokes are needed.
public enum RichText {
    /// System font at Mail's default size, unless the HTML sets its own styles.
    static let defaultStyle = """
        <style>body{font-family:-apple-system,"Helvetica Neue",Helvetica,Arial,sans-serif;font-size:13px;line-height:1.4}\
        blockquote{margin:0 0 0 .8ex;border-left:2px solid #c0c0c0;padding-left:1ex;color:#555}</style>
        """

    #if os(macOS)
    /// Converts on the main thread (AppKit's HTML importer requires it).
    @MainActor
    public static func rtf(fromHTML html: String) throws -> Data {
        let document = html.range(of: "<html", options: .caseInsensitive) == nil
            ? "<html><head><meta charset=\"utf-8\">\(defaultStyle)</head><body>\(html)</body></html>"
            : html
        let attributed = try NSAttributedString(
            data: Data(document.utf8),
            options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil)
        return try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }
    #endif

    /// Escapes plain text for embedding in HTML, keeping line breaks.
    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\n", with: "<br>")
    }
}
