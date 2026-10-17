import Foundation
import MailStore

/// A small, fully known mailbox used across the test suites.
///
/// Accounts: an iCloud-style IMAP account (a child of an "iCloud" parent in
/// the Accounts database), a Gmail-style account whose INBOX is a label on
/// "[Gmail]/All Mail", and "On My Mac".
public struct StandardFixture: Sendable {
    public let store: FixtureMailStore
    public let now: Date

    public static let me = EmailAddress(address: "me@icloud.test", name: "Me Myself")
    public static let alice = EmailAddress(address: "alice@example.test", name: "Alice Martin")
    public static let bob = EmailAddress(address: "bob@example.test", name: "Bob")
    public static let carol = EmailAddress(address: "carol@shop.test", name: "Carol, Billing")
    public static let dan = EmailAddress(address: "dan@example.test", name: "Dan")

    public let icloud = "AAAAAAAA-0000-0000-0000-000000000001"
    public let gmail = "BBBBBBBB-0000-0000-0000-000000000002"
    public let local = "CCCCCCCC-0000-0000-0000-000000000003"

    public var inbox: Int64 = 0, sent: Int64 = 0, archive: Int64 = 0, archive2020: Int64 = 0
    public var trash: Int64 = 0, junk: Int64 = 0, drafts: Int64 = 0
    public var gmailAll: Int64 = 0, gmailInbox: Int64 = 0, gmailSent: Int64 = 0, localOutbox: Int64 = 0

    /// Message ids by name.
    public var ids: [String: Int64] = [:]

    public var location: MailLocation { store.location }

    public static func make(now: Date = Date()) throws -> StandardFixture {
        var f = StandardFixture(store: try FixtureMailStore(), now: now)
        try f.populate()
        return f
    }

