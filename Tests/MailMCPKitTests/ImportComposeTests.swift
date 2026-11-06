import Foundation
import MCP
import MailAutomation
import MailFixtures
import MailStore
import Testing

@testable import MailMCPKit

/// The import route (issue #2): the server writes the message, Mail imports it, moves it to Drafts, and redirects it.
@Suite("Import route")
final class ImportComposeTests {
    let h: Harness
    /// Sources Mail "imported", newest last.
    let imported = Box<[String]>([])
    /// Mail has not written the imported message's body yet.
    let withoutFile = Box(false)

    init() throws {
        var settings = Harness.sendingAllowed
        settings.importCompose = true
        h = try Harness(settings: settings)
        h.toolbox.importTimeout = 1
        let withoutFile = self.withoutFile
        let lastImport = Box<FixtureMessage?>(nil)
        h.automation.defaultSender = StandardFixture.me.formatted
        let fixture = h.fixture
        let imported = self.imported
        // Mail: the import lands in On My Mac › Import › Apple Mail MCP; a move to Drafts lands there.
        h.automation.onImport = { path in
            let emlx = try String(contentsOf: URL(filePath: path).appending(path: "Messages/1.emlx"), encoding: .utf8)
            imported.value.append(emlx)
            let header = try #require(emlx.split(separator: "\n").first { $0.hasPrefix("Message-Id: <") })
            let box = try fixture.store.addMailbox(accountID: fixture.local, path: "Import/Apple Mail MCP", scheme: "local")
            var message = FixtureMessage(
                subject: "imported", from: StandardFixture.me, to: [], date: fixture.now, mailbox: box, body: "Imported")
            message.messageID = String(header.dropFirst("Message-Id: <".count).dropLast())
            lastImport.value = message
            _ = try fixture.store.addMessage(message)
        }
        h.automation.onMove = { ids, target in
            guard target.path == "Drafts" else { return }
            for id in ids {
                guard let moved = try? fixture.store.moveMessage(id, to: fixture.drafts) else { continue }
                // Mail writes the moved message's file a moment later; `withoutFile` is before that.
                if !withoutFile.value, var message = lastImport.value {
                    message.mailbox = fixture.drafts
                    try? fixture.store.writeEmlx(rowID: moved, mailbox: fixture.drafts, message: message)
                }
            }
        }
    }
    deinit { h.remove() }

    func composes() -> Int { h.automation.calls.filter { if case .compose = $0 { true } else { false } }.count }

    @Test func draftGoesThroughImportAndDrafts() async throws {
        let json = try await h.json(
            "compose_email",
            ["to": ["a@example.com"], "bcc": ["hidden@example.com"], "subject": "Bonjour", "html": "<p>Hi <b>there</b></p>"])
        #expect(json["result"] as? String == "saved to Drafts")
        #expect(json["via"] as? String == "import")
        #expect(json["leftover_mailbox"] as? String == "On My Mac/Import")
        let draftID = try #require((json["draft_id"] as? NSNumber)?.int64Value)
        #expect(try h.toolbox.store.message(id: draftID).mailboxID == h.fixture.drafts)
        #expect(composes() == 0)
        let source = try #require(imported.value.last)
        // A draft keeps its Bcc; Mail's own draft marker and flags are there.
        #expect(source.contains("Bcc: hidden@example.com"))
        #expect(source.contains("X-Uniform-Type-Identifier: com.apple.mail-draft"))
        #expect(source.contains("<integer>\(ImportMailbox.draftFlags)</integer>"))
        #expect(!source.contains("blockquote"))
    }

    @Test func sendRedirectsTheDraftWithoutABccHeader() async throws {
        let json = try await h.json(
            "compose_email",
            ["to": ["a@example.com"], "cc": ["c@example.com"], "bcc": ["hidden@example.com"], "subject": "Hello", "body": "Text",
             "mode": "send"])
        #expect(json["result"] as? String == "sent")
        #expect(json["via"] as? String == "import")
        let redirect = h.automation.calls.compactMap { call -> ([String], [String], [String])? in
            if case .redirect(_, let box, let to, let cc, let bcc) = call, box.path == "Drafts" { (to, cc, bcc) } else { nil }
        }
        #expect(redirect.count == 1)
        #expect(redirect.first?.0 == ["a@example.com"] && redirect.first?.1 == ["c@example.com"] && redirect.first?.2 == ["hidden@example.com"])
        #expect(composes() == 0)
        let source = try #require(imported.value.last)
        #expect(!source.contains("Bcc:"))
        #expect(source.contains("Cc: c@example.com"))
    }

    @Test func noRedirectBeforeMailHasTheBody() async throws {
        withoutFile.value = true
        let (text, isError) = await h.call(
            "compose_email", ["to": ["a@example.com"], "subject": "Hello", "body": "Text", "mode": "send"])
        #expect(isError)
        #expect(text.contains("nothing was sent"))
        #expect(!h.automation.calls.contains { if case .redirect = $0 { true } else { false } })
        #expect(composes() == 0)
    }

