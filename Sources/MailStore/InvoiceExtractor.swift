import Foundation
import PDFKit

/// Fields an invoice or receipt email usually carries, found in its text.
public struct InvoiceFields: Sendable, Equatable {
    /// The total as a plain decimal string ("1234.56").
    public var total: String?
    /// ISO 4217 code, when the text names or implies one ("$" counts as USD).
    public var currency: String?
    public var invoiceNumber: String?
    public var confidence: Confidence?

    public enum Confidence: String, Sendable {
        /// An amount with a currency next to a total keyword ("Total TTC", "Amount paid", "Gesamtbetrag").
        case high
        /// An amount next to a total keyword, without a currency.
        case medium
        /// The first currency amount in the text.
        case low
    }

    public init(total: String? = nil, currency: String? = nil, invoiceNumber: String? = nil, confidence: Confidence? = nil) {
        self.total = total
        self.currency = currency
        self.invoiceNumber = invoiceNumber
        self.confidence = confidence
    }
}

/// Finds totals, currencies and invoice numbers in invoice and receipt text (English, French,
/// German, Spanish, Portuguese, Italian). Pure text heuristics: no network, no model.
public enum InvoiceExtractor {
    /// Total keywords with a priority: the strongest match in the text wins, the later one on a tie
    /// (subtotals come before totals).
    static let totalKeywords: [(keyword: String, priority: Int)] = [
        ("net à payer", 9), ("net a payer", 9), ("montant ttc", 9), ("total ttc", 9), ("amount paid", 9),
        ("valor a pagar", 9), ("total a pagar", 9), ("gesamtbetrag", 9), ("rechnungsbetrag", 9), ("totale da pagare", 9),
        ("amount due", 8), ("total due", 8), ("balance due", 8), ("grand total", 8), ("total amount", 8),
        ("montant total", 8), ("montant payé", 8), ("amount charged", 8), ("total charged", 8), ("importe total", 8),
        ("zu zahlen", 8), ("valor total", 7), ("totale", 6), ("total", 5), ("summe", 4), ("montant", 4),
        ("betrag", 4), ("amount", 3), ("valor", 3), ("importe", 3),
    ]

    /// Words right after a total keyword that make it a pre-tax or partial figure.
    static let partialSuffixes = [" ht", " hors", " h.t", " excl", " before tax", " net of", " sans tva", " netto", " sem iva", " s/iva"]
    static let partialPrefixes = ["sub", "sous-", "sous ", "zwischen", "teil"]

    static let currency =
        #"(?:€|£|¥|r\$|us\$|\$|(?<![a-z])(?:euros|euro|eur|usd|gbp|chf|brl|cad|aud|jpy)(?![a-z]))"#
    static let number = #"(?<![\d.,])(?:\d{1,3}(?:[ .,'’]\d{3})+(?:[.,]\d{1,2})?|\d+(?:[.,]\d{1,2})?)(?![\d])"#