    func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    mutating func populate() throws {
        try store.addAccount(id: icloud, description: nil, parentName: "iCloud")
        try store.addAccount(id: gmail, description: "Gmail", username: "me@gmail.test")
        try store.addAccount(id: local, description: "On My Mac")

        inbox = try store.addMailbox(accountID: icloud, path: "INBOX")
        sent = try store.addMailbox(accountID: icloud, path: "Sent Messages")
        archive = try store.addMailbox(accountID: icloud, path: "Archive")
        archive2020 = try store.addMailbox(accountID: icloud, path: "Archive/2020")
        trash = try store.addMailbox(accountID: icloud, path: "Deleted Messages")
        junk = try store.addMailbox(accountID: icloud, path: "Junk")
        drafts = try store.addMailbox(accountID: icloud, path: "Drafts")
        gmailAll = try store.addMailbox(accountID: gmail, path: "[Gmail]/Tous les messages")
        gmailInbox = try store.addMailbox(accountID: gmail, path: "INBOX", source: gmailAll)
        gmailSent = try store.addMailbox(accountID: gmail, path: "[Gmail]/Messages envoyés", source: gmailAll)
        localOutbox = try store.addMailbox(accountID: local, path: "Outbox", scheme: "local")

        let me = Self.me

        var kickoff = FixtureMessage(
            subject: "Project kickoff", from: Self.alice, to: [me], date: daysAgo(1), mailbox: inbox,
            body: "Hi,\nLet's discuss the Kubernetes cluster and the café budget.\nAlice")
        kickoff.attachments = [("report.pdf", "application/pdf", Data("%PDF-1.4 fake report".utf8))]
        kickoff.partial = true
        kickoff.messageID = "kickoff@example.test"
        ids["kickoff"] = try store.addMessage(kickoff)

        var quote = FixtureMessage(
            subject: "Quote request", from: me, to: [Self.bob], date: daysAgo(3), mailbox: sent,
            body: "Bob, could you send a quote for the new site?")
        quote.isRead = true
        quote.conversationID = 5000
        ids["quote"] = try store.addMessage(quote)

        var digest = FixtureMessage(
            subject: "Weekly digest", from: EmailAddress(address: "news@letters.test", name: "Letters"), to: [me],
            date: daysAgo(2), mailbox: inbox, body: "Top stories this week.")
        digest.isList = true
        digest.hasUnsubscribe = true
        digest.category = .promotions
        ids["digest"] = try store.addMessage(digest)

        var invoice = FixtureMessage(
            subject: "Invoice 42", from: Self.carol, to: [me], date: daysAgo(4), mailbox: inbox, body: "",
            html: "<html><head><style>p{color:red}</style></head><body><p>Invoice <b>#42</b> &amp; receipt</p><ul><li>Item one</li><li>Item&nbsp;two</li></ul></body></html>")
        invoice.isRead = true
        invoice.flagColor = .red
        invoice.category = .transactions
        ids["invoice"] = try store.addMessage(invoice)

        var question = FixtureMessage(
            subject: "Contract question", from: me, to: [Self.dan], date: daysAgo(5), mailbox: sent,
            body: "Dan, any update on the contract?")
        question.isRead = true
        question.conversationID = 5001
        question.messageID = "question@icloud.test"
        ids["question"] = try store.addMessage(question)

        var answer = FixtureMessage(
            subject: "Re: Contract question", from: Self.dan, to: [me], date: daysAgo(4.5), mailbox: inbox,
            body: "Yes, signed copy attached soon.\n\nOn Monday, Me wrote:\n> Dan, any update on the contract?")
        answer.conversationID = 5001
        answer.inReplyTo = "question@icloud.test"
        answer.flagColor = .blue
        ids["answer"] = try store.addMessage(answer)

        var spam = FixtureMessage(
            subject: "Old spam", from: EmailAddress(address: "spam@junk.test"), to: [me], date: daysAgo(6), mailbox: trash,
            body: "Buy now")
        ids["spam"] = try store.addMessage(spam)
        spam.mailbox = junk
        spam.subject = "Junk offer"
        ids["junk"] = try store.addMessage(spam)

        var archived = FixtureMessage(
            subject: "Archived thing", from: Self.alice, to: [me],
            date: Date(timeIntervalSince1970: 1_590_000_000), mailbox: archive2020, body: "Un café à Paris, déjà vu.")
        archived.isRead = true
        archived.charset = "iso-8859-1"
        ids["archived"] = try store.addMessage(archived)

        var gmailHello = FixtureMessage(
            subject: "Gmail hello", from: EmailAddress(address: "eve@example.test", name: "Eve"),
            to: [EmailAddress(address: "me@gmail.test")], date: daysAgo(2.5), mailbox: gmailAll, body: "Hello from Gmail")
        gmailHello.labels = [gmailInbox]
        ids["gmail"] = try store.addMessage(gmailHello)

        var receipt = FixtureMessage(
            subject: "Your receipt", from: EmailAddress(address: "no-reply@shop.test", name: "Shop"), to: [me],
            date: daysAgo(1.5), mailbox: inbox, body: "Thanks for your order.")
        ids["receipt"] = try store.addMessage(receipt)
        receipt.subject = "Second sent"
        receipt.from = me
        receipt.to = [Self.alice]
        receipt.mailbox = sent
        receipt.date = daysAgo(20)
        receipt.isRead = true
        ids["sent2"] = try store.addMessage(receipt)

        var pending = FixtureMessage(
            subject: "Not downloaded yet", from: Self.bob, to: [me], date: daysAgo(0.5), mailbox: inbox,
            body: "This body only exists on the server.")
        pending.withoutFile = true
        pending.isRead = true
        ids["pending"] = try store.addMessage(pending)

        var deleted = FixtureMessage(
            subject: "Deleted row", from: Self.bob, to: [me], date: daysAgo(0.2), mailbox: inbox, body: "gone")
        deleted.deleted = true
        ids["deleted"] = try store.addMessage(deleted)

        try store.refreshCounts()
    }

    /// Opens a ``MailStore`` on the fixture.
    public func openStore() throws -> MailStore { try MailStore(location: location) }
}
