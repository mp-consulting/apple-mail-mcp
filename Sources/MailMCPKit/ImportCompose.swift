import Foundation
import MailAutomation
import MailStore

#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// The message source the server writes itself, for the import route (``ImportComposer``).
///
/// Mail 16 (macOS 27) puts every body set by scripting (`content`, plain or rich) inside the wrapper it uses for
/// content shared from other apps: `<div class="Apple-Mail-URLShareWrapperClass"><blockquote type="cite">…`, with an
/// empty line above it, and fills the plain-text part with `> ` quotes when it sends. Other mail apps show such a
/// message as a quoted reply (issue #2). A message whose source we write and Mail imports keeps that source.
struct MessageSource {
    var from: EmailAddress
    var to: [String]
    var cc: [String]
    /// Only for a draft: a sent message must not carry its Bcc header (redirect takes the Bcc recipients separately).
    var bcc: [String]
    var subject: String
    var text: String
    var html: String?
    var attachments: [Attachment]
    /// Without angle brackets.
    var messageID: String
    var date: Date

    struct Attachment {
        var name: String
        var contentType: String
        var data: Data
    }

    /// RFC 5322 source with LF line ends, as Mail stores its own `.emlx` files (it sends CRLF): with CRLF, Mail's
    /// Redirect cannot read the message and sends "undefined" (live, 2026-11-06). multipart/alternative (text,
    /// HTML), inside multipart/mixed when there are attachments. Text parts are base64, so no line is too long and
    /// no character needs escaping.
    func data() -> Data {
        var headers = [
            "From: \(Self.address(from))",
            "Subject: \(Self.encodedWord(subject))",
            "Date: \(Self.dateFormatter.string(from: date))",
            "Message-Id: <\(messageID)>",
            "MIME-Version: 1.0",
            // How Mail marks its own drafts.
            "X-Uniform-Type-Identifier: com.apple.mail-draft",
        ]
        if !to.isEmpty { headers.append("To: " + Self.addressList(to)) }
        if !cc.isEmpty { headers.append("Cc: " + Self.addressList(cc)) }
        if !bcc.isEmpty { headers.append("Bcc: " + Self.addressList(bcc)) }

        var body = bodyPart()
        if !attachments.isEmpty {
            let boundary = "Apple-Mail-MCP-mixed-\(UUID().uuidString)"
            var mixed = "Content-Type: multipart/mixed; boundary=\"\(boundary)\"\n\n"
            mixed += "--\(boundary)\n" + body
            for attachment in attachments {
                let name = Self.parameter("filename", attachment.name)
                mixed += "--\(boundary)\n"
                mixed += "Content-Type: \(attachment.contentType); \(Self.parameter("name", attachment.name))\n"
                mixed += "Content-Disposition: attachment; \(name)\n"
                mixed += "Content-Transfer-Encoding: base64\n\n"
                mixed += attachment.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
                mixed += "\n"
            }
            mixed += "--\(boundary)--\n"
            body = mixed
        }
        return Data((headers.joined(separator: "\n") + "\n" + body).utf8)
    }

    /// The headers and body of the text part (with its own Content-Type header first).
    private func bodyPart() -> String {
        guard let html else { return Self.textPart(text, type: "text/plain") }
        let boundary = "Apple-Mail-MCP-alt-\(UUID().uuidString)"
        return "Content-Type: multipart/alternative; boundary=\"\(boundary)\"\n\n"
            + "--\(boundary)\n" + Self.textPart(text, type: "text/plain")
            + "--\(boundary)\n" + Self.textPart(Self.htmlDocument(html), type: "text/html")
            + "--\(boundary)--\n"
    }

    private static func textPart(_ text: String, type: String) -> String {
        "Content-Type: \(type); charset=utf-8\nContent-Transfer-Encoding: base64\n\n"
            + Data(text.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
            + "\n"
    }

    /// A full document, with the system font at Mail's size unless the HTML is a document of its own.
    static func htmlDocument(_ html: String) -> String {
        if html.range(of: "<html", options: .caseInsensitive) != nil { return html }
        return """
            <html><head><meta charset="utf-8"><style>body{font-family:-apple-system,"Helvetica Neue",Helvetica,Arial,\
            sans-serif;font-size:13px;line-height:1.4}</style></head><body>\(html)</body></html>
            """
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return formatter
    }()

    /// RFC 2047 `=?utf-8?B?…?=` when the text is not plain ASCII; split so no encoded word passes 75 characters.
    static func encodedWord(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { !$0.isASCII || $0.value < 0x20 }) else { return text }
        var words: [String] = []
        var chunk = ""
        for character in text {
            // 45 bytes of UTF-8 make 60 base64 characters: with `=?utf-8?B?` and `?=`, 72.
            if Data((chunk + String(character)).utf8).count > 45 {
                words.append("=?utf-8?B?\(Data(chunk.utf8).base64EncodedString())?=")
                chunk = ""
            }
            chunk.append(character)
        }
        if !chunk.isEmpty { words.append("=?utf-8?B?\(Data(chunk.utf8).base64EncodedString())?=") }
        return words.joined(separator: "\n ")
    }

