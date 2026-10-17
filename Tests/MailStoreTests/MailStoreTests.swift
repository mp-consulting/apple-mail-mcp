import Foundation
import MailFixtures
import Testing

@testable import MailStore

@Suite("Mail store over a fixture")
final class MailStoreTests {
    let fixture: StandardFixture
    let store: MailStore

    init() throws {
        fixture = try StandardFixture.make()
        store = try fixture.openStore()
    }

    deinit { fixture.store.remove() }

    func search(_ configure: (inout MessageQuery) -> Void) throws -> SearchPage {
        var query = MessageQuery()
        query.limit = 100
        configure(&query)
        return try store.search(query)
    }

    func subjects(_ page: SearchPage) -> [String] { page.messages.map(\.subject) }

    // MARK: Accounts and mailboxes

    @Test func accountNamesComeFromTheAccountsDatabase() throws {
        let accounts = try store.accounts()
        #expect(accounts.map(\.name) == ["Gmail", "iCloud", "On My Mac"])
        let icloud = try #require(accounts.first { $0.id == fixture.icloud })
        #expect(icloud.kind == "imap")
        #expect(icloud.emailAddresses == ["me@icloud.test"])  // dominant sender of Sent Messages
        #expect(accounts.first { $0.id == fixture.local }?.kind == "local")
    }

    @Test func resolvesAccountsByNameIDOrAddress() throws {
        #expect(try store.resolveAccount("icloud").id == fixture.icloud)
        #expect(try store.resolveAccount(fixture.gmail.lowercased()).id == fixture.gmail)
        #expect(try store.resolveAccount("me@icloud.test").id == fixture.icloud)
        #expect(throws: MailStoreError.self) { try store.resolveAccount("nope") }
    }

    @Test func mailboxRolesAndLabels() throws {
        let boxes = try store.mailboxes(accountID: fixture.gmail)
        let inbox = try #require(boxes.first { $0.path == "INBOX" })
        #expect(inbox.role == .inbox)
        #expect(inbox.sourceMailboxID == fixture.gmailAll)
        #expect(boxes.first { $0.path == "[Gmail]/Messages envoyés" }?.role == .sent)
        #expect(boxes.first { $0.path == "[Gmail]/Tous les messages" }?.role == .allMail)
    }

    @Test func resolvesMailboxesByPathRoleAndName() throws {
        #expect(try store.resolveMailboxes("Archive/2020").map(\.id) == [fixture.archive2020])
        #expect(Set(try store.resolveMailboxes("inbox").map(\.id)) == [fixture.inbox, fixture.gmailInbox])
        #expect(try store.resolveMailboxes("sent", accountID: fixture.icloud).map(\.id) == [fixture.sent])
        #expect(try store.resolveMailboxes("trash", accountID: fixture.icloud).map(\.id) == [fixture.trash])
        #expect(try store.resolveMailboxes("2020").map(\.id) == [fixture.archive2020])
        #expect(throws: MailStoreError.self) { try store.resolveMailboxes("Nowhere") }
    }

    // MARK: Search

    @Test func defaultSearchExcludesTrashJunkAndDeletedRows() throws {
        let page = try search { _ in }
        let names = subjects(page)
        #expect(!names.contains("Old spam"))
        #expect(!names.contains("Junk offer"))
        #expect(!names.contains("Deleted row"))
        #expect(names.contains("Gmail hello"))
        #expect(page.total == names.count)
        // Newest first.
        #expect(page.messages.map(\.dateReceived) == page.messages.map(\.dateReceived).sorted(by: >))
    }

    @Test func includeTrash() throws {
        let names = subjects(try search { $0.includeTrashAndJunk = true })
        #expect(names.contains("Old spam") && names.contains("Junk offer"))
    }

    @Test func filters() throws {
        #expect(subjects(try search { $0.subjectTerms = ["kickoff", "invoice"] }).sorted() == ["Invoice 42", "Project kickoff"])
        #expect(subjects(try search { $0.sender = "carol@" }) == ["Invoice 42"])
        #expect(subjects(try search { $0.sender = "Alice Mar" }).contains("Project kickoff"))
        #expect(subjects(try search { $0.recipient = "dan@" }) == ["Contract question"])
        #expect(subjects(try search { $0.text = "digest" }) == ["Weekly digest"])
        #expect(subjects(try search { $0.text = "Top stories" }) == ["Weekly digest"])  // Mail's preview snippet
        #expect(subjects(try search { $0.flagColor = .red }) == ["Invoice 42"])
        #expect(Set(subjects(try search { $0.isFlagged = true })) == ["Invoice 42", "Re: Contract question"])
        #expect(subjects(try search { $0.hasAttachments = true }) == ["Project kickoff"])
        #expect(subjects(try search { $0.categories = [.transactions] }) == ["Invoice 42"])
        #expect(subjects(try search { $0.mailboxIDs = [fixture.archive2020] }) == ["Archived thing"])
        #expect(subjects(try search { $0.mailboxIDs = [fixture.gmailInbox] }) == ["Gmail hello"])
        #expect(subjects(try search { $0.accountIDs = [fixture.gmail] }) == ["Gmail hello"])
        let unread = try search { $0.isRead = false; $0.mailboxIDs = [fixture.inbox] }
        #expect(Set(subjects(unread)) == ["Project kickoff", "Weekly digest", "Re: Contract question", "Your receipt"])
        let old = try search { $0.dateTo = Date(timeIntervalSince1970: 1_600_000_000) }
        #expect(subjects(old) == ["Archived thing"])
        let recent = try search { $0.dateFrom = fixture.now.addingTimeInterval(-86_400 * 1.2) }
        #expect(Set(subjects(recent)) == ["Project kickoff", "Not downloaded yet"])
    }