    static let moneyRegex = try! NSRegularExpression(
        pattern: "(?:(?<c1>\(currency))\\s?(?<n1>\(number)))|(?:(?<n2>\(number))\\s?(?<c2>\(currency)))")
    static let bareAmountRegex = try! NSRegularExpression(
        pattern: #"(?<![\d.,])\d{1,3}(?:[ .,'’]\d{3})*[.,]\d{2}(?![\d])"#)

    static let token = #"([A-Za-z0-9][A-Za-z0-9\-/._]*)"#
    static let numberRegexes: [NSRegularExpression] = [
        // "Invoice number: INV-123", "Facture n° F2024-01", "Rechnung Nr. 5", "Fatura n.º FT 2024/1"
        #"\b(?:invoice|facture|fatura|factura|fattura|rechnung|receipt|re[çc]u|recibo|quittung|order|commande)\s*(?:number|num[ée]ro|número|numero|nummer|no\.?|nr\.?|n[°º]\.?|n\.º|#|id)\s*[:#.]?\s*(?:ft\s+)?"#
            + token,
        // "N° de facture : F-2024-001", "Number of the invoice 42", "Numéro de commande 123"
        #"\b(?:n[°º]|num[ée]ro|número|numero|number|nummer)\s*(?:de\s+(?:la\s+)?|of\s+(?:the\s+)?|da\s+)?(?:facture|invoice|fatura|factura|commande|order|re[çc]u|receipt)\s*[:#.]?\s*"#
            + token,
        #"\brechnungs(?:nummer|nr\.?)\s*[:#.]?\s*"# + token,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    /// "Invoice 42", "Invoice #INV-7", "Facture F-2024-01": the keyword followed directly by a number.
    static let looseNumberRegex = try! NSRegularExpression(
        pattern: #"\b(?:invoice|facture|fatura|factura|fattura|rechnung|receipt)\s*[:#]?\s*#?\s*([A-Za-z]{0,5}[-/]?\d[A-Za-z0-9\-/._]*)"#,
        options: [.caseInsensitive])

    public static func extract(text: String, subject: String = "") -> InvoiceFields {
        var fields = InvoiceFields()
        let normalized = text.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
        if let money = total(in: normalized) {
            fields.total = money.amount
            fields.currency = money.currency
            fields.confidence = money.confidence
        }
        fields.invoiceNumber = invoiceNumber(in: normalized, subject: subject)
        return fields
    }

    // MARK: Totals

    struct Money {
        var amount: String
        var currency: String?
        var confidence: InvoiceFields.Confidence
    }

    static func total(in text: String) -> Money? {
        let lines = text.lowercased().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var best: (priority: Int, line: Int, money: Money)?
        for (index, line) in lines.enumerated() {
            for (keyword, priority) in totalKeywords where priority >= (best?.priority ?? 0) {
                var searchStart = line.startIndex
                while let range = line.range(of: keyword, range: searchStart..<line.endIndex) {
                    searchStart = range.upperBound
                    guard isWordBoundary(line, range), !isPartialTotal(line, range) else { continue }
                    // An amount after the keyword on the same line, else on the next two non-empty lines.
                    var found = money(in: String(line[range.upperBound...]))
                    if found == nil {
                        // Lazy: a crafted mail with thousands of keyword lines must not rescan the rest each time.
                        for next in lines[(index + 1)...].lazy.filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }).prefix(2) {
                            if let hit = money(in: next) { found = hit; break }
                        }
                    }
                    if let found, priority > (best?.priority ?? 0) || (priority == best?.priority && index >= best!.line) {
                        best = (priority, index, found)
                    }
                    break
                }
            }
        }
        if let best { return best.money }
        // No keyword: the first amount that names a currency.
        let range = NSRange(text.startIndex..., in: text)
        if let match = moneyRegex.firstMatch(in: text.lowercased(), range: range), let money = money(from: match, in: text.lowercased()) {
            return Money(amount: money.amount, currency: money.currency, confidence: .low)
        }
        return nil
    }

    /// The first amount in `text`: with a currency (high), else a bare `12,34` (medium).
    static func money(in text: String) -> Money? {
        let range = NSRange(text.startIndex..., in: text)
        if let match = moneyRegex.firstMatch(in: text, range: range), let money = money(from: match, in: text) {
            return Money(amount: money.amount, currency: money.currency, confidence: .high)
        }
        if let match = bareAmountRegex.firstMatch(in: text, range: range), let swiftRange = Range(match.range, in: text),
           let amount = normalizeAmount(String(text[swiftRange]))
        {
            return Money(amount: amount, currency: nil, confidence: .medium)
        }
        return nil
    }

    static func money(from match: NSTextCheckingResult, in text: String) -> (amount: String, currency: String?)? {
        for (n, c) in [("n1", "c1"), ("n2", "c2")] {
            guard let numberRange = Range(match.range(withName: n), in: text),
                  let currencyRange = Range(match.range(withName: c), in: text),
                  let amount = normalizeAmount(String(text[numberRange]))
            else { continue }
            return (amount, currencyCode(String(text[currencyRange])))
        }
        return nil
    }

