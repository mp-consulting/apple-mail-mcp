import Foundation
import MailFixtures
import Testing

@testable import MailStore

@Suite("Body index")
final class BodyIndexTests {
    let fixture: StandardFixture
    let store: MailStore
    let index: BodyIndex

    init() throws {
        fixture = try StandardFixture.make()
        store = try fixture.openStore()
        index = try BodyIndex(url: fixture.store.directory.appending(path: "index/body.sqlite"))
    }

    deinit { fixture.store.remove() }

    @Test func ftsQueryNeutralizesSyntax() {
        #expect(BodyIndex.ftsQuery(for: "kubernetes cluster") == "\"kubernetes\"* \"cluster\"*")
        #expect(BodyIndex.ftsQuery(for: "say \"hello world\" now") == "\"say\"* \"hello world\" \"now\"*")
        #expect(BodyIndex.ftsQuery(for: "NEAR(a b) OR c*") == "\"NEAR\"* \"a\"* \"b\"* \"OR\"* \"c\"*")
        #expect(BodyIndex.ftsQuery(for: "me@icloud.test") == "\"me@icloud.test\"*")
        #expect(BodyIndex.ftsQuery(for: "  ") == nil)
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
