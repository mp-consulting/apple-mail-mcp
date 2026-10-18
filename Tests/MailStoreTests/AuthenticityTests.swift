import Foundation
import MailStore
import Testing

@testable import MailStore

@Suite("Authenticity")
struct AuthenticityTests {
    let bank = EmailAddress(address: "alerts@bank.test", name: "Bank")

    func check(
        _ results: String?, from: EmailAddress? = nil, replyTo: [EmailAddress] = [], html: String? = nil,
        known: Set<String> = [], prior: Int? = 3
    ) -> AuthenticityReport {
        let headers = results.map { [(name: "Authentication-Results", value: $0)] } ?? []
        return Authenticity.check(
            headers: headers, from: from ?? bank, replyTo: replyTo, html: html, knownDomains: known, priorMessagesFromSender: prior)
    }

    @Test func parsesAuthenticationResults() {
        let parsed = Authenticity.parseAuthenticationResults(
            "mx.icloud.test; spf=pass (sender is allowed) smtp.mailfrom=bounce.bank.test; dkim=pass (2048-bit key) header.d=bank.test header.i=@bank.test; dmarc=pass (p=reject) header.from=bank.test")
        #expect(parsed.map(\.method) == ["spf", "dkim", "dmarc"])
        #expect(parsed[0].properties["smtp.mailfrom"] == "bounce.bank.test")
        #expect(parsed[1].properties["header.d"] == "bank.test")
    }

    @Test func authenticatedAndAlignedPasses() {
        let report = check("mx.test; spf=pass smtp.mailfrom=bounce.bank.test; dkim=pass header.d=bank.test; dmarc=pass header.from=bank.test")
        #expect(report.verdict == .pass)
        #expect(report.aligned == true && report.signedBy == ["bank.test"])
        #expect(report.findings.isEmpty)
    }

    @Test func readsOneHeaderPerMethodFromTheSameServer() {
        // iCloud writes a header per method; an upstream server's header must not count.
        let headers = [
            (name: "Authentication-Results", value: "bimi.icloud.test; bimi=none"),
            (name: "Authentication-Results", value: "dmarc.icloud.test; dmarc=pass header.from=bank.test"),
            (name: "Authentication-Results", value: "dkim-verifier.icloud.test; dkim=pass (2048-bit) header.d=bank.test header.i=@bank.test"),
            (name: "Authentication-Results", value: "spf.icloud.test; spf=pass (domain) smtp.mailfrom=bounce.bank.test"),
        ]
        let report = Authenticity.check(headers: headers, from: bank, replyTo: [], html: nil, knownDomains: [], priorMessagesFromSender: 3)
        #expect(report.verdict == .pass && report.aligned == true && report.dmarc == "pass" && report.spf == "pass")
        let upstream = [(name: "Authentication-Results", value: "mx.icloud.test; dkim=pass header.d=bank.test"),
                        (name: "Authentication-Results", value: "relay.other.test; dmarc=fail")]
        #expect(Authenticity.check(headers: upstream, from: bank, replyTo: [], html: nil, knownDomains: [], priorMessagesFromSender: 3).dmarc == nil)
    }

    @Test func dmarcFailureFails() {
        let report = check("mx.test; spf=fail smtp.mailfrom=evil.test; dkim=none; dmarc=fail header.from=bank.test")
        #expect(report.verdict == .fail)
        #expect(report.findings.map(\.code).contains("dmarc_failed"))
        #expect(report.findings.map(\.code).contains("spf_failed"))
    }

    @Test func signedForAnotherDomainIsNotAligned() {
        let report = check("mx.test; spf=pass smtp.mailfrom=mailer.test; dkim=pass header.d=mailer.test; dmarc=none")
        #expect(report.aligned == false && report.verdict == .caution)
        #expect(report.findings.first?.code == "not_aligned")
    }

    @Test func organizationalDomains() {
        #expect(Authenticity.organizationalDomain("mail.news.example.co.uk") == "example.co.uk")
        #expect(Authenticity.organizationalDomain("bounce.bank.test") == "bank.test")
        #expect(Authenticity.organizationalDomain("bank.test") == "bank.test")
    }

    @Test func spotsImpersonation() {
        let spoof = EmailAddress(address: "x@evil.test", name: "support@bank.test")
        #expect(check(nil, from: spoof).findings.map(\.code).contains("display_name_spoof"))
        let lookalike = EmailAddress(address: "alerts@paypa1.test", name: "PayPal")
        #expect(check(nil, from: lookalike, known: ["paypal.test"]).verdict == .fail)
        let typo = EmailAddress(address: "ceo@acmecorp.test")
        #expect(check(nil, from: typo, known: ["acmecrop.test", "acmecorp.test"]).findings.allSatisfy { $0.code != "lookalike_domain" })
        #expect(check(nil, from: EmailAddress(address: "a@acmecorq.test"), known: ["acmecorp.test"]).verdict == .fail)
        // Short names have too many honest neighbours.
        #expect(check(nil, from: EmailAddress(address: "a@gmx.test"), known: ["gmz.test"]).verdict != .fail)
        let punycode = EmailAddress(address: "a@xn--pple-43d.test")
        #expect(check(nil, from: punycode).findings.map(\.code).contains("punycode_domain"))
    }

    @Test func replyToAndFirstContact() {
        let report = check(nil, replyTo: [EmailAddress(address: "help@other.test")], prior: 0)
        let codes = report.findings.map(\.code)
        #expect(codes.contains("reply_to_elsewhere") && codes.contains("first_contact") && codes.contains("no_authentication"))
        #expect(report.verdict == .pass)
    }

    @Test func linksShowingAnotherSite() {
        let html = """
            <p><a href="https://login.evil.test/x">https://www.bank.test/login</a>
            <a href="https://bank.test/help">www.bank.test</a> <a href="https://t.test/r">Click here</a></p>
            """
        let report = check("mx.test; dkim=pass header.d=bank.test; dmarc=pass", html: html)
        #expect(report.findings.filter { $0.code == "link_mismatch" }.map(\.detail) == ["A link shows bank.test but opens login.evil.test."])
        #expect(report.verdict == .caution)
    }
}