    @Test func noKnownSenderFallsBackToCompose() async throws {
        h.automation.defaultSender = nil
        let json = try await h.json("compose_email", ["to": ["a@example.com"], "subject": "Hi", "body": "Text", "mode": "send"])
        #expect(json["via"] == nil)
        #expect(composes() == 1)
        #expect(!h.automation.calls.contains { if case .importMailbox = $0 { true } else { false } })
    }

    @Test func openModeKeepsTheComposeWindow() async throws {
        _ = try await h.json("compose_email", ["to": ["a@example.com"], "subject": "Hi", "body": "Text", "mode": "open"])
        #expect(composes() == 1)
    }

    @Test func settingOffUsesCompose() async throws {
        var settings = Harness.sendingAllowed
        settings.importCompose = false
        try settings.save(to: h.support.appending(path: "settings.json"))
        _ = try await h.json("compose_email", ["to": ["a@example.com"], "subject": "Hi", "body": "Text", "mode": "send"])
        #expect(composes() == 1)
    }
}

@Suite("Message source")
struct MessageSourceTests {
    func source(subject: String = "Hello", html: String? = nil, attachments: [MessageSource.Attachment] = []) -> String {
        let message = MessageSource(
            from: EmailAddress(address: "me@example.com", name: "Mickaël Palma"), to: ["a@example.com", "Bé <b@example.com>"], cc: [],
            bcc: [], subject: subject, text: "Ligne 1\nLigne 2", html: html, attachments: attachments, messageID: "id-1@example.com",
            date: Date(timeIntervalSince1970: 1_793_966_400))
        return String(decoding: message.data(), as: UTF8.self)
    }

    @Test func headersAreEncodedWhenNotAscii() {
        let text = source(subject: "Assurance habitation – infos")
        #expect(text.contains("Subject: =?utf-8?B?"))
        #expect(text.contains("From: =?utf-8?B?") && text.contains("<me@example.com>"))
        #expect(text.contains("To: a@example.com, =?utf-8?B?"))
        #expect(text.contains("Message-Id: <id-1@example.com>"))
        #expect(text.contains("Date: Fri, 6 Nov 2026"))
    }

    @Test func plainTextAloneIsOnePart() {
        let text = source()
        #expect(text.contains("Content-Type: text/plain; charset=utf-8"))
        #expect(!text.contains("multipart"))
        #expect(text.contains(Data("Ligne 1\nLigne 2".utf8).base64EncodedString()))
    }

    @Test func htmlMakesAnAlternativeWithAFullDocument() throws {
        let text = source(html: "<p>Hi</p>")
        #expect(text.contains("multipart/alternative"))
        let htmlPart = try #require(text.components(separatedBy: "Content-Type: text/html; charset=utf-8\nContent-Transfer-Encoding: base64\n\n").last)
        let encoded = htmlPart.prefix { $0 != "-" }.replacingOccurrences(of: "\n", with: "")
        let decoded = String(decoding: try #require(Data(base64Encoded: encoded)), as: UTF8.self)
        #expect(decoded.hasPrefix("<html>") && decoded.contains("<body><p>Hi</p></body>"))
    }

    @Test func attachmentsMakeAMixedMessage() {
        let text = source(attachments: [.init(name: "Facture été.pdf", contentType: "application/pdf", data: Data([1, 2, 3]))])
        #expect(text.contains("multipart/mixed"))
        #expect(text.contains("Content-Disposition: attachment; filename*=utf-8''Facture%20%C3%A9t%C3%A9.pdf"))
        #expect(text.contains("Content-Type: application/pdf; name*=utf-8''"))
        #expect(text.contains(Data([1, 2, 3]).base64EncodedString()))
    }

    @Test func longSubjectsSplitIntoShortEncodedWords() {
        let words = MessageSource.encodedWord(String(repeating: "é", count: 60)).components(separatedBy: "\n ")
        #expect(words.count > 1)
        #expect(words.allSatisfy { $0.count <= 75 })
    }

    @Test func emlxStartsWithTheMessageLength() throws {
        let source = Data("Subject: x\n\nbody\n".utf8)
        let emlx = ImportMailbox.emlx(source, received: Date(timeIntervalSince1970: 0))
        let text = String(decoding: emlx, as: UTF8.self)
        #expect(text.hasPrefix("\(source.count)\nSubject: x"))
        #expect(text.contains("<key>flags</key>\n\t<integer>\(ImportMailbox.draftFlags)</integer>"))
    }

    @Test func settingIsOffByDefaultAndReadFromFile() throws {
        #expect(Settings().importCompose == false)
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(#"{"importCompose": true}"#.utf8))
        #expect(decoded.importCompose)
    }
}

/// A mutable value the Mail stand-in's closures can append to.
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
