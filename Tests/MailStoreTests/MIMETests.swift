import Foundation
import Testing

@testable import MailStore

@Suite("MIME parsing")
struct MIMETests {
    func parse(_ text: String) -> MIMEPart { MIME.parse(Data(text.utf8)) }

    @Test func singlePartPlainText() {
        let part = parse("Subject: Hi\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nHello there\r\n")
        #expect(part.contentType == "text/plain")
        #expect(part.partID == "1")
        #expect(part.text() == "Hello there\r\n")
        #expect(part.headers["subject"] == "Hi")
    }

    @Test func missingContentTypeDefaultsToPlainText() {
        let part = parse("From: a@b.c\n\nbody")
        #expect(part.contentType == "text/plain")
        #expect(MessageContent.bodies(part).text == "body")
    }

    @Test func foldedHeadersAreUnfolded() {
        let part = parse("Content-Type: multipart/alternative;\n boundary=\"xyz\"; charset=UTF-8\nSubject: a\n\tb\n\n--xyz\nContent-Type: text/plain\n\none\n--xyz--\n")
        #expect(part.parameters["boundary"] == "xyz")
        #expect(part.headers["Subject"] == "a b")
        #expect(part.children.count == 1)
    }

    @Test func nestedMultipartUsesIMAPPartNumbers() {
        let message = """
            Content-Type: multipart/mixed; boundary="outer"

            preamble
            --outer
            Content-Type: multipart/alternative; boundary="inner"

            --inner
            Content-Type: text/plain

            plain body
            --inner
            Content-Type: text/html

            <p>html body</p>
            --inner--
            --outer
            Content-Type: application/pdf; name="a.pdf"
            Content-Disposition: attachment; filename="a.pdf"
            Content-Transfer-Encoding: base64

            JVBERi0xLjQ=
            --outer--
            epilogue
            """
        let root = parse(message)
        #expect(root.children.map(\.partID) == ["1", "2"])
        #expect(root.children[0].children.map(\.partID) == ["1.1", "1.2"])
        let attachment = root.leaves.first { $0.isAttachment }
        #expect(attachment?.partID == "2")
        #expect(attachment?.filename == "a.pdf")
        #expect(attachment?.decodedBody() == Data("%PDF-1.4".utf8))
        let bodies = MessageContent.bodies(root)
        #expect(bodies.text == "plain body")
        #expect(bodies.html == "<p>html body</p>")
    }

    @Test func boundaryPrefixIsNotADelimiter() {
        let message = "Content-Type: multipart/mixed; boundary=\"b\"\n\n--b\nContent-Type: text/plain\n\nline with --bogus\n--bx not a delimiter\n--b--\n"
        let root = parse(message)
        #expect(root.children.count == 1)
        #expect(root.children[0].text().contains("--bx not a delimiter"))
    }

    @Test func quotedPrintableSoftBreaksAndBytes() {
        let decoded = MIME.decodeQuotedPrintable(Data("caf=C3=A9 au=\r\n lait=  \nend=3D".utf8))
        #expect(String(data: decoded, encoding: .utf8) == "café au laitend=")
    }

    @Test func base64ToleratesWhitespaceAndMissingPadding() {
        #expect(MIME.decodeBase64(Data("SGVs\r\nbG8".utf8)) == Data("Hello".utf8))
    }

    @Test func latin1Charset() {
        var raw = Data("Content-Type: text/plain; charset=iso-8859-1\nContent-Transfer-Encoding: 8bit\n\n".utf8)
        raw.append(contentsOf: [0x63, 0x61, 0x66, 0xE9])  // "café" in Latin-1
        #expect(MIME.parse(raw).text() == "café")
    }

    @Test func unknownCharsetFallsBackToUTF8() {
        #expect(MIME.decodeText(Data("héllo".utf8), charset: "x-made-up") == "héllo")
    }

    @Test func encodedWordsBase64AndQ() {
        #expect(MIME.decodeEncodedWords("=?UTF-8?B?Q2Fmw6k=?= time") == "Café time")
        #expect(MIME.decodeEncodedWords("=?iso-8859-1?Q?Caf=E9_cr=E8me?=") == "Café crème")
        // Whitespace between adjacent encoded words disappears.
        #expect(MIME.decodeEncodedWords("=?utf-8?Q?a?= =?utf-8?Q?b?=") == "ab")
        #expect(MIME.decodeEncodedWords("plain =?bogus") == "plain =?bogus")
    }

