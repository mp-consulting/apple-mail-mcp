import Foundation
import MCP
import MailAutomation
import MailStore

/// How a mailing list says to unsubscribe (`List-Unsubscribe`, RFC 2369, and `List-Unsubscribe-Post`, RFC 8058).
enum UnsubscribeMethod: Equatable {
    /// One HTTPS POST, no page to visit.
    case oneClick(URL)
    /// An email to the list's address.
    case email(address: String, subject: String, body: String)
    /// A web page the user has to open and confirm.
    case link(URL)
    case none

    var name: String {
        switch self {
        case .oneClick: "one_click"
        case .email: "email"
        case .link: "link"
        case .none: "none"
        }
    }

    /// One-click when the sender offers it over HTTPS, else email, else a link.
    static func from(listUnsubscribe: String?, post: String?) -> UnsubscribeMethod {
        guard let listUnsubscribe else { return .none }
        let targets = listUnsubscribe.split(separator: ",").compactMap { item -> URL? in
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            return URL(string: trimmed.trimmingCharacters(in: .whitespaces))
        }
        let web = targets.first { $0.scheme?.lowercased() == "https" }
        if let web, post?.range(of: "List-Unsubscribe=One-Click", options: .caseInsensitive) != nil { return .oneClick(web) }
        if let mail = targets.first(where: { $0.scheme?.lowercased() == "mailto" }),
           let components = URLComponents(url: mail, resolvingAgainstBaseURL: false), isSingleAddress(components.path)
        {
            // The sender wrote this link, and the email goes out from the user's account: one address, a short
            // one-line subject (lists use it for a token), and never the sender's body text.
            let query = Dictionary((components.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
            var subject = (query["subject"] ?? "").components(separatedBy: .newlines).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            if subject.isEmpty || subject.count > 100 { subject = "unsubscribe" }
            return .email(address: components.path, subject: subject, body: "unsubscribe")
        }
        if let web { return .link(web) }
        if let plain = targets.first(where: { $0.scheme?.lowercased() == "http" }) { return .link(plain) }
        return .none
    }

    /// Exactly one plain `local@domain` address: no lists, display names, routes or whitespace.
    static func isSingleAddress(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), text.count <= 254 else { return false }
        let forbidden = CharacterSet(charactersIn: ",;<>()[]\\\"").union(.whitespacesAndNewlines).union(.controlCharacters)
        return text.unicodeScalars.allSatisfy { !forbidden.contains($0) }
    }

    /// Whether every address `host` resolves to is on the public internet. A one-click link comes from the
    /// sender: it must not reach this Mac, the local network or a `.local` service.
    static func isPublicHost(_ host: String) -> Bool {
        let name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        guard !name.isEmpty, name != "localhost", !name.hasSuffix(".localhost"), !name.hasSuffix(".local"),
              !name.hasSuffix(".internal"), !name.hasSuffix(".lan"), !name.hasSuffix(".home.arpa")
        else { return false }
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, "443", &hints, &list) == 0, let first = list else { return false }
        defer { freeaddrinfo(list) }
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let info = node?.pointee {
            guard let address = info.ai_addr, isPublic(address) else { return false }
            node = info.ai_next
        }
        return true
    }

    private static func isPublic(_ address: UnsafeMutablePointer<sockaddr>) -> Bool {
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            let bytes = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) } }
            switch (bytes[0], bytes[1]) {
            case (0, _), (10, _), (127, _), (169, 254), (192, 168), (255, _): return false
            case (172, 16...31), (100, 64...127): return false  // private, carrier-grade NAT
            case (224...239, _): return false  // multicast
            default: return true
            }
        case AF_INET6:
            let bytes = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) } }
            if bytes.allSatisfy({ $0 == 0 }) || bytes == [UInt8](repeating: 0, count: 15) + [1] { return false }  // :: and ::1
            if bytes[0] & 0xFE == 0xFC { return false }  // fc00::/7 unique local
            if bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80 { return false }  // fe80::/10 link-local
            if bytes[0] == 0xFF { return false }  // multicast
            if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF {  // IPv4-mapped
                var v4 = sockaddr_in()
                v4.sin_family = sa_family_t(AF_INET)
                withUnsafeMutableBytes(of: &v4.sin_addr) { $0.copyBytes(from: bytes[12..<16]) }
                return withUnsafeMutablePointer(to: &v4) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { isPublic($0) } }
            }
            return true
        default:
            return false
        }
    }
}

/// Refuses every redirect: a one-click POST goes to the link the sender signed, nowhere else.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? { nil }
}

extension MailToolbox {
    /// POSTs a one-click unsubscribe and returns the HTTP status (tests replace it).
    public typealias UnsubscribePoster = @Sendable (URL) async throws -> Int

