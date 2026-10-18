import CoreGraphics
import CoreText
import Foundation
import MailFixtures
import Testing

@testable import MailStore

@Suite("Body index")
final class BodyIndexTests {
    let fixture: StandardFixture
    let store: MailStore
    let index: BodyIndex
    /// Tests never read the Keychain.
    static let key = BodyIndexKey(bytes: Array(0..<16))
    var indexURL: URL { fixture.store.directory.appending(path: "index/body.sqlite") }

    init() throws {
        fixture = try StandardFixture.make()
        store = try fixture.openStore()
        index = try BodyIndex(url: fixture.store.directory.appending(path: "index/body.sqlite"), key: { Self.key })
    }

    deinit { fixture.store.remove() }

    @Test func queryTermsNeutralizeSyntax() {
        typealias Term = BodyIndex.QueryTerm
        #expect(BodyIndex.queryTerms(for: "Kubernetes cluster") == [Term.prefix("kubernetes"), .prefix("cluster")])
        #expect(BodyIndex.queryTerms(for: "say \"hello world\" now") == [Term.prefix("say"), .phrase(["hello", "world"]), .prefix("now")])
        #expect(BodyIndex.queryTerms(for: "NEAR(a b) OR c*") == [Term.prefix("near"), .word("a"), .word("b"), .word("or"), .word("c")])
        #expect(BodyIndex.queryTerms(for: "me@icloud.test") == [Term.phrase(["me", "icloud", "test"])])
        #expect(BodyIndex.queryTerms(for: "\"Café\"") == [Term.word("cafe")])
        #expect(BodyIndex.queryTerms(for: "  ").isEmpty)
    }

    @Test func sipHashMatchesReferenceVector() {
        // Appendix A of the SipHash paper: key 00…0f, message 00…0e.
        let hasher = SipHash24(key: Array(0..<16))
        #expect(hasher.hash(Array(0..<15)) == 0xa129_ca61_49be_45e5)
        #expect(hasher.hash([]) == 0x726f_db47_dd0e_0e31)
    }