    static func address(_ address: EmailAddress) -> String {
        guard let name = address.name, !name.isEmpty else { return address.address }
        let shown = name.unicodeScalars.allSatisfy(\.isASCII)
            ? "\"\(name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
            : encodedWord(name)
        return "\(shown) <\(address.address)>"
    }

    static func addressList(_ values: [String]) -> String {
        values.map { value in
            let parsed = MIME.parseAddressList(value).first ?? EmailAddress(address: value)
            return address(parsed)
        }.joined(separator: ", ")
    }

    /// `name="file.pdf"`, or RFC 2231 `name*=utf-8''…` for names that are not plain ASCII.
    static func parameter(_ key: String, _ value: String) -> String {
        if value.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 0x20 && $0 != "\"" && $0 != "\\" }) {
            return "\(key)=\"\(value)\""
        }
        let allowed = CharacterSet.alphanumerics.subtracting(.nonBaseCharacters).union(CharacterSet(charactersIn: "!#$&+-.^_`|~"))
        let encoded = Data(value.utf8).map { byte -> String in
            let scalar = Unicode.Scalar(byte)
            return byte < 0x80 && allowed.contains(scalar) ? String(Character(scalar)) : String(format: "%%%02X", byte)
        }.joined()
        return "\(key)*=utf-8''\(encoded)"
    }

    static func contentType(forFile path: String) -> String {
        #if canImport(UniformTypeIdentifiers)
        if let type = UTType(filenameExtension: URL(filePath: path).pathExtension), let mime = type.preferredMIMEType { return mime }
        #endif
        return "application/octet-stream"
    }
}

/// A one-message mailbox in Mail's own format, which `import Mail mailbox` reads with the message's flags.
enum ImportMailbox {
    /// What Mail stores for its own drafts: read (bit 0), draft (bit 6), and bits 16, 17 and 33 as Mail sets them.
    /// The draft bit is what makes Mail open the message as an editable draft once it is in a Drafts mailbox.
    static let draftFlags: Int64 = 0x2_0003_0041

    /// Writes `<directory>/<name>.mbox/Messages/1.emlx` and returns the `.mbox` folder to import.
    static func write(_ source: Data, received: Date, in directory: URL, name: String) throws -> URL {
        let mailbox = directory.appending(path: "\(name).mbox", directoryHint: .isDirectory)
        let messages = mailbox.appending(path: "Messages", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true)
        try emlx(source, received: received).write(to: messages.appending(path: "1.emlx"), options: .atomic)
        return mailbox
    }

