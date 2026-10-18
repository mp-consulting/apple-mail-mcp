import Foundation
import MailStore
import Testing

@testable import MailStore

@Suite("Field extractor")
struct FieldExtractorTests {
    func values(_ text: String, _ kind: ExtractedField.Kind, subject: String = "") -> [String] {
        FieldExtractor.extract(text: text, subject: subject, kinds: [kind]).map(\.value)
    }

    @Test func trackingNumbers() {
        let fields = FieldExtractor.extract(
            text: "Your UPS parcel 1Z999AA10123456784 is on its way. Colissimo : suivez LA123456785FR. Fake LA123456789FR.",
            kinds: [.tracking])
        #expect(fields.map(\.value) == ["1Z999AA10123456784", "LA123456785FR"])
        #expect(fields[0].details["carrier"] == "UPS")
        #expect(FieldExtractor.validS10("RR123456785FR") && !FieldExtractor.validS10("RR123456784FR"))
        #expect(values("DHL Express - Sendungsnummer: 1234567890", .tracking) == ["1234567890"])
        let labelled = FieldExtractor.extract(text: "Numéro de suivi : 6A12345678901 (Colissimo)", kinds: [.tracking])
        #expect(labelled.first?.value == "6A12345678901" && labelled.first?.details["carrier"] == "Colissimo")
        #expect(values("tracking number: pending", .tracking).isEmpty)
    }

    @Test func verificationCodes() {
        #expect(values("Your verification code is 482913. It expires in 10 minutes.", .code) == ["482913"])
        #expect(values("Votre code de vérification : 7731", .code) == ["7731"])
        #expect(values("", .code, subject: "G-584211 is your Google verification code") == ["584211"])
        #expect(values("193847 is your Instagram code", .code) == ["193847"])
        #expect(values("Promo code SUMMER valid until 2026", .code).isEmpty)
        #expect(values("Order total 1234.50 with code", .code).isEmpty)
    }

    @Test func bookingsAndFlights() {
        let text = "Booking reference: QX7P2L\nFlight AF 1234 CDG → JFK departs 10:20. Confirmation number: 88412345."
        #expect(values(text, .booking) == ["QX7P2L", "88412345"])
        let flights = FieldExtractor.extract(text: text, kinds: [.flight])
        #expect(flights.map(\.value) == ["AF1234"] && flights[0].details["route"] == "CDG → JFK")
        #expect(values("Your order number: details below", .booking).isEmpty)
        #expect(values("vol de nuit", .flight).isEmpty)
    }

    @Test func calendarInvitations() {
        let ics = """
            BEGIN:VCALENDAR\r
            METHOD:REQUEST\r
            BEGIN:VEVENT\r
            SUMMARY:Roadmap review\\, Q4\r
            DTSTART;TZID=Europe/Paris:20261020T140000\r
            DTEND:20261020T130000Z\r
            LOCATION:Room 4\r
            ORGANIZER;CN=Alice Martin:mailto:alice@example.test\r
            DESCRIPTION:A long\r
             folded line\r
            END:VEVENT\r
            END:VCALENDAR\r
            """
        let events = FieldExtractor.events(fromICS: ics)
        #expect(events.count == 1)
        #expect(events[0].value == "Roadmap review, Q4")
        #expect(events[0].details["method"] == "REQUEST" && events[0].details["location"] == "Room 4")
        #expect(events[0].details["organizer"] == "Alice Martin <alice@example.test>")
        let iso = ISO8601DateFormatter()
        #expect(iso.date(from: events[0].details["start"] ?? "") == iso.date(from: "2026-10-20T12:00:00Z"))
        #expect(iso.date(from: events[0].details["end"] ?? "") == iso.date(from: "2026-10-20T13:00:00Z"))
        #expect(FieldExtractor.events(fromICS: "BEGIN:VEVENT\nDTSTART;VALUE=DATE:20261224\nEND:VEVENT").first?.details["start"] == "2026-12-24")
    }
}
