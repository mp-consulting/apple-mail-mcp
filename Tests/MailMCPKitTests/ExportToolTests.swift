import AppKit
import CoreText
import Foundation
import MCP
import MailFixtures
import MailStore
import Testing

@testable import MailMCPKit

@Suite("Bulk search, export and invoices")
final class ExportToolTests {
    let h: Harness
    let out: URL

    init() throws {
        h = try Harness(settings: { var s = Settings(); s.ownNames = ["Carol"]; return s }())
        out = h.support.appending(path: "exports")
    }
    deinit { h.remove() }

    func ids(_ json: [String: Any]) -> Set<Int64> {
        Set((json["messages"] as? [[String: Any]] ?? []).compactMap { ($0["id"] as? Int).map(Int64.init) })
    }

    func search(_ arguments: [String: Value]) async throws -> Set<Int64> {
        ids(try await h.json("search_messages", arguments.merging(["limit": 200]) { a, _ in a }))
    }

    // MARK: Filters

    @Test func queryTermsAreAlternatives() async throws {
        let found = try await search(["query": "kickoff, your receipt"])
        #expect(found == [h.id("kickoff"), h.id("receipt")])
    }

    @Test func exclusionsRemoveSubjectsSendersAndReplies() async throws {
        let found = try await search(["query": "receipt, invoice", "exclude_subject": "your receipt"])
        #expect(found.contains(h.id("invoice")) && !found.contains(h.id("receipt")))
        let inbox = try await search(["mailbox": "inbox", "exclude_sender": "shop.test, Letters"])
        #expect(!inbox.contains(h.id("invoice")) && !inbox.contains(h.id("receipt")) && !inbox.contains(h.id("digest")))
        #expect(inbox.contains(h.id("kickoff")))
        let noReplies = try await search(["mailbox": "inbox", "exclude_replies": true])
        #expect(!noReplies.contains(h.id("answer")) && noReplies.contains(h.id("kickoff")))
    }

    @Test func directionSeparatesSentFromReceived() async throws {
        let sent = try await search(["direction": "sent"])
        #expect(sent == [h.id("quote"), h.id("question"), h.id("sent2")])
        let received = try await search(["direction": "received"])
        #expect(received.isDisjoint(with: sent) && received.contains(h.id("kickoff")) && received.contains(h.id("gmail")))
        let bad = await h.call("search_messages", ["direction": "sideways"])
        #expect(bad.isError)
    }

    @Test func excludeFromSelfUsesOwnNames() async throws {
        let found = try await search(["mailbox": "inbox", "exclude_from_self": true])
        #expect(!found.contains(h.id("invoice")))  // "Carol, Billing" matches the own name "Carol"
        #expect(found.contains(h.id("kickoff")))
    }

    @Test func severalCategories() async throws {
        #expect(try await search(["category": "transactions, promotions"]) == [h.id("invoice"), h.id("digest")])
        #expect(await h.call("search_messages", ["category": "bills"]).isError)
    }

    @Test func compactResultsCarryLinksWithoutPreviews() async throws {
        let full = try await h.json("search_messages", ["query": "kickoff"])
        let first = (full["messages"] as? [[String: Any]])?.first
        #expect((first?["link"] as? String)?.hasPrefix("message://") == true)
        #expect(first?["preview"] != nil)
        let compact = try await h.json("search_messages", ["query": "kickoff", "compact": true])
        #expect((compact["messages"] as? [[String: Any]])?.first?["preview"] == nil)
    }

    @Test func groupBySenderDomainAndMonth() async throws {
        let bySender = try await h.json("search_messages", ["mailbox": "inbox", "group_by": "sender"])
        let groups = bySender["groups"] as? [[String: Any]] ?? []
        #expect(groups.first { $0["key"] as? String == "alice@example.test" }?["count"] as? Int == 1)
        let byDomain = try await h.json("search_messages", ["group_by": "domain", "body": "café"])
        #expect((byDomain["groups"] as? [[String: Any]])?.first?["key"] as? String == "example.test")
        let byMonth = try await h.json("search_messages", ["group_by": "month"])
        #expect(((byMonth["groups"] as? [[String: Any]])?.first?["key"] as? String)?.count == 7)
    }

