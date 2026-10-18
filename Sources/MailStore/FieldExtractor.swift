import Foundation

/// A value worth acting on, found in a message: a parcel to track, a code to type, a booking, a flight, an invite.
public struct ExtractedField: Sendable, Hashable {
    public enum Kind: String, Sendable, CaseIterable {
        case tracking, code, booking, flight, event
    }

    public var kind: Kind
    public var value: String
    /// Kind-specific extras: `carrier`, `route`, `start`, `end`, `location`, `organizer`, `method`, `status`.
    public var details: [String: String]

    public init(kind: Kind, value: String, details: [String: String] = [:]) {
        self.kind = kind
        self.value = value
        self.details = details
    }
}

/// Finds tracking numbers, verification codes, booking references and flights in message text (English,
/// French, German, Spanish, Italian, Portuguese), and events in calendar (`.ics`) parts.
public enum FieldExtractor {
    public static func extract(text: String, subject: String = "", kinds: Set<ExtractedField.Kind> = Set(ExtractedField.Kind.allCases))
        -> [ExtractedField]
    {
        let full = subject + "\n" + text
        var fields: [ExtractedField] = []
        if kinds.contains(.tracking) { fields += trackingNumbers(full) }
        if kinds.contains(.code) { fields += codes(full) }
        if kinds.contains(.booking) { fields += bookings(full, excluding: Set(fields.map(\.value))) }
        if kinds.contains(.flight) { fields += flights(full) }
        var seen = Set<String>()
        return fields.filter { seen.insert($0.kind.rawValue + $0.value).inserted }
    }

    // MARK: Tracking

    static let carriers = [
        "UPS", "FedEx", "DHL", "USPS", "Colissimo", "Chronopost", "La Poste", "DPD", "GLS", "Royal Mail", "PostNL",
        "Hermes", "Evri", "Amazon", "TNT", "Mondial Relay", "Correos", "Poste Italiane", "CTT", "Canada Post", "Purolator",
    ]

    static func carrier(near text: String, around range: Range<String.Index>) -> String? {
        let start = text.index(range.lowerBound, offsetBy: -300, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 300, limitedBy: text.endIndex) ?? text.endIndex
        let window = text[start..<end]
        return carriers.first { window.range(of: $0, options: .caseInsensitive) != nil }
    }

    /// UPU S10 (`LA123456789FR`): two letters, eight digits, a check digit, the country.
    static func validS10(_ value: String) -> Bool {
        let digits = value.dropFirst(2).prefix(9).compactMap(\.wholeNumberValue)
        guard digits.count == 9 else { return false }
        let sum = zip(digits.prefix(8), [8, 6, 4, 2, 3, 5, 9, 7]).reduce(0) { $0 + $1.0 * $1.1 }
        var check = 11 - sum % 11
        if check == 10 { check = 0 } else if check == 11 { check = 5 }
        return check == digits[8]
    }

    static let s10Countries = ["FR": "La Poste", "US": "USPS", "GB": "Royal Mail", "DE": "Deutsche Post", "CN": "China Post",
                               "ES": "Correos", "IT": "Poste Italiane", "NL": "PostNL", "BE": "bpost", "CH": "Swiss Post",
                               "CA": "Canada Post", "PT": "CTT"]

