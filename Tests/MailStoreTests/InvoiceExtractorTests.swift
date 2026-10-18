import Foundation
import Testing

@testable import MailStore

@Suite("Invoice extraction")
struct InvoiceExtractorTests {
    func fields(_ text: String, subject: String = "") -> InvoiceFields { InvoiceExtractor.extract(text: text, subject: subject) }

    @Test func appleReceipt() {
        let f = fields("Apple Receipt\nORDER ID MXK7QZ2\niCloud+ 50 GB    €0.99\nSubtotal €0.82\nVAT €0.17\nTOTAL €0.99")
        #expect(f.total == "0.99" && f.currency == "EUR" && f.confidence == .high)
    }

    @Test func frenchTelecomAndAccounting() {
        let sosh = fields("Votre facture Sosh\nMontant HT : 21,66 €\nMontant TTC : 25,99 €\nFacture n° 0123456789")
        #expect(sosh.total == "25.99" && sosh.currency == "EUR")
        #expect(sosh.invoiceNumber == "0123456789")
        let pennylane = fields("Facture F-2024-118\nTotal HT 1 000,00 €\nTVA 200,00 €\nNet à payer\n1 200,00 €")
        #expect(pennylane.total == "1200.00" && pennylane.confidence == .high)
        #expect(pennylane.invoiceNumber == "F-2024-118")
        let tolls = fields("Bip&Go - relevé\nMontant total : 12,40 €")
        #expect(tolls.total == "12.40")
    }

    @Test func stripeAndGermanAndPortuguese() {
        let stripe = fields("Receipt from Anthropic\nInvoice number 1A2B3C4D-0007\nAmount paid $20.00\nDate paid Oct 1, 2026")
        #expect(stripe.total == "20.00" && stripe.currency == "USD" && stripe.invoiceNumber == "1A2B3C4D-0007")
        let german = fields("Rechnungsnummer: RE-55\nZwischensumme 1.000,00 EUR\nGesamtbetrag 1.234,56 EUR")
        #expect(german.total == "1234.56" && german.currency == "EUR" && german.invoiceNumber == "RE-55")
        let ikea = fields("IKEA Portugal\nFatura n.º FT 2024/1234\nTotal a pagar 149,00 €", subject: "A sua Fatura")
        #expect(ikea.total == "149.00" && ikea.invoiceNumber == "2024/1234")
    }

    @Test func subtotalsAndPreTaxLinesLoseToTotals() {
        let f = fields("Subtotal: $90.00\nTotal HT 90,00\nTax: $10.00\nTotal: $100.00")
        #expect(f.total == "100.00")
    }

    @Test func fallbacksAndNothing() {
        let loose = fields("Thanks! We charged 49,90 € to your card.")
        #expect(loose.total == "49.90" && loose.confidence == .low)
        #expect(fields("See you tomorrow at 10.30").total == nil)
        #expect(fields("", subject: "Invoice 42").invoiceNumber == "42")
        #expect(fields("Your invoice is ready, no longer pending").invoiceNumber == nil)
    }

    @Test func manyKeywordLinesStayFast() {
        let text = String(repeating: "total\n", count: 30_000) + "Total 5,00 €"
        let start = ContinuousClock.now
        #expect(fields(text).total == "5.00")
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test func amountNormalization() {
        #expect(InvoiceExtractor.normalizeAmount("1 234,56") == "1234.56")
        #expect(InvoiceExtractor.normalizeAmount("1,234.56") == "1234.56")
        #expect(InvoiceExtractor.normalizeAmount("1.234") == "1234.00")
        #expect(InvoiceExtractor.normalizeAmount("12,5") == "12.50")
        #expect(InvoiceExtractor.normalizeAmount("1.234.567") == "1234567.00")
    }
}