    @Test func previewsLoseInvisiblePadding() {
        #expect(Render.cleanPreview("Receipt\u{200C}\u{200C} \u{034F} \u{00AD}from\n\nStripe") == "Receipt from Stripe")
    }

    // MARK: Export

    @Test func exportsCSVWithoutRunnableFormulas() async throws {
        var evil = FixtureMessage(
            subject: "=HYPERLINK(\"http://x.test\",\"Click\")", from: EmailAddress(address: "x@evil.test", name: "@SUM(A1)"),
            to: [StandardFixture.me], date: Date(), mailbox: h.fixture.inbox, body: "hi")
        evil.messageID = "evil@evil.test"
        _ = try h.fixture.store.addMessage(evil)
        let json = try await h.json("export_search", ["mailbox": "inbox", "path": .string(out.appending(path: "inbox.csv").path)])
        let path = try #require(json["path"] as? String)
        let bytes = try Data(contentsOf: URL(filePath: path))
        #expect(bytes.prefix(3) == Data([0xEF, 0xBB, 0xBF]))  // BOM, so Excel reads UTF-8
        let text = String(decoding: bytes.dropFirst(3), as: UTF8.self)
        #expect(text.hasPrefix("date,from_name,from_address,subject"))
        #expect(text.contains("\"'=HYPERLINK(\"\"http://x.test\"\",\"\"Click\"\")\""))
        #expect(text.contains(",'@SUM(A1),"))
        let total = try await h.json("search_messages", ["mailbox": "inbox", "limit": 1])["total"] as? Int
        #expect(json["rows"] as? Int == total)
        #expect(text.components(separatedBy: "\r\n").filter { !$0.isEmpty }.count == (total ?? 0) + 1)
    }

    @Test func exportKeepsTheFormatsExtensionAndRespectsThePathGuard() async throws {
        let json = try await h.json("export_search", ["mailbox": "inbox", "path": .string(out.appending(path: "run.command").path)])
        #expect((json["path"] as? String)?.hasSuffix("run.command.csv") == true)
        let again = try await h.json("export_search", ["mailbox": "inbox", "path": .string(out.appending(path: "run.command").path)])
        #expect((again["path"] as? String)?.hasSuffix("run.command 2.csv") == true)
        let refused = await h.call("export_search", ["path": "/etc/mail.csv"])
        #expect(refused.isError && refused.text.contains("protected location"))
    }