    @Test func likeWildcardsAreLiteral() throws {
        #expect(try search { $0.subjectTerms = ["%"] }.messages.isEmpty)
        #expect(try search { $0.sender = "_" }.messages.isEmpty)
    }

    @Test func pagination() throws {
        let all = try search { $0.mailboxIDs = [fixture.inbox] }
        var query = MessageQuery()
        query.mailboxIDs = [fixture.inbox]
        query.limit = 2
        query.offset = 2
        let page = try store.search(query)
        #expect(page.messages.map(\.id) == Array(all.messages.map(\.id)[2..<4]))
        #expect(page.total == all.total)
        #expect(page.hasMore)
        query.sortAscending = true
        query.offset = 0
        #expect(try store.search(query).messages.first?.id == all.messages.last?.id)
    }

    @Test func summaryFields() throws {
        let invoice = try store.message(id: fixture.ids["invoice"]!)
        #expect(invoice.sender == StandardFixture.carol)
        #expect(invoice.flagColor == .red)
        #expect(invoice.isRead)
        #expect(invoice.accountName == "iCloud")
        #expect(invoice.mailboxPath == "INBOX")
        #expect(invoice.category == .transactions)
        let answer = try store.message(id: fixture.ids["answer"]!)
        #expect(answer.subject == "Re: Contract question")
        #expect(answer.flagColor == .blue)
        let kickoff = try store.message(id: fixture.ids["kickoff"]!)
        #expect(kickoff.messageIDHeader == "kickoff@example.test")
        #expect(kickoff.mailLink == "message://%3Ckickoff@example.test%3E")
        #expect(kickoff.hasAttachments)
        #expect(kickoff.preview?.hasPrefix("Hi, Let's discuss") == true)
        #expect(throws: MailStoreError.self) { try store.message(id: 999_999) }
    }

    // MARK: Content

