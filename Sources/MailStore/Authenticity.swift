import Foundation

/// Whether a message really comes from who it says, judged from its headers and links.
public struct AuthenticityReport: Sendable {
    public enum Verdict: String, Sendable {
        /// Authenticated and nothing odd found.
        case pass
        /// Something deserves a second look before trusting a link or a request.
        case caution
        /// Failed authentication or a clear impersonation sign.
        case fail
    }

    public struct Finding: Sendable, Hashable {
        public enum Severity: String, Sendable, Comparable {
            case info, low, medium, high

            var rank: Int { [.info: 0, .low: 1, .medium: 2, .high: 3][self]! }
            public static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }
        }

        public var code: String
        public var severity: Severity
        public var detail: String
    }

    public var verdict: Verdict
    /// Results as the receiving server recorded them (`pass`, `fail`, `softfail`, `none`…).
    public var spf: String?
    public var dkim: String?
    public var dmarc: String?
    /// Domains whose DKIM signature verified.
    public var signedBy: [String]
    public var fromDomain: String
    /// The From domain matches a verified DKIM domain or the SPF envelope domain (same organisation).
    public var aligned: Bool?
    public var findings: [Finding]
}

public enum Authenticity {
    /// Judges one message.
    /// - Parameters:
    ///   - headers: every header, in file order (topmost first), as `MessageDetail.headers`.
    ///   - knownDomains: domains the user corresponds with, to spot lookalikes.
    ///   - priorMessagesFromSender: earlier messages from this exact address, when known.
    public static func check(
        headers: [(name: String, value: String)], from: EmailAddress, replyTo: [EmailAddress], html: String?,
        knownDomains: Set<String>, priorMessagesFromSender: Int?
    ) -> AuthenticityReport {
        var findings: [AuthenticityReport.Finding] = []
        func add(_ code: String, _ severity: AuthenticityReport.Finding.Severity, _ detail: String) {
            findings.append(.init(code: code, severity: severity, detail: detail))
        }
        let fromDomain = from.domain
        let fromOrg = organizationalDomain(fromDomain)

        // The receiving server's verdicts: the topmost Authentication-Results header is the one it added.
        let results = headers.first { $0.name.caseInsensitiveCompare("Authentication-Results") == .orderedSame }
            .map { parseAuthenticationResults($0.value) } ?? []
        func result(_ method: String) -> [AuthResult] { results.filter { $0.method == method } }
        let dkimResults = result("dkim")
        let signedBy = dkimResults.filter { $0.result == "pass" }.compactMap { $0.properties["header.d"]?.lowercased() }
        let dkim = dkimResults.isEmpty ? nil : (signedBy.isEmpty ? dkimResults[0].result : "pass")
        var spf = result("spf").first?.result
        let mailFrom = result("spf").first?.properties["smtp.mailfrom"].map { address in
            (address.split(separator: "@").last.map(String.init) ?? address).lowercased()
        }
        if spf == nil, let received = headers.first(where: { $0.name.caseInsensitiveCompare("Received-SPF") == .orderedSame }) {
            spf = received.value.split(whereSeparator: { $0 == " " || $0 == "(" }).first.map { $0.lowercased() }
        }
        let dmarc = result("dmarc").first?.result

        var aligned: Bool?
        if !results.isEmpty {
            let dkimAligned = signedBy.contains { organizationalDomain($0) == fromOrg }
            let spfAligned = spf == "pass" && mailFrom.map { organizationalDomain($0) == fromOrg } == true
            aligned = dkimAligned || spfAligned
        }

        switch dmarc {
        case "fail": add("dmarc_failed", .high, "DMARC failed: the sender's own domain policy rejects this message as not from \(fromDomain).")
        case "pass", nil, "none", "bestguesspass": break
        default: add("dmarc_\(dmarc!)", .low, "DMARC result \(dmarc!).")
        }
        switch spf {
        case "fail": add("spf_failed", .medium, "SPF failed: the server that sent it is not allowed to send for \(mailFrom ?? fromDomain).")
        case "softfail": add("spf_softfail", .low, "SPF soft-failed for \(mailFrom ?? fromDomain).")
        default: break
        }
        if let dkim, dkim != "pass", dkim != "none" {
            add("dkim_failed", .medium, "The DKIM signature did not verify (\(dkim)): the message may have been changed in transit.")
        }
        if results.isEmpty, spf == nil {
            add("no_authentication", .low, "No authentication results recorded (some accounts and local mail have none).")
        } else if aligned == false, dmarc != "fail" {
            let by = signedBy.first.map { " (signed by \($0))" } ?? ""
            add("not_aligned", .medium, "Authenticated for another domain than the From address \(fromDomain)\(by).")
        }

        if let reply = replyTo.first, !reply.domain.isEmpty, organizationalDomain(reply.domain) != fromOrg {
            add("reply_to_elsewhere", .low, "Replies go to \(reply.address), not to \(fromDomain).")
        }
        if let name = from.name, let shown = embeddedAddress(in: name), organizationalDomain(EmailAddress(address: shown).domain) != fromOrg {
            add("display_name_spoof", .high, "The name shows \(shown) but the message comes from \(from.address).")
        }
        if fromDomain.split(separator: ".").contains(where: { $0.hasPrefix("xn--") }) {
            add("punycode_domain", .medium, "The sender domain \(fromDomain) uses look-alike international characters.")
        }
        if let lookalike = lookalike(of: fromOrg, among: knownDomains) {
            add("lookalike_domain", .high, "\(fromOrg) looks like \(lookalike), a domain you correspond with, but is not it.")
        }
        if priorMessagesFromSender == 0 {
            add("first_contact", .info, "First message you have from \(from.address).")
        }
        for mismatch in linkMismatches(html ?? "").prefix(3) {
            add("link_mismatch", .medium, "A link shows \(mismatch.shown) but opens \(mismatch.actual).")
        }

        let worst = findings.map(\.severity).max() ?? .info
        let verdict: AuthenticityReport.Verdict = worst == .high ? .fail : worst == .medium ? .caution : .pass
        return AuthenticityReport(
            verdict: verdict, spf: spf, dkim: dkim, dmarc: dmarc, signedBy: Array(Set(signedBy)).sorted(), fromDomain: fromDomain,
            aligned: aligned, findings: findings.sorted { $0.severity > $1.severity })
    }