    @Test func rfc2231Parameters() {
        let (value, parameters) = MIME.parseParameterizedValue(
            "attachment; filename*=UTF-8''r%C3%A9sum%C3%A9.pdf; size=12")
        #expect(value == "attachment")
        #expect(parameters["filename"] == "résumé.pdf")
        let (_, continued) = MIME.parseParameterizedValue("attachment; filename*0=\"long \"; filename*1=\"name.txt\"")
        #expect(continued["filename"] == "long name.txt")
    }

    @Test func addressLists() {
        let list = MIME.parseAddressList("\"Doe, Jane\" <jane@x.test>, bob@y.test (Bob B), =?utf-8?B?w4l2ZQ==?= <eve@z.test>; bad")
        #expect(list == [
            EmailAddress(address: "jane@x.test", name: "Doe, Jane"),
            EmailAddress(address: "bob@y.test", name: "Bob B"),
            EmailAddress(address: "eve@z.test", name: "Éve"),
        ])
    }

    @Test func strippedAttachmentHasNoInlineData() {
        let message = "Content-Type: multipart/mixed; boundary=\"m\"\r\n\r\n--m\r\nContent-Type: text/plain\r\n\r\nhi\r\n--m\r\nContent-Type: image/png; name=x.png\r\nContent-Disposition: INLINE; filename=x.png\r\nX-Apple-Content-Length: 42\r\n\r\n\r\n--m--\r\n"
        let part = parse(message).leaves[1]
        #expect(part.isAttachment)
        #expect(!part.hasInlineData)
        #expect(part.appleContentLength == 42)
    }
}

@Suite("Body selection")
struct BodySelectionTests {
    func message(text: String, html: String) -> MIMEPart {
        let raw = """
            Content-Type: multipart/alternative; boundary="b"\r
            \r
            --b\r
            Content-Type: text/plain; charset=utf-8\r
            \r
            \(text)\r
            --b\r
            Content-Type: text/html; charset=utf-8\r
            \r
            \(html)\r
            --b--\r
            """
        return MIME.parse(Data(raw.utf8))
    }

    @Test func htmlWinsOverAStubTextPart() {
        let html = "<html><body><p>Bonjour,</p><p>Le montant de votre facture est de 38,26&euro; TTC.</p><p>Il sera prélevé le 25/02.</p></body></html>"
        let bodies = MessageContent.bodies(message(text: "This is an HTML message.", html: html))
        #expect(bodies.text?.contains("38,26€ TTC") == true)
        #expect(InvoiceExtractor.extract(text: bodies.text ?? "").total == "38.26")
    }

    @Test func realTextPartsAreKept() {
        let text = "Hi Alice,\nThe plain version of this note is the one I wrote, and it is long enough to be the real body of the message, so it stays.\nBob"
        let bodies = MessageContent.bodies(message(text: text, html: "<p>Formatted copy with <b>more</b> markup and a footer and more words than the text part has in it, honestly</p>"))
        #expect(bodies.text?.hasPrefix("Hi Alice") == true)
        // A short real reply stays when the HTML says no more than it does.
        let short = MessageContent.bodies(message(text: "Yes, Thursday works.", html: "<p>Yes, Thursday works.</p>"))
        #expect(short.text == "Yes, Thursday works.")
    }
}

@Suite("HTML to text and folding")
struct HTMLTextTests {
    @Test func blocksEntitiesAndSkippedContent() {
        let html = """
            <html><head><title>T</title><style>p { color: red }</style></head>
            <body><p>Hello&nbsp;<b>world</b> &amp; friends</p><div>Line two<br>Line three</div>
            <script>alert('x')</script><ul><li>One</li><li>Two &#8211; &#x2014;</li></ul>
            <!-- comment --><p>5 &lt; 6 &unknown; end</p></body></html>
            """
        let text = HTMLText.plainText(fromHTML: html)
        #expect(text == "Hello world & friends\n\nLine two\nLine three\n• One\n• Two – —\n\n5 < 6 &unknown; end")
    }

    @Test func attributesWithAngleBracketsInQuotes() {
        #expect(HTMLText.plainText(fromHTML: "<a title=\"a > b\" href='x'>link</a> text") == "link text")
    }

    @Test func tablesSeparateCells() {
        #expect(HTMLText.plainText(fromHTML: "<table><tr><td>a</td><td>b</td></tr><tr><td>c</td></tr></table>") == "a b\nc")
    }

    @Test func foldingIsCaseAndDiacriticInsensitive() {
        let pattern = TextFold.Pattern("Cafe CREME")
        #expect(pattern.matches("un café crème, s'il vous plaît"))
        #expect(!pattern.matches("cafe noir"))
        #expect(TextFold.Pattern("Ærø").matches("aerø") || TextFold.Pattern("Ærø").matches("ærø"))
        #expect(TextFold.Pattern("").matches("anything"))
    }
}