    static func isWordBoundary(_ line: String, _ range: Range<String.Index>) -> Bool {
        let before = range.lowerBound == line.startIndex ? nil : line[line.index(before: range.lowerBound)]
        let after = range.upperBound == line.endIndex ? nil : line[range.upperBound]
        return !(before?.isLetter ?? false) && !(after?.isLetter ?? false)
    }

    static func isPartialTotal(_ line: String, _ range: Range<String.Index>) -> Bool {
        let before = line[..<range.lowerBound].suffix(8)
        let after = line[range.upperBound...].prefix(12)
        return partialPrefixes.contains { before.hasSuffix($0) } || partialSuffixes.contains { after.hasPrefix($0) }
    }

    /// "1 234,56", "1,234.56", "1.234", "12,5" → "1234.56", "1234.56", "1234.00", "12.50".
    static func normalizeAmount(_ raw: String) -> String? {
        let compact = raw.filter { !" '’".contains($0) }
        let lastDot = compact.lastIndex(of: ".")
        let lastComma = compact.lastIndex(of: ",")
        var decimal: String.Index?
        switch (lastDot, lastComma) {
        case let (dot?, comma?): decimal = max(dot, comma)
        case let (separator?, nil), let (nil, separator?):
            // One kind of separator: three digits after it means thousands ("1.234"), fewer means decimals.
            let digitsAfter = compact.distance(from: separator, to: compact.endIndex) - 1
            let occurrences = compact.filter { $0 == compact[separator] }.count
            decimal = digitsAfter == 3 || occurrences > 1 ? nil : separator
        case (nil, nil): decimal = nil
        }
        var integer = compact
        var fraction = ""
        if let decimal {
            integer = String(compact[..<decimal])
            fraction = String(compact[compact.index(after: decimal)...])
        }
        integer = integer.filter(\.isNumber)
        guard !integer.isEmpty, let value = Decimal(string: integer + "." + (fraction.isEmpty ? "0" : fraction)) else { return nil }
        guard value > 0, value < 100_000_000 else { return nil }
        var rounded = Decimal()
        var source = value
        NSDecimalRound(&rounded, &source, 2, .plain)
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.usesGroupingSeparator = false
        return formatter.string(from: rounded as NSDecimalNumber)
    }

    static func currencyCode(_ raw: String) -> String? {
        switch raw.lowercased() {
        case "€", "eur", "euro", "euros": "EUR"
        case "$", "us$", "usd": "USD"
        case "£", "gbp": "GBP"
        case "¥", "jpy": "JPY"
        case "r$", "brl": "BRL"
        case "chf": "CHF"
        case "cad": "CAD"
        case "aud": "AUD"
        default: nil
        }
    }

    // MARK: Invoice numbers

    static func invoiceNumber(in text: String, subject: String) -> String? {
        for regex in numberRegexes {
            if let found = firstToken(regex, in: text) { return found }
        }
        return firstToken(looseNumberRegex, in: subject) ?? firstToken(looseNumberRegex, in: text)
    }

    static func firstToken(_ regex: NSRegularExpression, in text: String) -> String? {
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            let token = String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".-_/"))
            if token.contains(where: \.isNumber), (1...40).contains(token.count) { return token }
        }
        return nil
    }
}

/// What `MailStore.invoiceFields` found for one message.
public struct InvoiceResult: Sendable {
    public var fields: InvoiceFields
    /// Where the total came from: `body` or `pdf`.
    public var source: String?
    public var pdfNames: [String]
    /// False when Mail has not downloaded the message yet.
    public var bodyAvailable: Bool
}

extension MailStore {
    /// Invoice fields for each message, read in parallel. The body comes first; when it has no confident
    /// total and `readPDFs` is set, the text of attached PDFs (first pages of the first two) is tried.
    public func invoiceFields(for messages: [MessageSummary], readPDFs: Bool = true) throws -> [Int64: InvoiceResult] {
        let (mailboxes, _) = try lookupTables()
        let results = ResultSlots<InvoiceResult>(count: messages.count)
        DispatchQueue.concurrentPerform(iterations: messages.count) { index in
            autoreleasepool {
                results[index] = invoiceResult(for: messages[index], mailboxes: mailboxes, readPDFs: readPDFs)
            }
        }
        var out: [Int64: InvoiceResult] = [:]
        for (index, message) in messages.enumerated() {
            if let result = results[index] { out[message.id] = result }
        }
        return out
    }