    @Test func detailOfPlainMessageWithStrippedAttachment() throws {
        let detail = try store.detail(id: fixture.ids["kickoff"]!)
        #expect(detail.bodyAvailable)
        #expect(detail.textBody?.contains("Kubernetes cluster") == true)
        #expect(detail.to == [StandardFixture.me])
        #expect(detail.attachments == [
            AttachmentInfo(partID: "2", filename: "report.pdf", mimeType: "application/pdf", size: 20, isDownloaded: true)
        ])
        let (info, data) = try store.attachmentData(messageID: fixture.ids["kickoff"]!, attachment: "report.pdf")
        #expect(info.partID == "2")
        #expect(data == Data("%PDF-1.4 fake report".utf8))
    }

    @Test func htmlOnlyMessageGetsTextBody() throws {
        let detail = try store.detail(id: fixture.ids["invoice"]!)
        #expect(detail.textBody == "Invoice #42 & receipt\n\n• Item one\n• Item two")
        #expect(detail.htmlBody?.contains("<b>#42</b>") == true)
        #expect(detail.to.first?.address == "me@icloud.test")
    }

    @Test func latin1Body() throws {
        #expect(try store.detail(id: fixture.ids["archived"]!).textBody == "Un café à Paris, déjà vu.")
    }

    @Test func notDownloadedMessageFallsBackToIndex() throws {
        let detail = try store.detail(id: fixture.ids["pending"]!)
        #expect(!detail.bodyAvailable)
        #expect(detail.textBody == nil)
        #expect(detail.to == [StandardFixture.me])
        #expect(throws: MailStoreError.self) { try store.rawSource(id: fixture.ids["pending"]!) }
    }

    @Test func rawSource() throws {
        let source = String(decoding: try store.rawSource(id: fixture.ids["kickoff"]!), as: UTF8.self)
        #expect(source.contains("Message-ID: <kickoff@example.test>"))
        #expect(!source.contains("<?xml"))
    }

    @Test func threadIsOrderedAndDeduplicated() throws {
        let thread = try store.thread(of: fixture.ids["answer"]!)
        #expect(thread.map(\.subject) == ["Contract question", "Re: Contract question"])
    }

    @Test func messagesByHeader() throws {
        let found = try store.messages(messageIDHeaders: ["kickoff@example.test"], mailboxIDs: [fixture.inbox])
        #expect(found.map(\.id) == [fixture.ids["kickoff"]!])
        #expect(try store.messages(messageIDHeaders: ["kickoff@example.test"], mailboxIDs: [fixture.archive]).isEmpty)
    }

    // MARK: Body search without an index

    @Test func bodyScan() throws {
        let page = try search { $0.bodyText = "kubernetes" }
        #expect(subjects(page) == ["Project kickoff"])
        #expect(page.bodySearchMode == "scan")
        #expect(subjects(try search { $0.bodyText = "CAFE A PARIS" }) == ["Archived thing"])
        #expect(subjects(try search { $0.bodyText = "receipt"; $0.mailboxIDs = [fixture.inbox] }).contains("Invoice 42"))
    }

    @Test func bodyScanBudgetIsReported() throws {
        let page = try search { $0.bodyText = "zzz-not-there"; $0.bodyScanBudget = 2 }
        #expect(page.scanLimited)
        #expect(page.total == nil)
        #expect(page.scannedMessages == 2)
        #expect(page.hasMore)
    }

    // MARK: Insights

    @Test func ownAddressesCanBeExtended() throws {
        #expect(try store.ownAddresses() == ["me@icloud.test"])
        store.registerOwnAddresses(["Me@Gmail.test"], accountID: fixture.gmail)
        #expect(try store.ownAddresses() == ["me@icloud.test", "me@gmail.test"])
    }

    @Test func awaitingReplyFindsUnansweredSentMail() throws {
        let waiting = try store.awaitingReply(days: 14, minimumAgeHours: 24)
        // "Quote request" got no answer; "Contract question" was answered by Dan; "Second sent" is 20 days old.
        #expect(waiting.map(\.subject) == ["Quote request"])
        #expect(try store.awaitingReply(days: 30, minimumAgeHours: 24).map(\.subject) == ["Quote request", "Second sent"])
        #expect(try store.awaitingReply(days: 14, minimumAgeHours: 24 * 4).isEmpty)
    }

    @Test func needsResponseSkipsListsNoReplyAndPromotions() throws {
        let needs = try store.needsResponse(days: 7)
        // Kickoff (to me, latest in its conversation) and Dan's answer qualify; digest is a list,
        // the receipt is from no-reply, the invoice is a transaction, the pending one is fine too.
        #expect(Set(needs.map(\.subject)) == ["Project kickoff", "Re: Contract question", "Not downloaded yet"])
        #expect(Set(try store.needsResponse(days: 7, includeRead: false).map(\.subject)) == ["Project kickoff", "Re: Contract question"])
    }

    @Test func statisticsAndTopSenders() throws {
        let stats = try store.statistics(days: 30)
        #expect(stats.received == 10)
        #expect(stats.sentByMe == 3)
        #expect(stats.flagged == 2)
        #expect(stats.withAttachments == 1)
        #expect(stats.categories["promotions"] == 1)
        let senders = try store.topSenders(days: 30, limit: 20)
        #expect(!senders.contains { $0.key == "me@icloud.test" })
        #expect(senders.count == 7)
        #expect(senders.first { $0.key == "alice@example.test" }?.name == "Alice Martin")
        #expect(senders.first { $0.key == "alice@example.test" }?.unread == 1)
        let domains = try store.topSenders(days: 30, byDomain: true, limit: 10)
        #expect(domains.first?.key == "example.test")
    }

    // MARK: Robustness

    @Test func unsupportedSchemaIsDetected() throws {
        let broken = try FixtureMailStore()
        defer { broken.remove() }
        let db = try SQLiteConnection(path: broken.location.envelopeIndex.path, readOnly: false)
        try db.execute("DROP INDEX messages_conversation_id_index; ALTER TABLE messages DROP COLUMN conversation_id")
        #expect {
            _ = try MailStore(location: broken.location)
        } throws: { error in
            guard case MailStoreError.unsupportedSchema(let missing) = error else { return false }
            return missing == ["messages.conversation_id"]
        }
    }

    @Test func storeSeesNewMessagesWithoutReopening() throws {
        let before = try store.search(MessageQuery()).total ?? 0
        try fixture.store.addMessage(
            FixtureMessage(subject: "Fresh", from: StandardFixture.bob, to: [StandardFixture.me], date: Date(), mailbox: fixture.inbox, body: "new"))
        try fixture.store.refreshCounts()
        #expect(try store.search(MessageQuery()).total == before + 1)
        #expect(try store.mailbox(id: fixture.inbox)?.totalCount == 7)
    }
}
