import Foundation
import MCP
import MailStore

/// The MCP server over HTTP for remote clients (claude.ai and the Claude apps), behind a tunnel that publishes it at
/// `Settings.remoteAddress`, such as `https://mcp.example.com/me/mail`. Everything lives under that address's path,
/// so several servers can share one host name, each on its own path:
///
/// - `<path>`: the MCP endpoint (Streamable HTTP), bearer tokens only;
/// - `<path>/oauth/register`, `token`, `revoke`: RFC 7591, the token endpoint, RFC 7009;
/// - `<path>/oauth/authorize`: the page where the person approves, with the passcode or in the menu bar app;
/// - `/.well-known/oauth-protected-resource<path>` and `/.well-known/oauth-authorization-server<path>`: the discovery
///   documents, where RFC 9728 and RFC 8414 put them for an address with a path (the tunnel routes these too), and
///   the same under `<path>/.well-known/…` for clients that look there.
///
/// Each MCP session gets its own toolbox (its client's name in the activity log, read-only when the grant is) and
/// stays bound to the grant that opened it.
public final class RemoteServer: @unchecked Sendable {
    public struct Address: Sendable, Equatable {
        /// `https://mcp.example.com`
        public let origin: String
        /// `mcp.example.com` (with `:port` when the address has one), what the `Host` header must say.
        public let host: String
        /// `/me/mail`, or empty.
        public let path: String