    private func invoiceResult(for message: MessageSummary, mailboxes: [Int64: Mailbox], readPDFs: Bool) -> InvoiceResult {
        guard let mailbox = mailboxes[message.mailboxID], let mailboxURL = MailboxURL(mailbox.url),
              let file = files.emlxURL(rowID: message.id, mailbox: mailboxURL), let emlx = try? EmlxFile(url: file)
        else {
            let fields = InvoiceExtractor.extract(text: message.preview ?? "", subject: message.subject)
            return InvoiceResult(fields: fields, source: fields.total == nil ? nil : "preview", pdfNames: [], bodyAvailable: false)
        }
        let root = MIME.parse(emlx.message)
        let body = MessageContent.searchableText(root, maxCharacters: 60_000)
        var fields = InvoiceExtractor.extract(text: body, subject: message.subject)
        var source = fields.total == nil ? nil : "body"
        let pdfs = root.leaves.filter { $0.isAttachment && Self.isPDF($0) }
        if readPDFs, fields.confidence != .high {
            for part in pdfs.prefix(2) {
                guard let data = pdfData(part, rowID: message.id, mailbox: mailboxURL), let text = Self.pdfText(data) else { continue }
                let fromPDF = InvoiceExtractor.extract(text: text, subject: message.subject)
                if Self.rank(fromPDF.confidence) > Self.rank(fields.confidence) {
                    fields.total = fromPDF.total
                    fields.currency = fromPDF.currency
                    fields.confidence = fromPDF.confidence
                    source = "pdf"
                }
                if fields.invoiceNumber == nil { fields.invoiceNumber = fromPDF.invoiceNumber }
                if fields.confidence == .high { break }
            }
        }
        return InvoiceResult(
            fields: fields, source: source, pdfNames: pdfs.map { $0.filename ?? "part-\($0.partID).pdf" }, bodyAvailable: true)
    }

    static func isPDF(_ part: MIMEPart) -> Bool {
        part.contentType == "application/pdf" || (part.filename?.lowercased().hasSuffix(".pdf") ?? false)
    }

    static func rank(_ confidence: InvoiceFields.Confidence?) -> Int {
        switch confidence {
        case .high: 3
        case .medium: 2
        case .low: 1
        case nil: 0
        }
    }

    /// PDF bytes inline in the message or in Mail's Attachments folder; skipped above 15 MB.
    private func pdfData(_ part: MIMEPart, rowID: Int64, mailbox: MailboxURL) -> Data? {
        let limit = 15 * 1_048_576
        if part.hasInlineData {
            guard part.rawBody.count < limit * 4 / 3 + 1024 else { return nil }
            return part.decodedBody()
        }
        guard let file = files.attachmentFile(rowID: rowID, mailbox: mailbox, partID: part.partID),
              let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size < limit
        else { return nil }
        return try? Data(contentsOf: file)
    }

    /// PDFKit is not documented as thread-safe: one document at a time.
    private static let pdfLock = NSLock()

    /// Text of the first pages of a PDF; nil for scans and unreadable files.
    static func pdfText(_ data: Data, maxPages: Int = 3) -> String? {
        pdfLock.lock()
        defer { pdfLock.unlock() }
        guard let document = PDFDocument(data: data), !document.isLocked else { return nil }
        var text = ""
        for index in 0..<min(document.pageCount, maxPages) {
            text += (document.page(at: index)?.string ?? "") + "\n"
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }
}

/// Lock-protected optional results written from `concurrentPerform`.
final class ResultSlots<T>: @unchecked Sendable {
    private var storage: [T?]
    private let lock = NSLock()

    init(count: Int) { storage = Array(repeating: nil, count: count) }

    subscript(index: Int) -> T? {
        get { lock.withLock { storage[index] } }
        set { lock.withLock { storage[index] = newValue } }
    }
}