    public static let defaultUnsubscribePoster: UnsubscribePoster = { url in
        guard url.scheme?.lowercased() == "https", let host = url.host(percentEncoded: false), UnsubscribeMethod.isPublicHost(host) else {
            throw ToolError("\(url.host() ?? "this link") is not a public web address; open the link yourself if you trust it")
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("List-Unsubscribe=One-Click".utf8)
        // No cookies or cache: the request says nothing beyond the list's own link.
        let session = URLSession(configuration: .ephemeral)
        let (_, response) = try await session.data(for: request, delegate: NoRedirects())
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    var unsubscribe: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "unsubscribe", "Unsubscribe from mailing lists",
                """
                Unsubscribe from the lists that sent these messages, the way the sender asks in its headers: a \
                one-click request (only when the sender's DKIM signature verified for its own domain), an \
                unsubscribe email, or else a link returned for the user to open. Follows the send policy and asks \
                in the menu bar app when it is "Ask me first". Use dry_run to see the method for each message.
                """,
                Schema.object(
                    [
                        "ids": Schema.ids("Message ids, one per list (up to 20)"),
                        "dry_run": Schema.boolean("Only report how each would unsubscribe (default false)"),
                    ], required: ["ids"]), kind: .compose, openWorld: true),
            kind: .compose
        ) { [automation] arguments in
            let store = try self.store
            let ids = try arguments.ids("ids")
            guard !ids.isEmpty, ids.count <= 20 else { throw ToolError("ids must contain 1 to 20 message ids") }
            let dryRun = try arguments.bool("dry_run") ?? false
            var plan: [(id: Int64, sender: EmailAddress, method: UnsubscribeMethod, note: String?)] = []
            for id in ids {
                let detail = try store.detail(id: id)
                func header(_ name: String) -> String? {
                    detail.headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
                }
                var method = UnsubscribeMethod.from(listUnsubscribe: header("List-Unsubscribe"), post: header("List-Unsubscribe-Post"))
                var note: String?
                switch method {
                case .oneClick, .email:
                    // RFC 8058 relies on the DKIM signature: without one for the sender's domain, a one-click POST
                    // would only tell a forger the address is read, and an unsubscribe email would go wherever a
                    // forger pointed it, from the user's account.
                    let check = Authenticity.check(
                        headers: detail.headers, from: detail.summary.sender, replyTo: [], html: nil, knownDomains: [],
                        priorMessagesFromSender: nil)
                    guard check.dkim != "pass" || check.aligned != true else { break }
                    if case .oneClick(let url) = method {
                        method = .link(url)
                        note = "Not signed by the sender's domain, so no one-click request: open the link only if you trust it."
                    } else {
                        method = .none
                        note = "Not signed by the sender's domain, so no unsubscribe email is sent from your account."
                    }
                default: break
                }
                plan.append((id, detail.summary.sender, method, note))
            }
            func describe(_ item: (id: Int64, sender: EmailAddress, method: UnsubscribeMethod, note: String?), result: String?) -> JSON {
                var target: String?
                switch item.method {
                case .oneClick(let url), .link(let url): target = url.absoluteString
                case .email(let address, _, _): target = address
                case .none: break
                }
                return .obj([
                    ("id", .int(item.id)), ("from", .string(item.sender.formatted)), ("method", .string(item.method.name)),
                    (item.method == .none ? "target" : item.method.name == "email" ? "address" : "url", target.map(JSON.string)),
                    ("result", result.map(JSON.string)), ("note", item.note.map(JSON.string)),
                ])
            }
            let actionable = plan.filter { if case .oneClick = $0.method { true } else if case .email = $0.method { true } else { false } }
            if dryRun || actionable.isEmpty {
                return ToolReply(
                    json: .obj([("dry_run", dryRun ? .bool(true) : nil), ("messages", .array(plan.map { describe($0, result: dryRun ? nil : "nothing to do automatically") }))]),
                    summary: dryRun ? "dry run" : "nothing to unsubscribe automatically")
            }
            switch self.settings.current.sendPolicy {
            case .never:
                throw ToolError("Unsubscribing sends a request on your behalf, and sending is turned off (send policy \"never\"). Use dry_run to get the links.")
            case .allow:
                break
            case .confirm:
                let targets = actionable.map { item -> String in
                    switch item.method {
                    case .oneClick(let url): url.absoluteString
                    case .email(let address, _, _): address
                    default: ""
                    }
                }
                try await self.askUser(
                    ApprovalRequest(
                        id: UUID(), created: Date(), tool: "unsubscribe", client: self.clientName, from: nil, to: targets, cc: [], bcc: [],
                        subject: actionable.count == 1 ? "Unsubscribe from \(actionable[0].sender.name ?? actionable[0].sender.address)" : "Unsubscribe from \(actionable.count) lists",
                        bodyPreview: actionable.map { item -> String in
                            switch item.method {
                            case .email(let address, let subject, _): "\(item.sender.formatted) — email to \(address), subject \"\(subject)\""
                            case .oneClick(let url): "\(item.sender.formatted) — one-click request to \(url.absoluteString)"
                            default: item.sender.formatted
                            }
                        }.joined(separator: "\n"),
                        attachments: [], status: .pending, decided: nil, kind: .unsubscribe),
                    what: "Unsubscribing", declined: "The user declined. Nothing was sent.", nothing: "Nothing was sent.")
            }
            var results: [JSON] = []
            var done = 0
            for item in plan {
                var result = "open the link to finish"
                switch item.method {
                case .oneClick(let url):
                    do {
                        let status = try await self.unsubscribePoster(url)
                        if (200..<300).contains(status) {
                            result = "unsubscribed"
                            done += 1
                        } else {
                            result = "the list answered HTTP \(status); open the link instead"
                        }
                    } catch {
                        result = "request failed: \(error.localizedDescription)"
                    }
                case .email(let address, let subject, let body):
                    _ = try await automation.compose(OutgoingMessage(to: [address], subject: subject, body: body), mode: .send)
                    result = "unsubscribe email sent"
                    done += 1
                case .link: break
                case .none: result = item.note == nil ? "no unsubscribe header" : "not unsubscribed"
                }
                results.append(describe(item, result: result))
            }
            return ToolReply(json: .obj([("unsubscribed", .int(Int64(done))), ("messages", .array(results))]), summary: "unsubscribed \(done)")
        }
    }
}
