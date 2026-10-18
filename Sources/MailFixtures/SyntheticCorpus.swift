import Foundation
import MailStore

/// Generates a large, realistic-looking mailbox for scale benchmarks: several
/// accounts and folders, five years of dates, threads, HTML and attachments.
/// Deterministic for a given seed, so runs are comparable.
public enum SyntheticCorpus {
    struct Generator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 33
        }
        mutating func int(_ range: Range<Int>) -> Int { range.lowerBound + Int(next() % UInt64(range.count)) }
        mutating func pick<T>(_ items: [T]) -> T { items[int(0..<items.count)] }
        mutating func chance(_ p: Double) -> Bool { Double(next() % 10_000) / 10_000 < p }
    }

    static let words = """
        project meeting invoice report update budget review release deploy server cluster kubernetes design \
        contract schedule client proposal quarter roadmap sprint ticket bug feature customer support order \
        shipping payment receipt travel flight hotel booking conference agenda notes draft feedback launch \
        marketing analytics revenue forecast hiring interview offer onboarding security incident backup \
        database migration performance latency storage network invoice renewal subscription newsletter \
        café résumé déjà naïve coöperate über straße señor
        """.split(whereSeparator: \.isWhitespace).map(String.init)

    /// Builds a corpus with `messages` messages and returns the fixture (caller removes it).
    public static func make(messages: Int, seed: UInt64 = 42, directory: URL? = nil) throws -> FixtureMailStore {
        var rng = Generator(state: seed)
        let store = try FixtureMailStore(directory: directory)
        let accounts = ["AAAA0000-0000-0000-0000-00000000000A", "BBBB0000-0000-0000-0000-00000000000B"]
        try store.addAccount(id: accounts[0], description: "Work")
        try store.addAccount(id: accounts[1], description: "Personal")
        var mailboxes: [Int64] = []
        var sentBoxes: [Int64] = []
        for account in accounts {
            mailboxes.append(try store.addMailbox(accountID: account, path: "INBOX"))
            sentBoxes.append(try store.addMailbox(accountID: account, path: "Sent Messages"))
            for year in 2021...2025 { mailboxes.append(try store.addMailbox(accountID: account, path: "Archive/\(year)")) }
            mailboxes.append(try store.addMailbox(accountID: account, path: "Projects/Alpha"))
        }
        let me = EmailAddress(address: "me@work.test", name: "Me")
        let senders = (0..<400).map { EmailAddress(address: "person\($0)@\(["example.test", "corp.test", "mail.test", "news.test"][$0 % 4])", name: "Person \($0)") }
        let now = Date()
        var conversation: Int64 = 10_000
        var threadSubjects: [(Int64, String)] = []

        func sentence(_ count: Int, _ rng: inout Generator) -> String {
            (0..<count).map { _ in rng.pick(words) }.joined(separator: " ")
        }

        try store.db.transaction {
            for n in 0..<messages {
                let fromMe = rng.chance(0.12)
                let replying = !threadSubjects.isEmpty && rng.chance(0.3)
                let (conv, subject): (Int64, String)
                if replying {
                    let thread = threadSubjects[rng.int(0..<threadSubjects.count)]
                    conv = thread.0
                    subject = "Re: " + thread.1
                } else {
                    conversation += 1
                    conv = conversation
                    subject = sentence(rng.int(3..<8), &rng).capitalized
                    if threadSubjects.count < 5000 { threadSubjects.append((conv, subject)) }
                }
                let paragraphs = (0..<rng.int(1..<6)).map { _ in sentence(rng.int(20..<80), &rng) }
                var message = FixtureMessage(
                    subject: subject, from: fromMe ? me : rng.pick(senders), to: fromMe ? [rng.pick(senders)] : [me],
                    date: now.addingTimeInterval(-Double(rng.int(0..<(5 * 365 * 86_400)))),
                    mailbox: fromMe ? rng.pick(sentBoxes) : rng.pick(mailboxes), body: paragraphs.joined(separator: "\n\n"))
                if rng.chance(0.4) {
                    message.html = "<html><body>" + paragraphs.map { "<p>\($0)</p>" }.joined() + "</body></html>"
                    if rng.chance(0.5) { message.body = "" }
                }
                if rng.chance(0.08) {
                    message.attachments = [("file-\(n).pdf", "application/pdf", Data(repeating: 0x25, count: rng.int(200..<4000)))]
                    message.partial = rng.chance(0.5)
                }
                message.isRead = rng.chance(0.8)
                if rng.chance(0.03) { message.flagColor = FlagColor(rawValue: rng.int(0..<7)) }
                message.isList = rng.chance(0.15)
                message.category = MailCategory(rawValue: rng.int(0..<4))
                message.conversationID = conv
                try store.addMessage(message)
            }
        }
        try store.refreshCounts()
        return store
    }
}