    @Test func fileHoldsNoReadableText() throws {
        try index.update(from: store)
        try index.prune(against: store)
        // Nothing the messages say is in the database, its WAL or the FTS shadow tables.
        var bytes = Data()
        for suffix in ["", "-wal"] { bytes.append((try? Data(contentsOf: URL(filePath: indexURL.path + suffix))) ?? Data()) }
        for secret in ["kubernetes", "Kubernetes", "cluster", "carol", "Project kickoff", "server"] {
            #expect(bytes.range(of: Data(secret.utf8)) == nil, "\(secret) found in the index file")
        }
        // Reading the terms back, as one could from contentless FTS5, yields only opaque hashes.
        let db = try SQLiteConnection(path: indexURL.path, readOnly: false)
        try db.execute("CREATE VIRTUAL TABLE temp.terms USING fts5vocab(main, 'body_fts', 'row')")
        let terms = try db.all("SELECT term FROM temp.terms") { $0.string(0) }
        #expect(!terms.isEmpty)
        #expect(terms.allSatisfy { $0.count == 16 && $0.allSatisfy(\.isHexDigit) })
        let permissions = try FileManager.default.attributesOfItem(atPath: indexURL.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    /// A one-page PDF whose text layer says `text`.
    static func pdf(_ text: String) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 12, nil)]))
        context.textPosition = CGPoint(x: 20, y: 100)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    @Test func indexesAttachedPDFsAndTextFiles() throws {
        var message = FixtureMessage(
            subject: "Signed papers", from: StandardFixture.alice, to: [StandardFixture.me], date: Date(), mailbox: fixture.inbox,
            body: "See attached.")
        message.attachments = [
            ("contract.pdf", "application/pdf", Self.pdf("Indemnification clause appendix")),
            ("notes.txt", "text/plain", Data("Escrow arrangements".utf8)),
        ]
        let withFiles = try fixture.store.addMessage(message)
        message.partial = true
        message.attachments = [("stripped.pdf", "application/pdf", Self.pdf("Quarterly forecast"))]
        let stripped = try fixture.store.addMessage(message)
        try index.update(from: store)
        #expect(try index.matchingIDs(for: "indemnification clause", limit: 10) == [withFiles])
        #expect(try index.matchingIDs(for: "escrow", limit: 10) == [withFiles])
        #expect(try index.matchingIDs(for: "forecast", limit: 10) == [stripped])
        let bytes = try Data(contentsOf: indexURL) + ((try? Data(contentsOf: URL(filePath: indexURL.path + "-wal"))) ?? Data())
        #expect(bytes.range(of: Data("ndemnification".utf8)) == nil && bytes.range(of: Data("scrow".utf8)) == nil)
    }

    @Test func olderIndexesReReadMessagesWithAttachments() throws {
        try index.update(from: store)
        let waiting = try index.status().pendingMessages
        try index.queueAttachmentBackfill(from: store)
        // Queued messages are not reported as waiting for download, and the next update takes them.
        #expect(try index.status().pendingMessages == waiting)
        let db = try SQLiteConnection(path: indexURL.path, readOnly: false)
        #expect(try db.scalarInt("SELECT COUNT(*) FROM pending WHERE attempts = 0") == 1)  // the kickoff, with its PDF
        try index.update(from: store, retryAfter: 0)
        #expect(try db.scalarInt("SELECT COUNT(*) FROM pending WHERE attempts = 0") == 0)
    }

    @Test func anotherKeyFindsNothingAndRebuilds() throws {
        try index.update(from: store)
        #expect(!(try index.matchingIDs(for: "kubernetes", limit: 10)).isEmpty)
        let other = try BodyIndex(url: indexURL, key: { BodyIndexKey(bytes: Array(repeating: 7, count: 16)) })
        #expect(try other.matchingIDs(for: "kubernetes", limit: 10).isEmpty)
        #expect(try other.coveredThrough() == 0)
        #expect(try other.status().indexedMessages == 0)
        try other.update(from: store)
        #expect(Set(try other.matchingIDs(for: "kubernetes", limit: 10)) == [fixture.ids["kickoff"]!])
    }

    @Test func plaintextIndexFromVersionOneIsDeleted() throws {
        let url = fixture.store.directory.appending(path: "old/body.sqlite")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            let old = try SQLiteConnection(path: url.path, readOnly: false, create: true)
            try old.execute(
                """
                CREATE TABLE meta (key TEXT PRIMARY KEY, value); INSERT INTO meta VALUES ('schema_version', 1);
                CREATE VIRTUAL TABLE body_fts USING fts5(subject, sender, body, content = '');
                INSERT INTO body_fts (rowid, subject, sender, body) VALUES (1, 'secret', 'x', 'the launch code is hunter2');
                """)
        }
        let upgraded = try BodyIndex(url: url, key: { Self.key })
        #expect(try upgraded.status().indexedMessages == 0)
        let bytes = try Data(contentsOf: url)
        #expect(bytes.range(of: Data("hunter2".utf8)) == nil)
    }

    @Test func buildsAndSearches() throws {
        let result = try index.update(from: store)
        // Every live message with a file is indexed; the not-downloaded one waits.
        #expect(result.indexed == 12)
        #expect(result.pendingAdded == 1)
        #expect(Set(try index.matchingIDs(for: "kubernetes", limit: 10)) == [fixture.ids["kickoff"]!])
        #expect(Set(try index.matchingIDs(for: "cafe", limit: 10)) == [fixture.ids["kickoff"]!, fixture.ids["archived"]!])
        #expect(try index.matchingIDs(for: "\"cluster budget\"", limit: 10).isEmpty)
        #expect(Set(try index.matchingIDs(for: "\"Kubernetes cluster\"", limit: 10)) == [fixture.ids["kickoff"]!])
        // Subject and sender are indexed too.
        #expect(Set(try index.matchingIDs(for: "carol", limit: 10)) == [fixture.ids["invoice"]!])
        // Prefixes expand through the vocabulary; short words match whole.
        #expect(Set(try index.matchingIDs(for: "kube", limit: 10)) == [fixture.ids["kickoff"]!])
        #expect(try index.matchingIDs(for: "kubernetesx", limit: 10).isEmpty)
        #expect(try index.matchingIDs(for: "\"kube\"", limit: 10).isEmpty)

        var query = MessageQuery()
        query.bodyText = "café"
        let page = try store.search(query, bodyIndex: index)
        #expect(page.bodySearchMode == "index")
        #expect(page.messages.map(\.subject).sorted() == ["Archived thing", "Project kickoff"])
        #expect(page.total == 2)
    }

    @Test func newMessagesAreScannedUntilIndexed() throws {
        try index.update(from: store)
        let id = try fixture.store.addMessage(
            FixtureMessage(
                subject: "Late arrival", from: StandardFixture.alice, to: [StandardFixture.me], date: Date(),
                mailbox: fixture.inbox, body: "Kubernetes upgrade notes"))
        var query = MessageQuery()
        query.bodyText = "kubernetes"
        let mixed = try store.search(query, bodyIndex: index)
        #expect(mixed.bodySearchMode == "index+scan")
        #expect(mixed.messages.map(\.id) == [id, fixture.ids["kickoff"]!])
        let update = try index.update(from: store)
        #expect(update.indexed == 1)
        #expect(try store.search(query, bodyIndex: index).bodySearchMode == "index")
    }

    @Test func pendingBodiesAreRetriedAndStaleRowsPruned() throws {
        try index.update(from: store)
        #expect(try index.status().pendingMessages == 1)
        let pendingID = fixture.ids["pending"]!
        var late = FixtureMessage(
            subject: "Not downloaded yet", from: StandardFixture.bob, to: [StandardFixture.me], date: Date(),
            mailbox: fixture.inbox, body: "This body only exists on the server.")
        late.messageID = "late@fixture.test"
        try fixture.store.writeEmlx(rowID: pendingID, mailbox: fixture.inbox, message: late)
        try index.update(from: store, retryAfter: 0)
        #expect(try index.status().pendingMessages == 0)
        #expect(try index.matchingIDs(for: "server", limit: 10) == [pendingID])

        let db = try SQLiteConnection(path: fixture.location.envelopeIndex.path, readOnly: false)
        try db.run("DELETE FROM messages WHERE ROWID = ?", [.int(pendingID)])
        #expect(try index.prune(against: store) == 1)
        #expect(try index.matchingIDs(for: "server", limit: 10).isEmpty)
    }

    @Test func resetClearsEverything() throws {
        try index.update(from: store)
        try index.reset()
        #expect(try index.status().indexedMessages == 0)
        #expect(try index.coveredThrough() == 0)
    }
}