    static func trackingNumbers(_ text: String) -> [ExtractedField] {
        var found: [ExtractedField] = []
        func add(_ value: String, carrier: String?) {
            guard !found.contains(where: { $0.value == value }) else { return }
            found.append(ExtractedField(kind: .tracking, value: value, details: carrier.map { ["carrier": $0] } ?? [:]))
        }
        for match in text.matches(of: /\b1Z[0-9A-Z]{16}\b/) { add(String(match.output), carrier: "UPS") }
        for match in text.matches(of: /\b([A-Z]{2})\d{9}([A-Z]{2})\b/) where validS10(String(match.output.0)) {
            add(String(match.output.0), carrier: carrier(near: text, around: match.range) ?? s10Countries[String(match.output.2)])
        }
        for match in text.matches(of: /\b9[2-5]\d{20}\b/) { add(String(match.output), carrier: "USPS") }
        let labelled = /(?i)(?:tracking\s*(?:number|no\.?|#|id|code)?|track(?:ing)?-?nummer|sendungsnummer|num[ée]ro\s+de\s+suivi|n°\s*de\s+suivi|n[úu]mero\s+de\s+(?:seguimiento|rastreamento|rastreio)|codice\s+di\s+tracciamento|numero\s+di\s+(?:tracking|spedizione))\s*[:#]?\s*([A-Z0-9][A-Z0-9\-]{6,34}[A-Z0-9])\b/
        for match in text.matches(of: labelled) {
            let value = String(match.output.1).replacingOccurrences(of: "-", with: "")
            guard value.contains(where: \.isNumber), value == value.uppercased() else { continue }
            add(value, carrier: carrier(near: text, around: match.range))
        }
        return found
    }

    // MARK: Codes

    static func codes(_ text: String) -> [ExtractedField] {
        var found: [String] = []
        let keywordFirst = /(?i)\b(?:code|passcode|one[- ]time|otp|pin|verification|security|sign[- ]in|login|bestätigungscode|sicherheitscode|anmeldecode|código|codigo|codice|vérification)\b[^\n\d]{0,40}?\b(\d{4,8})\b(?![.,]\d)/
        let codeFirst = /(?i)\b(\d{4,8})\s+(?:is|est|ist|es|è|é)\s+(?:your|votre|ton|dein|ihr|su|tu|il\s+tuo|o\s+seu)\b/
        let google = /\bG-(\d{6})\b/
        for match in text.matches(of: keywordFirst) { found.append(String(match.output.1)) }
        for match in text.matches(of: codeFirst) { found.append(String(match.output.1)) }
        for match in text.matches(of: google) { found.append(String(match.output.1)) }
        var seen = Set<String>()
        return found.filter { code in
            // A four-digit year after "code" is far more likely a date than a code.
            !(code.count == 4 && (code.hasPrefix("19") || code.hasPrefix("20"))) && seen.insert(code).inserted
        }.map { ExtractedField(kind: .code, value: $0) }
    }

    // MARK: Bookings

    static func bookings(_ text: String, excluding: Set<String>) -> [ExtractedField] {
        let labelled = /(?i)(?:confirmation\s*(?:number|code|#|no\.?)|booking\s*(?:reference|ref\.?|number|code|id|#)|reservation\s*(?:number|code|#|id)|record\s+locator|\bPNR\b|r[ée]f[ée]rence\s+(?:de\s+(?:la\s+)?r[ée]servation|du\s+dossier|de\s+commande)|num[ée]ro\s+de\s+(?:r[ée]servation|confirmation|commande)|buchungs(?:nummer|code|referenz)|best[äa]tigungsnummer|localizador|c[óo]digo\s+de\s+reserva|n[úu]mero\s+de\s+reserva|codice\s+(?:di\s+)?prenotazione|order\s*(?:number|no\.?|#|id))\s*[:#]?\s*([A-Z0-9][A-Z0-9\-]{4,15})\b/
        var found: [ExtractedField] = []
        for match in text.matches(of: labelled) {
            let value = String(match.output.1)
            let hasDigit = value.contains(where: \.isNumber), hasLetter = value.contains(where: \.isLetter)
            // Record locators are six letters; anything else needs a digit, and words in lowercase are not codes.
            guard value == value.uppercased(), hasDigit || (hasLetter && value.count == 6), !excluding.contains(value),
                  !found.contains(where: { $0.value == value })
            else { continue }
            found.append(ExtractedField(kind: .booking, value: value))
        }
        return found
    }

    // MARK: Flights

    static let notAirports: Set<String> = ["THE", "AND", "FOR", "YOU", "ARE", "NOT", "BUT", "ALL", "NEW", "VIA", "PDF", "USD", "EUR", "GBP"]

    static func flights(_ text: String) -> [ExtractedField] {
        let flight = /(?i)\b(?:flight|vol|flug|vuelo|volo|voo)\b\s*(?:number|no\.?|n°|nr\.?|#)?\s*:?\s*([A-Z0-9]{2})\s?(\d{1,4})\b/
        let route = /\b([A-Z]{3})\s*(?:→|->|–|—|-|>|to|à|nach|a)\s*([A-Z]{3})\b/
        let routes = text.matches(of: route).map { (String($0.output.1), String($0.output.2)) }
            .filter { !notAirports.contains($0.0) && !notAirports.contains($0.1) }
        var found: [ExtractedField] = []
        for match in text.matches(of: flight) {
            let airline = String(match.output.1)
            guard airline == airline.uppercased(), airline.contains(where: \.isLetter) else { continue }
            let value = airline + String(match.output.2)
            guard !found.contains(where: { $0.value == value }) else { continue }
            var details: [String: String] = [:]
            if let first = routes.first { details["route"] = "\(first.0) → \(first.1)" }
            found.append(ExtractedField(kind: .flight, value: value, details: details))
        }
        return found
    }

    // MARK: Calendar

    /// Events of an iCalendar (RFC 5545) document: summary, start, end, location, organizer, and the
    /// invitation's method (REQUEST, CANCEL, REPLY).
    public static func events(fromICS ics: String) -> [ExtractedField] {
        // Unfold: a line starting with a space or tab continues the previous one.
        var lines: [String] = []
        for raw in ics.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = raw.first, first == " " || first == "\t", !lines.isEmpty {
                lines[lines.count - 1] += raw.dropFirst()
            } else {
                lines.append(String(raw))
            }
        }
        var method: String?
        var events: [ExtractedField] = []
        var current: [String: (value: String, parameters: [String: String])]?
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let head = line[..<colon].split(separator: ";").map(String.init)
            let name = head[0].uppercased()
            var parameters: [String: String] = [:]
            for parameter in head.dropFirst() {
                let pair = parameter.split(separator: "=", maxSplits: 1).map(String.init)
                if pair.count == 2 { parameters[pair[0].uppercased()] = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            }
            let value = unescape(String(line[line.index(after: colon)...]))
            switch (name, value.uppercased()) {
            case ("BEGIN", "VEVENT"): current = [:]
            case ("END", "VEVENT"):
                if let event = current { events.append(field(from: event, method: method)) }
                current = nil
            case ("METHOD", _) where current == nil: method = value.uppercased()
            default:
                if current != nil, current?[name] == nil { current?[name] = (value, parameters) }
            }
        }
        return events
    }

    private static func field(from event: [String: (value: String, parameters: [String: String])], method: String?) -> ExtractedField {
        var details: [String: String] = [:]
        if let start = event["DTSTART"] { details["start"] = isoDate(start.value, parameters: start.parameters) }
        if let end = event["DTEND"] { details["end"] = isoDate(end.value, parameters: end.parameters) }
        if let location = event["LOCATION"]?.value, !location.isEmpty { details["location"] = location }
        if let organizer = event["ORGANIZER"] {
            let address = organizer.value.replacingOccurrences(of: "mailto:", with: "", options: .caseInsensitive)
            details["organizer"] = organizer.parameters["CN"].map { "\($0) <\(address)>" } ?? address
        }
        if let method { details["method"] = method }
        if let status = event["STATUS"]?.value { details["status"] = status.uppercased() }
        if let url = event["URL"]?.value { details["url"] = url }
        return ExtractedField(kind: .event, value: event["SUMMARY"]?.value ?? "(no title)", details: details.compactMapValues { $0 })
    }

    private static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\,", with: ",").replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    /// `20261020T140000Z`, `20261020T140000` with a TZID, or a `20261020` all-day date, as ISO 8601.
    static func isoDate(_ value: String, parameters: [String: String]) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if value.count == 8 {
            formatter.dateFormat = "yyyyMMdd"
            guard let day = formatter.date(from: value) else { return value }
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: day)
        }
        let utc = value.hasSuffix("Z")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        formatter.timeZone = utc ? TimeZone(identifier: "UTC") : parameters["TZID"].flatMap(TimeZone.init(identifier:)) ?? .current
        guard let date = formatter.date(from: utc ? String(value.dropLast()) : value) else { return value }
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        return iso.string(from: date)
    }
}

extension MailStore {
    /// Fields for each message (body, subject and `.ics` parts), read in parallel.
    public func extractedFields(for messages: [MessageSummary], kinds: Set<ExtractedField.Kind>) throws -> [Int64: [ExtractedField]] {
        let (mailboxes, _) = try lookupTables()
        let results = ResultSlots<[ExtractedField]>(count: messages.count)
        DispatchQueue.concurrentPerform(iterations: messages.count) { index in
            autoreleasepool {
                let message = messages[index]
                guard let mailbox = mailboxes[message.mailboxID], let mailboxURL = MailboxURL(mailbox.url),
                      let file = files.emlxURL(rowID: message.id, mailbox: mailboxURL), let emlx = try? EmlxFile(url: file)
                else {
                    results[index] = FieldExtractor.extract(text: message.preview ?? "", subject: message.subject, kinds: kinds)
                    return
                }
                let root = MIME.parse(emlx.message)
                var fields = FieldExtractor.extract(
                    text: MessageContent.searchableText(root, maxCharacters: 60_000), subject: message.subject, kinds: kinds)
                if kinds.contains(.event) {
                    for part in root.leaves where Self.isCalendar(part) {
                        guard let data = attachmentBytes(part, rowID: message.id, mailbox: mailboxURL, limit: 1_048_576) else { continue }
                        fields += FieldExtractor.events(fromICS: MIME.decodeText(data, charset: part.parameters["charset"]))
                    }
                }
                results[index] = fields
            }
        }
        var out: [Int64: [ExtractedField]] = [:]
        for (index, message) in messages.enumerated() { out[message.id] = results[index] ?? [] }
        return out
    }

    static func isCalendar(_ part: MIMEPart) -> Bool {
        part.contentType == "text/calendar" || part.contentType == "application/ics"
            || (part.filename?.lowercased().hasSuffix(".ics") ?? false)
    }

    /// A part's bytes, inline or from Mail's Attachments folder, when smaller than `limit`.
    func attachmentBytes(_ part: MIMEPart, rowID: Int64, mailbox: MailboxURL, limit: Int) -> Data? {
        if part.hasInlineData {
            guard part.rawBody.count < limit * 4 / 3 + 1024 else { return nil }
            return part.decodedBody()
        }
        guard let file = files.attachmentFile(rowID: rowID, mailbox: mailbox, partID: part.partID),
              let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size < limit
        else { return nil }
        return try? Data(contentsOf: file)
    }
}