    @Test func exportDedupesCopiesAcrossMailboxes() async throws {
        var copy = FixtureMessage(
            subject: "Statement October", from: StandardFixture.carol, to: [StandardFixture.me], date: Date(),
            mailbox: h.fixture.inbox, body: "Total: 10,00 €")
        copy.messageID = "statement@shop.test"
        _ = try h.fixture.store.addMessage(copy)
        copy.mailbox = h.fixture.archive
        _ = try h.fixture.store.addMessage(copy)
        let path = out.appending(path: "statements.json").path
        let deduped = try await h.json("export_search", ["subject": "statement", "path": .string(path)])
        #expect(deduped["rows"] as? Int == 1 && deduped["duplicates_skipped"] as? Int == 1)
        let all = try await h.json("export_search", ["subject": "statement", "path": .string(path), "dedupe": false])
        #expect(all["rows"] as? Int == 2)
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(filePath: try #require(all["path"] as? String)))) as? [[String: Any]]
        #expect(rows?.first?["subject"] as? String == "Statement October")
    }

    @Test func exportsXLSXWithAmounts() async throws {
        var bill = FixtureMessage(
            subject: "Votre facture", from: EmailAddress(address: "factures@telecom.test", name: "Telecom"),
            to: [StandardFixture.me], date: Date(), mailbox: h.fixture.inbox, body: "Facture n° F-77\nMontant TTC : 25,99 €")
        bill.messageID = "bill@telecom.test"
        _ = try h.fixture.store.addMessage(bill)
        let json = try await h.json(
            "export_search",
            ["subject": "facture", "include": ["amount", "invoice_number"], "path": .string(out.appending(path: "bills.xlsx").path)])
        #expect(json["format"] as? String == "xlsx" && json["rows"] as? Int == 1 && json["with_amount"] as? Int == 1)
        let data = try Data(contentsOf: URL(filePath: try #require(json["path"] as? String)))
        #expect(data.prefix(2) == Data("PK".utf8))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("xl/worksheets/sheet1.xml") && text.contains("<v>25.99</v>") && text.contains(">F-77<"))
    }

    @Test func writerUnits() {
        #expect(SpreadsheetWriter.neutralizeFormula("-2+3") == "'-2+3")
        #expect(SpreadsheetWriter.neutralizeFormula("Invoice") == "Invoice")
        #expect(SpreadsheetWriter.columnName(0) == "A" && SpreadsheetWriter.columnName(26) == "AA")
        #expect(SpreadsheetWriter.xmlText("a<b&\u{1}c") == "a&lt;b&amp;c")
        #expect(ZipArchive.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
    }

    // MARK: Batch read and invoices

    @Test func getMessagesReadsManyAndReportsMissing() async throws {
        let json = try await h.json("get_messages", ["ids": [.int(Int(h.id("kickoff"))), .int(Int(h.id("answer"))), 999_999]])
        let messages = json["messages"] as? [[String: Any]] ?? []
        #expect(messages.count == 2 && json["missing"] as? [Int] == [999_999])
        #expect((messages[0]["body"] as? String)?.contains("Kubernetes") == true)
        #expect((messages[1]["body"] as? String)?.contains("> Dan") == false)  // quotes stripped by default
        #expect(messages[0]["attachments"] as? [String] == ["report.pdf"])
        #expect(await h.call("get_messages", ["ids": .array((1...201).map { .int($0) })]).isError)
    }

    @Test func extractsTotalsFromBodiesAndPDFs() async throws {
        var bill = FixtureMessage(
            subject: "Votre facture", from: EmailAddress(address: "factures@telecom.test", name: "Telecom"),
            to: [StandardFixture.me], date: Date(), mailbox: h.fixture.inbox, body: "Bonjour,\nMontant TTC : 25,99 €\nFacture n° F-77")
        let billID = try h.fixture.store.addMessage(bill)
        bill.subject = "Your receipt from Anthropic"
        bill.body = "Your receipt is attached."
        bill.attachments = [("Receipt-2041.pdf", "application/pdf", Self.pdf("Receipt #2041\nAmount paid $20.00"))]
        bill.messageID = "stripe@anthropic.test"
        let pdfID = try h.fixture.store.addMessage(bill)

        let json = try await h.json("extract_invoice_fields", ["ids": [.int(Int(billID)), .int(Int(pdfID))]])
        let invoices = json["invoices"] as? [[String: Any]] ?? []
        let fromBody = invoices.first { $0["id"] as? Int == Int(billID) }
        #expect(fromBody?["total"] as? Double == 25.99 && fromBody?["currency"] as? String == "EUR")
        #expect(fromBody?["invoice_number"] as? String == "F-77" && fromBody?["source"] as? String == "body")
        let fromPDF = invoices.first { $0["id"] as? Int == Int(pdfID) }
        #expect(fromPDF?["total"] as? Double == 20.0 && fromPDF?["currency"] as? String == "USD")
        #expect(fromPDF?["source"] as? String == "pdf" && fromPDF?["pdf_names"] as? [String] == ["Receipt-2041.pdf"])
        #expect(json["with_total"] as? Int == 2)

        let byFilter = try await h.json("extract_invoice_fields", ["subject": "facture"])
        #expect(byFilter["count"] as? Int == 1)
    }

    /// A one-page PDF with real text, drawn with Core Text.
    static func pdf(_ text: String) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        for (index, line) in text.split(separator: "\n").enumerated() {
            let attributed = NSAttributedString(string: String(line), attributes: [.font: NSFont.systemFont(ofSize: 14)])
            context.textPosition = CGPoint(x: 20, y: 260 - CGFloat(index) * 24)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}