@Suite("Files and mailbox URLs")
struct FileLayoutTests {
    @Test func dataSubpathReversesThousands() {
        #expect(MessageFileLocator.dataSubpath(forRowID: 7) == "Data")
        #expect(MessageFileLocator.dataSubpath(forRowID: 999) == "Data")
        #expect(MessageFileLocator.dataSubpath(forRowID: 1000) == "Data/1")
        #expect(MessageFileLocator.dataSubpath(forRowID: 95246) == "Data/5/9")
        #expect(MessageFileLocator.dataSubpath(forRowID: 142529) == "Data/2/4/1")
    }

    @Test func emlxExtractsCountedMessage() {
        let data = Data("12\nHello world!<?xml plist?>".utf8)
        let file = EmlxFile(url: URL(filePath: "/tmp/1.partial.emlx"), data: data)
        #expect(String(data: file.message, encoding: .utf8) == "Hello world!")
        #expect(file.isPartial)
    }

    @Test func mailboxURLDecodesToPrecomposedPath() throws {
        let url = try #require(MailboxURL("imap://ED90311D/%5BGmail%5D/Messages%20envoye%CC%81s"))
        #expect(url.accountID == "ED90311D")
        #expect(url.path == "[Gmail]/Messages envoyés")
        #expect(url.path == "[Gmail]/Messages envoy\u{E9}s")
        #expect(url.relativeDirectory == "ED90311D/[Gmail].mbox/Messages envoyés.mbox")
        #expect(MailboxRoleDetector.role(for: url) == .sent)
    }

    @Test func roleDetection() throws {
        func role(_ s: String) throws -> MailboxRole { MailboxRoleDetector.role(for: try #require(MailboxURL(s))) }
        #expect(try role("imap://A/INBOX") == .inbox)
        #expect(try role("imap://A/Sent%20Messages") == .sent)
        #expect(try role("imap://A/Deleted%20Messages") == .trash)
        #expect(try role("local://A/Deleted%20Messages%20(me%40x.test)") == .trash)
        #expect(try role("imap://A/Archive/2020") == .archive)
        #expect(try role("imap://A/Projects/Sent") == .other)
        #expect(try role("imap://A/%5BGmail%5D/Spam") == .junk)
        #expect(try role("ews://A/Courrier%20ind%C3%A9sirable") == .junk)
    }

    @Test func emlxSurvivesCorruptLengthLine() {
        let huge = Data("\(Int.max)\nHello".utf8)
        #expect(EmlxFile(url: URL(filePath: "/tmp/1.emlx"), data: huge).message == Data("Hello".utf8))
        let short = Data("99\nHi".utf8)
        #expect(EmlxFile(url: URL(filePath: "/tmp/1.emlx"), data: short).message == Data("Hi".utf8))
    }

    @Test func mailboxNamesCannotLeaveMailsFolder() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "locator-\(UUID().uuidString)")
        let outside = root.deletingLastPathComponent().appending(path: "x.mbox/" + UUID().uuidString + "/Data")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside.deletingLastPathComponent().deletingLastPathComponent())
        }
        let locator = MessageFileLocator(root: root)
        let escaping = try #require(MailboxURL("imap://A/%2E%2E%2F%2E%2E%2Fx"))
        #expect(locator.storeDirectories(for: escaping).isEmpty)
        let inbox = try #require(MailboxURL("imap://A/INBOX"))
        #expect(locator.attachmentFile(rowID: 1, mailbox: inbox, partID: "../../x") == nil)
        #expect(MessageFileLocator.isInside(root.path + "/A/INBOX.mbox", root: root.path))
        #expect(!MessageFileLocator.isInside(root.path + "-other/A", root: root.path))
    }

    @Test func statementCacheEvictionKeepsRunningStatements() throws {
        let db = try SQLiteConnection(path: ":memory:", readOnly: false, create: true)
        try db.execute("CREATE TABLE t (v INTEGER); INSERT INTO t VALUES (1), (2), (3);")
        var seen: [Int64] = []
        // Each row runs 150 distinct statements, overflowing the cache while the outer one steps.
        try db.query("SELECT v FROM t ORDER BY v") { row in
            seen.append(row.int(0))
            for n in 0..<150 { _ = try db.scalarInt("SELECT \(n) + \(row.int(0) * 1000)") }
        }
        #expect(seen == [1, 2, 3])
    }

    @Test func likePatternEscapes() {
        #expect(SQLiteConnection.likePattern(containing: "50%_off\\") == "%50\\%\\_off\\\\%")
    }
}