    /// `.emlx`: the byte count of the message on its own line, the message, then a property list.
    static func emlx(_ source: Data, received: Date) -> Data {
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
            \t<key>date-received</key>
            \t<integer>\(Int64(received.timeIntervalSince1970))</integer>
            \t<key>flags</key>
            \t<integer>\(draftFlags)</integer>
            </dict>
            </plist>

            """
        return Data("\(source.count)\n".utf8) + source + Data(plist.utf8)
    }
}

/// The import route for new messages, an opt-in setting (``Settings/importCompose``): the server writes the message
/// itself, Mail imports it and moves it to the sending account's Drafts, and sending is Mail's Redirect of that draft.
/// Mail never sets the body, so it never wraps it. The cost: each import leaves an empty "Import" mailbox in On My
/// Mac, which Mail does not let scripts delete.
struct ImportComposer {
    let store: MailStore
    let automation: any MailAutomating
    /// Scratch space for the mailbox folders Mail imports (each removed once imported).
    var directory: URL = FileManager.default.temporaryDirectory.appending(path: "apple-mail-mcp-import", directoryHint: .isDirectory)
    /// How long to wait for Mail's database to show each step.
    var timeout: TimeInterval = 30

    struct Result {
        /// The draft's id (`.draft`); nil once sent.
        var draftID: Int64?
        /// The empty mailbox the import left in On My Mac, for the user to delete.
        var leftover: String?
    }

    /// Why the import route cannot take this message; the caller falls back to the usual compose.
    struct Unavailable: Error, CustomStringConvertible {
        var reason: String
        var description: String { reason }
    }

    func deliver(_ outgoing: OutgoingMessage, mode: DeliveryMode) async throws -> Result {
        precondition(mode != .open, "the import route saves or sends; .open goes through compose")
        // The sender and its account's Drafts mailbox.
        guard let senderText = try await automation.sender(for: outgoing.from),
              let sender = MIME.parseAddressList(senderText).first
        else { throw Unavailable(reason: "Mail did not say which address the message would be sent from.") }
        let account = try store.accounts().first { $0.emailAddresses.contains { $0.caseInsensitiveCompare(sender.address) == .orderedSame } }
        guard let account,
              let drafts = try store.mailboxes(accountID: account.id).first(where: { $0.role == .drafts && $0.sourceMailboxID == nil })
        else { throw Unavailable(reason: "No Drafts mailbox found for \(sender.address).") }

        let attachments = try outgoing.attachments.map { path in
            MessageSource.Attachment(
                name: URL(filePath: path).lastPathComponent, contentType: MessageSource.contentType(forFile: path),
                data: try Data(contentsOf: URL(filePath: path)))
        }
        let now = Date()
        let domain = sender.address.split(separator: "@").last.map(String.init) ?? "localhost"
        let source = MessageSource(
            from: sender, to: outgoing.to, cc: outgoing.cc, bcc: mode == .draft ? outgoing.bcc : [], subject: outgoing.subject,
            text: outgoing.body, html: outgoing.html, attachments: attachments, messageID: "\(UUID().uuidString)@\(domain)", date: now)

        let scratch = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let folder = try ImportMailbox.write(source.data(), received: now, in: scratch, name: "Apple Mail MCP")
        try await automation.importMailbox(at: folder.path)

        // Mail imports into On My Mac › Import[-N] › Apple Mail MCP.
        guard let imported = try await waitFor(source.messageID, where: { MailboxURL($0.url)?.scheme == "local" }) else {
            throw ToolError("Mail did not import the message in time; nothing was sent. Check On My Mac › Import in Mail.")
        }
        let leftover = imported.mailbox.path.split(separator: "/").first.map { "On My Mac/\($0)" }
        let ref = MessageRef(id: imported.message.id, header: source.messageID, subject: imported.message.subject, dateReceived: imported.message.dateReceived)
        _ = try await automation.move([ref], from: MailboxTarget(imported.mailbox), to: MailboxTarget(drafts))
        guard let draft = try await waitFor(source.messageID, where: { $0.id == drafts.id }) else {
            throw ToolError("Mail did not move the message to \(drafts.path) in time; nothing was sent. It is in \(leftover ?? "On My Mac") in Mail.")
        }
        guard mode == .send else { return Result(draftID: draft.message.id, leftover: leftover) }
        // Mail lists the moved draft before it has written its body to disk, and a redirect then sends text/plain
        // "undefined" (live, 2026-11-06: the file came 3 s after the send). Redirect only once the body is there.
        guard try await waitForBody(draft.message.id) else {
            throw ToolError(
                "Mail has not stored the draft's body yet, so nothing was sent. The message is in \(drafts.path) (id \(draft.message.id)); send it from Mail or try send_draft.")
        }
        try await automation.redirect(draft.message.id, in: MailboxTarget(drafts), to: outgoing.to, cc: outgoing.cc, bcc: outgoing.bcc)
        return Result(draftID: nil, leftover: leftover)
    }

    /// Waits until Mail has the message's file on disk, then a second more for Mail to finish with it.
    private func waitForBody(_ id: Int64) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if (try? store.detail(id: id).bodyAvailable) == true {
                try await Task.sleep(for: .seconds(1))
                return true
            }
            try await Task.sleep(for: .milliseconds(500))
        } while Date() < deadline
        return false
    }

    /// Polls Mail's database for the message with this Message-ID in a mailbox `matching` accepts.
    private func waitFor(_ messageID: String, where matching: (Mailbox) -> Bool) async throws -> (message: MessageSummary, mailbox: Mailbox)? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let boxes = try store.mailboxes().filter(matching)
            if !boxes.isEmpty, let found = try store.messages(messageIDHeaders: [messageID], mailboxIDs: boxes.map(\.id)).first,
               let box = boxes.first(where: { $0.id == found.mailboxID })
            {
                return (found, box)
            }
            try await Task.sleep(for: .milliseconds(500))
        } while Date() < deadline
        return nil
    }
}