    // MARK: Authentication-Results

    struct AuthResult: Equatable {
        var method: String
        var result: String
        var properties: [String: String]
    }

    /// `mx.example; spf=pass smtp.mailfrom=a.test; dkim=pass header.d=a.test` (RFC 8601), comments removed.
    static func parseAuthenticationResults(_ value: String) -> [AuthResult] {
        var text = ""
        var depth = 0
        for character in value {
            if character == "(" { depth += 1 } else if character == ")" { depth = max(0, depth - 1) } else if depth == 0 { text.append(character) }
        }
        return text.split(separator: ";").dropFirst().compactMap { clause in
            let words = clause.split(whereSeparator: { $0.isWhitespace })
            guard let first = words.first, let equals = first.firstIndex(of: "=") else { return nil }
            var properties: [String: String] = [:]
            for word in words.dropFirst() {
                guard let sign = word.firstIndex(of: "=") else { continue }
                properties[word[..<sign].lowercased()] = String(word[word.index(after: sign)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
            return AuthResult(
                method: first[..<equals].lowercased(), result: first[first.index(after: equals)...].lowercased(), properties: properties)
        }
    }

    // MARK: Domains

    private static let secondLevel: Set<String> = ["co", "com", "org", "net", "ac", "gov", "edu", "ne", "or", "gouv"]

    /// `mail.news.example.co.uk` → `example.co.uk`: close enough to a public-suffix lookup for alignment.
    public static func organizationalDomain(_ domain: String) -> String {
        let labels = domain.lowercased().split(separator: ".").map(String.init)
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let keep = labels[labels.count - 1].count == 2 && secondLevel.contains(labels[labels.count - 2]) ? 3 : 2
        return labels.suffix(keep).joined(separator: ".")
    }

    /// An address written into a display name: `"support@bank.test" <x@evil.test>`.
    static func embeddedAddress(in name: String) -> String? {
        let pattern = /[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}/
        return name.firstMatch(of: pattern).map { String($0.output).lowercased() }
    }

    /// Characters people mistake for others in a domain: digits for letters, `rn` for `m`.
    static func skeleton(_ label: String) -> String {
        var text = label.lowercased().applyingTransform(.toLatin, reverse: false)?
            .folding(options: [.diacriticInsensitive], locale: nil) ?? label.lowercased()
        for (from, to) in [("rn", "m"), ("vv", "w"), ("0", "o"), ("1", "l"), ("3", "e"), ("5", "s"), ("i", "l")] {
            text = text.replacingOccurrences(of: from, with: to)
        }
        return text
    }

    /// A known domain that `domain` imitates: same suffix, a name one edit away or the same once look-alike
    /// characters are normalised. Short names are skipped (too many honest neighbours).
    static func lookalike(of domain: String, among known: Set<String>) -> String? {
        let parts = domain.split(separator: ".", maxSplits: 1).map(String.init)
        let knownOrganizations = Set(known.map(organizationalDomain))
        guard parts.count == 2, !knownOrganizations.contains(domain) else { return nil }
        for candidate in knownOrganizations.sorted() {
            let other = candidate.split(separator: ".", maxSplits: 1).map(String.init)
            guard other.count == 2, other[1] == parts[1], other[0].count >= 5 else { continue }
            if skeleton(other[0]) == skeleton(parts[0]) || editDistance(other[0], parts[0]) == 1 { return candidate }
        }
        return nil
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }

    // MARK: Links

    struct LinkMismatch: Equatable {
        var shown: String
        var actual: String
    }

    /// Links whose visible text is a web address on another site than the one they open.
    static func linkMismatches(_ html: String) -> [LinkMismatch] {
        guard html.range(of: "<a", options: .caseInsensitive) != nil else { return [] }
        let anchor = /(?is)<a\b[^>]*?href\s*=\s*["']([^"']+)["'][^>]*>(.*?)<\/a>/
        var found: [LinkMismatch] = []
        for match in html.matches(of: anchor) {
            let href = String(match.output.1)
            let shown = HTMLText.plainText(fromHTML: String(match.output.2)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let shownHost = host(inVisibleText: shown), let actualHost = URL(string: href)?.host?.lowercased(),
                  organizationalDomain(shownHost) != organizationalDomain(actualHost)
            else { continue }
            let item = LinkMismatch(shown: shownHost, actual: actualHost)
            if !found.contains(item) { found.append(item) }
        }
        return found
    }

    /// `https://bank.test/login` or `www.bank.test` → `bank.test`; nil for ordinary words.
    static func host(inVisibleText text: String) -> String? {
        guard !text.contains(" "), text.count < 200 else { return nil }
        let candidate = text.lowercased().hasPrefix("http") ? text : "https://" + text
        guard let host = URL(string: candidate)?.host?.lowercased(), host.contains("."),
              host.range(of: #"^[a-z0-9.\-]+\.[a-z]{2,}$"#, options: .regularExpression) != nil
        else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

extension MailStore {
    /// Messages from this exact address (any mailbox), not counting `excluding`.
    public func messageCount(fromAddress address: String, excluding id: Int64? = nil) throws -> Int {
        Int(
            try withDB { db in
                try db.scalarInt(
                    """
                    SELECT COUNT(*) FROM messages m JOIN addresses a ON a.ROWID = m.sender
                    WHERE a.address = ? AND m.deleted = 0 AND m.ROWID != ?
                    """, [.text(address), .int(id ?? -1)]) ?? 0
            })
    }
}