        public init?(_ text: String) {
            guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespaces)),
                  let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
                  let name = components.host?.lowercased(), !name.isEmpty, components.query == nil, components.fragment == nil
            else { return nil }
            host = components.port.map { "\(name):\($0)" } ?? name
            origin = "\(scheme)://\(host)"
            var path = components.path
            while path.hasSuffix("/") { path.removeLast() }
            self.path = path
        }

        /// The MCP endpoint's path: the address itself, or `/mcp` for an address without a path.
        public var endpoint: String { path.isEmpty ? "/mcp" : path }
        public var resource: String { origin + endpoint }
        public var issuer: String { origin + path }
    }

    let address: Address
    let access: RemoteAccess
    let approvals: ApprovalCenter
    let settings: SettingsProvider
    let makeToolbox: @Sendable (_ readOnly: Bool) -> MailToolbox
    let name: String

    private let lock = NSLock()
    private var sessions: [String: Session] = [:]
    private var tickets: [UUID: Ticket] = [:]
    private var failures: [Date] = []

    final class Session: @unchecked Sendable {
        let transport: StatefulHTTPServerTransport
        let server: Server
        let toolbox: MailToolbox
        let grantID: String
        var lastUsed = Date()

        init(transport: StatefulHTTPServerTransport, server: Server, toolbox: MailToolbox, grantID: String) {
            self.transport = transport
            self.server = server
            self.toolbox = toolbox
            self.grantID = grantID
        }
    }

    /// An approval asked in the menu bar app, which the sign-in page polls.
    struct Ticket {
        var status: ApprovalRequest.Status
        var redirect: String?
        var created: Date
    }

    static let sessionIdleLimit: TimeInterval = 3600
    static let maximumSessions = 32
    /// Wrong passcodes in this window lock the page out until the oldest one leaves it.
    static let failureWindow: TimeInterval = 900
    static let maximumFailures = 5

    public init(
        address: Address, access: RemoteAccess, approvals: ApprovalCenter, settings: SettingsProvider, name: String = "Apple Mail",
        makeToolbox: @escaping @Sendable (_ readOnly: Bool) -> MailToolbox
    ) {
        self.address = address
        self.access = access
        self.approvals = approvals
        self.settings = settings
        self.name = name
        self.makeToolbox = makeToolbox
    }

    // MARK: Routing

    public func handle(_ request: HTTPListener.Request) async -> HTTPListener.Response {
        guard hostAllowed(request.headers["host"]) else { return Self.json(["error": "misdirected request"], status: 421) }
        let path = request.path.count > 1 && request.path.hasSuffix("/") ? String(request.path.dropLast()) : request.path
        let prefix = address.path
        let resourceMetadata = ["/.well-known/oauth-protected-resource" + prefix, prefix + "/.well-known/oauth-protected-resource"]
        let serverMetadata = [
            "/.well-known/oauth-authorization-server" + prefix, "/.well-known/openid-configuration" + prefix,
            prefix + "/.well-known/oauth-authorization-server", prefix + "/.well-known/openid-configuration",
        ]
        if request.method == "OPTIONS" { return .full(status: 204, headers: Self.cors, body: Data()) }
        switch path {
        case address.endpoint, prefix + "/mcp":
            return await mcp(request)
        case _ where resourceMetadata.contains(path):
            return Self.json([
                "resource": address.resource, "authorization_servers": [address.issuer], "bearer_methods_supported": ["header"],
                "scopes_supported": ["mail"], "resource_name": name,
            ])
        case _ where serverMetadata.contains(path):
            let base = address.issuer + "/oauth"
            return Self.json([
                "issuer": address.issuer, "authorization_endpoint": base + "/authorize", "token_endpoint": base + "/token",
                "registration_endpoint": base + "/register", "revocation_endpoint": base + "/revoke",
                "response_types_supported": ["code"], "grant_types_supported": ["authorization_code", "refresh_token"],
                "code_challenge_methods_supported": ["S256"], "token_endpoint_auth_methods_supported": ["none"],
                "revocation_endpoint_auth_methods_supported": ["none"], "scopes_supported": ["mail"],
                "authorization_response_iss_parameter_supported": true,
            ])
        case prefix + "/oauth/register" where request.method == "POST":
            return register(request)
        case prefix + "/oauth/token" where request.method == "POST":
            return token(request)
        case prefix + "/oauth/revoke" where request.method == "POST":
            let form = Self.form(request.body)
            if let token = form["token"], let client = form["client_id"] { try? access.revoke(token: token, clientID: client) }
            return Self.json([:])
        case prefix + "/oauth/authorize" where request.method == "GET":
            return authorizePage(request)
        case prefix + "/oauth/approve" where request.method == "POST":
            return await approve(request)
        case prefix + "/oauth/ask" where request.method == "POST":
            return ask(request)
        case _ where path.hasPrefix(prefix + "/oauth/ask/") && request.method == "GET":
            return poll(String(path.dropFirst((prefix + "/oauth/ask/").count)))
        default:
            return Self.json(["error": "not found"], status: 404)
        }
    }

    /// The published host name, or this machine (local checks, a tunnel that rewrites `Host`).
    func hostAllowed(_ header: String?) -> Bool {
        guard let header = header?.lowercased() else { return false }
        if header == address.host { return true }
        let name = header.hasPrefix("[") ? String(header.prefix { $0 != "]" }) + "]" : String(header.split(separator: ":").first ?? "")
        return ["localhost", "127.0.0.1", "[::1]"].contains(name)
    }

    static let cors = [
        "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
        "Access-Control-Allow-Headers": "Authorization, Content-Type, MCP-Protocol-Version, Mcp-Session-Id, Last-Event-ID",
        "Access-Control-Expose-Headers": "Mcp-Session-Id, WWW-Authenticate",
    ]

    static func json(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> HTTPListener.Response {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return .full(
            status: status, headers: cors.merging(["Content-Type": "application/json", "Cache-Control": "no-store"].merging(headers) { _, new in new }) { _, new in new },
            body: body)
    }

    static func oauthError(_ error: Error) -> HTTPListener.Response {
        let error = error as? RemoteAccess.OAuthError ?? .invalidRequest("\(error)")
        return json(["error": error.code, "error_description": error.message], status: error.status)
    }

    /// An `application/x-www-form-urlencoded` body.
    static func form(_ body: Data) -> [String: String] {
        var components = URLComponents()
        components.percentEncodedQuery = String(decoding: body, as: UTF8.self).replacingOccurrences(of: "+", with: "%20")
        var fields: [String: String] = [:]
        for item in components.queryItems ?? [] { fields[item.name] = item.value ?? "" }
        return fields
    }

    // MARK: MCP

    private func mcp(_ request: HTTPListener.Request) async -> HTTPListener.Response {
        let metadata = address.origin + "/.well-known/oauth-protected-resource" + address.path
        let bearer = request.headers["authorization"].flatMap { header -> String? in
            header.lowercased().hasPrefix("bearer ") ? String(header.dropFirst(7)).trimmingCharacters(in: .whitespaces) : nil
        }
        guard let bearer, case .valid(let grant) = access.validate(bearer) else {
            let challenge = bearer == nil
                ? #"Bearer resource_metadata="\#(metadata)""#
                : #"Bearer resource_metadata="\#(metadata)", error="invalid_token""#
            return Self.json(["error": "a bearer token is required"], status: 401, headers: ["WWW-Authenticate": challenge])
        }
        var headers: [String: String] = [:]
        for (name, value) in request.headers { headers[name] = value }
        let forwarded = HTTPRequest(method: request.method, headers: headers, body: request.body.isEmpty ? nil : request.body, path: address.endpoint)

        if let id = request.headers["mcp-session-id"] {
            guard let session = lock.withLock({ sessions[id] }), session.grantID == grant.id else {
                return Self.json(["jsonrpc": "2.0", "error": ["code": -32001, "message": "Session not found"], "id": NSNull()], status: 404)
            }
            session.lastUsed = Date()
            let response = await session.transport.handleRequest(forwarded)
            if request.method == "DELETE" { await end(id) }
            return Self.convert(response)
        }
        guard request.method == "POST" else {
            return Self.json(["jsonrpc": "2.0", "error": ["code": -32000, "message": "Bad Request: no session"], "id": NSNull()], status: 400)
        }
        await prune()
        let transport = StatefulHTTPServerTransport(validationPipeline: StandardValidationPipeline(validators: [
            AcceptHeaderValidator(mode: .sseRequired), ContentTypeValidator(), ProtocolVersionValidator(), SessionValidator(),
        ]))
        let toolbox = makeToolbox(grant.readOnly)
        let server = await MailMCPServer.make(toolbox: toolbox)
        let app = access.client(id: grant.clientID)?.name
        do {
            try await server.start(transport: transport) { clientInfo, _ in
                // The activity log names the app as its OAuth registration does ("Claude"), marked remote.
                toolbox.clientName = "\(app ?? clientInfo.title ?? clientInfo.name) (remote)"
            }
        } catch {
            return Self.json(["error": "could not start a session"], status: 500)
        }
        let response = await transport.handleRequest(forwarded)
        if let id = response.headers.first(where: { $0.key.lowercased() == "mcp-session-id" })?.value {
            lock.withLock { sessions[id] = Session(transport: transport, server: server, toolbox: toolbox, grantID: grant.id) }
        } else {
            await server.stop()
        }
        return Self.convert(response)
    }

    static func convert(_ response: HTTPResponse) -> HTTPListener.Response {
        let headers = cors.merging(response.headers) { _, new in new }
        if case .stream(let stream, _) = response { return .stream(status: 200, headers: headers, body: stream) }
        return .full(status: response.statusCode, headers: headers, body: response.bodyData ?? Data())
    }

    private func end(_ id: String) async {
        guard let session = lock.withLock({ sessions.removeValue(forKey: id) }) else { return }
        await session.server.stop()
        session.toolbox.activity?.flush()
    }

    /// Ends sessions idle for an hour or whose app was disconnected, and the oldest past the limit.
    private func prune(now: Date = Date()) async {
        let stale = lock.withLock { () -> [String] in
            var stale = sessions.filter { now.timeIntervalSince($0.value.lastUsed) > Self.sessionIdleLimit || !access.grantExists($0.value.grantID) }.map(\.key)
            let alive = sessions.filter { !stale.contains($0.key) }.sorted { $0.value.lastUsed < $1.value.lastUsed }
            if alive.count >= Self.maximumSessions { stale += alive.prefix(alive.count - Self.maximumSessions + 1).map(\.key) }
            return stale
        }
        for id in stale { await end(id) }
    }

    /// Ends every session (the server is stopping).
    public func stop() async {
        for id in lock.withLock({ Array(sessions.keys) }) { await end(id) }
    }

    // MARK: OAuth endpoints

    private func register(_ request: HTTPListener.Request) -> HTTPListener.Response {
        guard let metadata = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] else {
            return Self.oauthError(RemoteAccess.OAuthError.invalidClientMetadata("send the client's metadata as JSON"))
        }
        do {
            let client = try access.register(metadata)
            return Self.json([
                "client_id": client.id, "client_id_issued_at": Int(client.created.timeIntervalSince1970), "client_name": client.name,
                "redirect_uris": client.redirectURIs, "token_endpoint_auth_method": "none",
                "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"],
            ], status: 201)
        } catch {
            return Self.oauthError(error)
        }
    }

    private func token(_ request: HTTPListener.Request) -> HTTPListener.Response {
        let form = Self.form(request.body)
        do {
            var clientID = form["client_id"]
            if clientID == nil, let header = request.headers["authorization"], header.lowercased().hasPrefix("basic "),
               let decoded = Data(base64Encoded: String(header.dropFirst(6)).trimmingCharacters(in: .whitespaces)) {
                clientID = String(decoding: decoded, as: UTF8.self).split(separator: ":", maxSplits: 1).first.map(String.init)?.removingPercentEncoding
            }
            guard let clientID, access.client(id: clientID) != nil else { throw RemoteAccess.OAuthError.invalidClient("unknown client") }
            let tokens: RemoteAccess.Tokens
            switch form["grant_type"] {
            case "authorization_code":
                guard let code = form["code"] else { throw RemoteAccess.OAuthError.invalidRequest("code is missing") }
                if let resource = form["resource"], !isResource(resource) { throw RemoteAccess.OAuthError.invalidRequest("resource is not this server") }
                tokens = try access.exchange(code: code, clientID: clientID, redirectURI: form["redirect_uri"], verifier: form["code_verifier"])
            case "refresh_token":
                guard let refresh = form["refresh_token"] else { throw RemoteAccess.OAuthError.invalidRequest("refresh_token is missing") }
                tokens = try access.refresh(refresh, clientID: clientID)
            case nil:
                throw RemoteAccess.OAuthError.invalidRequest("grant_type is missing")
            default:
                throw RemoteAccess.OAuthError.unsupportedGrantType("the grants are authorization_code and refresh_token")
            }
            return Self.json([
                "access_token": tokens.access, "token_type": "Bearer", "expires_in": tokens.expiresIn, "refresh_token": tokens.refresh,
                "scope": "mail",
            ], headers: ["Pragma": "no-cache"])
        } catch {
            return Self.oauthError(error)
        }
    }

    /// RFC 8707's `resource`: this server's endpoint (or its address), with or without a final slash.
    func isResource(_ value: String) -> Bool {
        var value = value
        while value.hasSuffix("/") { value.removeLast() }
        return [address.resource, address.issuer, address.origin + address.path + "/mcp"].contains(value)
    }

    // MARK: Approval

    struct Authorization {
        var client: RemoteAccess.Client
        var redirectURI: String
        var redirectURIGiven: Bool
        var state: String?
        var challenge: String
    }

    enum AuthorizationCheck {
        case valid(Authorization)
        /// Shown on the page: without a known client and redirect URI, nothing may be sent anywhere.
        case refused(String)
        /// Sent back to the client, as its redirect URI's `error`.
        case redirect(String)
    }

    func checkAuthorization(_ parameters: [String: String]) -> AuthorizationCheck {
        func text(_ name: String) -> String? { parameters[name].flatMap { $0.isEmpty ? nil : $0 } }
        guard let clientID = text("client_id"), let client = access.client(id: clientID) else {
            return .refused("This app is not registered here, or its registration expired. Connect again from the app.")
        }
        let redirectURI: String
        if let given = text("redirect_uri") {
            guard client.redirectURIs.contains(given) else { return .refused("The address this app asked to return to is not one it registered.") }
            redirectURI = given
        } else {
            guard client.redirectURIs.count == 1 else { return .refused("The app did not say where to return to.") }
            redirectURI = client.redirectURIs[0]
        }
        let state = text("state")
        func back(_ error: String, _ description: String) -> AuthorizationCheck {
            .redirect(Self.redirect(redirectURI, [("error", error), ("error_description", description), ("state", state), ("iss", address.issuer)]))
        }
        guard text("response_type") == "code" else { return back("unsupported_response_type", "response_type is code") }
        guard let challenge = text("code_challenge"), text("code_challenge_method") == "S256", RemoteAccess.challengeIsValid(challenge) else {
            return back("invalid_request", "PKCE with S256 is required")
        }
        if let resource = text("resource"), !isResource(resource) { return back("invalid_target", "resource is not this server") }
        return .valid(Authorization(client: client, redirectURI: redirectURI, redirectURIGiven: text("redirect_uri") != nil, state: state, challenge: challenge))
    }

    static func redirect(_ uri: String, _ parameters: [(String, String?)]) -> String {
        guard var components = URLComponents(string: uri) else { return uri }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let query = parameters.compactMap { name, value in
            value.map { "\(name)=\($0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
        }.joined(separator: "&")
        components.percentEncodedQuery = [components.percentEncodedQuery, query].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: "&")
        return components.string ?? uri
    }

    /// Where approving sends the browser, as the page shows it.
    static func shownDestination(_ uri: String) -> String { URLComponents(string: uri)?.host ?? uri }

    private func authorizePage(_ request: HTTPListener.Request) -> HTTPListener.Response {
        switch checkAuthorization(request.query) {
        case .refused(let message):
            return AuthorizePage.response(AuthorizePage.refused(message: message, service: name), status: 400)
        case .redirect(let location):
            return .full(status: 302, headers: ["Location": location, "Cache-Control": "no-store"], body: Data())
        case .valid(let authorization):
            return AuthorizePage.response(AuthorizePage.consent(
                service: name, app: authorization.client.name, destination: Self.shownDestination(authorization.redirectURI),
                passcode: access.hasPasscode, mac: approvals.isAgentRunning(), base: address.path + "/oauth"))
        }
    }

    private struct Decision {
        var query: [String: String]
        var readOnly: Bool
        var passcode: String?
        var approve: Bool
    }

    private func decision(_ request: HTTPListener.Request) -> Decision? {
        guard let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any], let query = body["query"] as? String else { return nil }
        var components = URLComponents()
        components.percentEncodedQuery = query.hasPrefix("?") ? String(query.dropFirst()) : query
        var parameters: [String: String] = [:]
        for item in components.queryItems ?? [] { parameters[item.name] = item.value ?? "" }
        return Decision(
            query: parameters, readOnly: body["readOnly"] as? Bool ?? false, passcode: body["passcode"] as? String, approve: body["approve"] as? Bool ?? false)
    }

    private func codeRedirect(_ authorization: Authorization, readOnly: Bool) -> String {
        let code = access.issueCode(
            clientID: authorization.client.id, readOnly: readOnly, redirectURI: authorization.redirectURI,
            redirectURIGiven: authorization.redirectURIGiven, challenge: authorization.challenge)
        return Self.redirect(authorization.redirectURI, [("code", code), ("state", authorization.state), ("iss", address.issuer)])
    }

    /// The page's Allow with the passcode, or its Deny.
    private func approve(_ request: HTTPListener.Request) async -> HTTPListener.Response {
        guard let decision = decision(request) else { return Self.json(["error": "send the request and the answer as JSON"], status: 400) }
        let authorization: Authorization
        switch checkAuthorization(decision.query) {
        case .refused(let message): return Self.json(["error": message], status: 400)
        case .redirect(let location): return Self.json(["redirect": location])
        case .valid(let valid): authorization = valid
        }
        guard decision.approve else {
            return Self.json(["redirect": Self.redirect(authorization.redirectURI, [
                ("error", "access_denied"), ("error_description", "the user said no"), ("state", authorization.state), ("iss", address.issuer),
            ])])
        }
        let now = Date()
        let locked = lock.withLock { () -> TimeInterval? in
            failures.removeAll { now.timeIntervalSince($0) > Self.failureWindow }
            guard failures.count >= Self.maximumFailures, let oldest = failures.first else { return nil }
            return Self.failureWindow - now.timeIntervalSince(oldest)
        }
        if let locked {
            return Self.json(["error": "Too many wrong passcodes. Try again in \(Int(locked / 60) + 1) minutes, or approve on your Mac."], status: 429)
        }
        guard let passcode = decision.passcode, access.checkPasscode(passcode) else {
            lock.withLock { failures.append(now) }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            return Self.json(["error": access.hasPasscode ? "Wrong passcode." : "No passcode is set: approve on your Mac."], status: 403)
        }
        return Self.json(["redirect": codeRedirect(authorization, readOnly: decision.readOnly)])
    }

    /// The page's "Approve on my Mac": asks in the menu bar app; the page then polls the ticket.
    private func ask(_ request: HTTPListener.Request) -> HTTPListener.Response {
        guard let decision = decision(request) else { return Self.json(["error": "send the request as JSON"], status: 400) }
        guard case .valid(let authorization) = checkAuthorization(decision.query) else { return Self.json(["error": "this request is no longer valid"], status: 400) }
        guard approvals.isAgentRunning() else { return Self.json(["error": "The menu bar app is not running on the Mac."], status: 503) }
        let ticket = UUID()
        let readOnly = decision.readOnly
        lock.withLock {
            tickets = tickets.filter { Date().timeIntervalSince($0.value.created) < 900 }
            tickets[ticket] = Ticket(status: .pending, created: Date())
        }
        let what = readOnly
            ? "It may read your mail, and nothing else."
            : "It may read, organize and draft your mail. Sending and big changes still ask you here first."
        let approval = ApprovalRequest(
            id: UUID(), created: Date(), tool: "connect", client: authorization.client.name, from: nil,
            to: [Self.shownDestination(authorization.redirectURI)], cc: [], bcc: [],
            subject: "\(authorization.client.name) wants to connect to \(name)", bodyPreview: what, attachments: [], status: .pending, decided: nil,
            kind: .connect)
        let timeout = settings.current.approvalTimeout
        Task {
            let status = (try? await approvals.requestApproval(approval, timeout: timeout)) ?? .denied
            let redirect: String? = switch status {
            case .approved: codeRedirect(authorization, readOnly: readOnly)
            case .denied: Self.redirect(authorization.redirectURI, [
                ("error", "access_denied"), ("error_description", "the user said no"), ("state", authorization.state), ("iss", address.issuer),
            ])
            case .pending: nil
            }
            lock.withLock { tickets[ticket]?.status = status; tickets[ticket]?.redirect = redirect }
        }
        return Self.json(["ticket": ticket.uuidString])
    }

    private func poll(_ id: String) -> HTTPListener.Response {
        guard let id = UUID(uuidString: id), let ticket = lock.withLock({ tickets[id] }) else { return Self.json(["error": "unknown request"], status: 404) }
        if let redirect = ticket.redirect {
            lock.withLock { _ = tickets.removeValue(forKey: id) }
            return Self.json(["redirect": redirect])
        }
        // Unanswered in the menu bar app before its timeout: the page says so and offers to ask again.
        return Self.json(["status": ticket.status == .pending && Date().timeIntervalSince(ticket.created) < settings.current.approvalTimeout + 5 ? "pending" : "expired"])
    }
}

/// A value made on first use and kept: one Mail store for all of a remote server's sessions.
public final class LazyStore: @unchecked Sendable {
    private let lock = NSLock()
    private let make: () throws -> MailStore
    private var store: MailStore?

    public init(_ make: @escaping () throws -> MailStore) { self.make = make }

    public func get() throws -> MailStore {
        try lock.withLock {
            if let store { return store }
            let made = try make()
            store = made
            return made
        }
    }
}
