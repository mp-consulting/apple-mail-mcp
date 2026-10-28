import CryptoKit
import Foundation
import Testing

@testable import MailMCPKit

/// The remote server end to end on a real socket: discovery under a path, registration, approval with the passcode
/// and in the menu bar app, PKCE, tokens, and MCP sessions bound to their grant.
@Suite(.serialized)
struct RemoteTests {
    struct Remote {
        let harness: Harness
        let access: RemoteAccess
        let server: RemoteServer
        let listener: HTTPListener
        let base: String
        let readOnlyCalls: ReadOnlyRecorder

        init(address: String = "https://mcp.example.com/me/mail") async throws {
            harness = try Harness()
            access = RemoteAccess(url: harness.support.appending(path: "remote-access.json"))
            let recorder = ReadOnlyRecorder()
            readOnlyCalls = recorder
            let toolbox = harness.toolbox
            server = RemoteServer(
                address: RemoteServer.Address(address)!, access: access, approvals: harness.approvals,
                settings: SettingsProvider(url: harness.support.appending(path: "settings.json"))
            ) { readOnly in
                recorder.append(readOnly)
                return toolbox
            }
            let server = server
            listener = try HTTPListener(host: "127.0.0.1", port: 0) { await server.handle($0) }
            try await listener.start()
            base = "http://127.0.0.1:\(listener.port!)"
        }

        func stop() async {
            await server.stop()
            listener.stop()
            harness.remove()
        }

        func request(
            _ method: String, _ path: String, json: Any? = nil, form: [String: String]? = nil, headers: [String: String] = [:]
        ) async throws -> (status: Int, headers: [String: String], body: Data) {
            var request = URLRequest(url: URL(string: base + path)!)
            request.httpMethod = method
            if let json {
                request.httpBody = try JSONSerialization.data(withJSONObject: json)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            if let form {
                request.httpBody = Data(form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)" }.joined(separator: "&").utf8)
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            }
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as! HTTPURLResponse
            var fields: [String: String] = [:]
            for (name, value) in http.allHeaderFields { fields[String(describing: name).lowercased()] = String(describing: value) }
            return (http.statusCode, fields, data)
        }

        func object(_ data: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] }

        /// Registers a client and returns its id.
        func register() async throws -> String {
            let (status, _, body) = try await request(
                "POST", "/me/mail/oauth/register",
                json: ["client_name": "Claude", "redirect_uris": ["https://claude.ai/api/mcp/auth_callback"], "token_endpoint_auth_method": "none"])
            #expect(status == 201)
            return object(body)["client_id"] as! String
        }

        func query(client: String, challenge: String, state: String = "xyz") -> String {
            var components = URLComponents()
            components.queryItems = [
                .init(name: "response_type", value: "code"), .init(name: "client_id", value: client),
                .init(name: "redirect_uri", value: "https://claude.ai/api/mcp/auth_callback"), .init(name: "code_challenge", value: challenge),
                .init(name: "code_challenge_method", value: "S256"), .init(name: "state", value: state),
                .init(name: "resource", value: "https://mcp.example.com/me/mail"),
            ]
            return "?" + components.percentEncodedQuery!
        }

        /// The code in a redirect, after checking its state and issuer.
        func code(in redirect: String) -> String? {
            let items = URLComponents(string: redirect)?.queryItems ?? []
            #expect(items.first { $0.name == "state" }?.value == "xyz")
            #expect(items.first { $0.name == "iss" }?.value == "https://mcp.example.com/me/mail")
            return items.first { $0.name == "code" }?.value
        }

        /// The whole sign-in with the passcode; returns the token response.
        func signIn(readOnly: Bool = false) async throws -> [String: Any] {
            try access.setPasscode("correct horse")
            let client = try await register()
            let verifier = String(repeating: "v", count: 50)
            let challenge = RemoteAccess.challenge(for: verifier)
            let query = query(client: client, challenge: challenge)
            let (_, _, answer) = try await request(
                "POST", "/me/mail/oauth/approve", json: ["query": query, "approve": true, "passcode": "correct horse", "readOnly": readOnly])
            let issued = try #require(self.code(in: object(answer)["redirect"] as? String ?? ""))
            let (status, _, tokens) = try await request(
                "POST", "/me/mail/oauth/token",
                form: [
                    "grant_type": "authorization_code", "code": issued, "client_id": client, "code_verifier": verifier,
                    "redirect_uri": "https://claude.ai/api/mcp/auth_callback", "resource": "https://mcp.example.com/me/mail",
                ])
            #expect(status == 200)
            var result = object(tokens)
            result["client_id"] = client
            return result
        }

        /// The JSON-RPC messages of a Server-Sent Events body (or a plain JSON one).
        func messages(_ body: Data) -> [[String: Any]] {
            let text = String(decoding: body, as: UTF8.self)
            if text.hasPrefix("{") { return [object(body)] }
            return text.split(separator: "\n").compactMap { line in
                line.hasPrefix("data:") ? object(Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)) : nil
            }.filter { !$0.isEmpty }
        }

        static let mcpHeaders = ["Accept": "application/json, text/event-stream"]
        nonisolated(unsafe) static let initialize: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "claude-ai", "version": "1"]],
        ]
    }

    final class ReadOnlyRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Bool] = []
        func append(_ value: Bool) { lock.withLock { values.append(value) } }
        var all: [Bool] { lock.withLock { values } }
    }

    @Test func addressKeepsItsPath() throws {
        let address = try #require(RemoteServer.Address("https://MCP.example.com/me/mail/"))
        #expect(address.host == "mcp.example.com")
        #expect(address.path == "/me/mail")
        #expect(address.resource == "https://mcp.example.com/me/mail")
        #expect(RemoteServer.Address("https://mcp.example.com")?.resource == "https://mcp.example.com/mcp")
        #expect(RemoteServer.Address("ftp://x/y") == nil)
        #expect(RemoteServer.Address("https://x/y?z=1") == nil)
    }

    @Test func discoveryLivesUnderThePath() async throws {
        let remote = try await Remote()
        defer { Task { await remote.stop() } }
        let (status, headers, _) = try await remote.request("POST", "/me/mail", json: Remote.initialize, headers: Remote.mcpHeaders)
        #expect(status == 401)
        #expect(headers["www-authenticate"] == #"Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource/me/mail""#)

        let (_, _, resource) = try await remote.request("GET", "/.well-known/oauth-protected-resource/me/mail")
        #expect(remote.object(resource)["resource"] as? String == "https://mcp.example.com/me/mail")
        #expect(remote.object(resource)["authorization_servers"] as? [String] == ["https://mcp.example.com/me/mail"])
        for path in ["/.well-known/oauth-authorization-server/me/mail", "/me/mail/.well-known/oauth-authorization-server"] {
            let (status, _, metadata) = try await remote.request("GET", path)
            #expect(status == 200)
            #expect(remote.object(metadata)["issuer"] as? String == "https://mcp.example.com/me/mail")
            #expect(remote.object(metadata)["token_endpoint"] as? String == "https://mcp.example.com/me/mail/oauth/token")
        }
        // Another server's path on the same host is not ours.
        #expect(try await remote.request("GET", "/.well-known/oauth-authorization-server/homeswift").status == 404)
        #expect(try await remote.request("GET", "/.well-known/oauth-authorization-server").status == 404)
    }

    @Test func onlyThePublishedHostIsServed() async throws {
        let remote = try await Remote()
        defer { Task { await remote.stop() } }
        #expect(remote.server.hostAllowed("mcp.example.com"))
        #expect(remote.server.hostAllowed("MCP.example.com"))
        #expect(remote.server.hostAllowed("127.0.0.1:8590"))
        #expect(remote.server.hostAllowed("[::1]:8590"))
        #expect(!remote.server.hostAllowed("evil.example"))
        #expect(!remote.server.hostAllowed("mcp.example.com.evil.example"))
        #expect(!remote.server.hostAllowed(nil))
    }

    @Test func passcodeSignInOpensAnMCPSession() async throws {
        let remote = try await Remote()
        defer { Task { await remote.stop() } }
        let tokens = try await remote.signIn()
        let access = try #require(tokens["access_token"] as? String)
        #expect(access.hasPrefix(RemoteAccess.accessPrefix))
        #expect(tokens["expires_in"] as? Int == 3600)

        let auth = Remote.mcpHeaders.merging(["Authorization": "Bearer \(access)"]) { _, new in new }
        let (status, headers, body) = try await remote.request("POST", "/me/mail", json: Remote.initialize, headers: auth)
        #expect(status == 200)
        let session = try #require(headers["mcp-session-id"])
        #expect(remote.messages(body).first?["result"] != nil)
        #expect(remote.harness.toolbox.clientName == "Claude (remote)")

        var inSession = auth
        inSession["Mcp-Session-Id"] = session
        inSession["MCP-Protocol-Version"] = "2025-06-18"
        _ = try await remote.request("POST", "/me/mail", json: ["jsonrpc": "2.0", "method": "notifications/initialized"], headers: inSession)
        let (_, _, list) = try await remote.request("POST", "/me/mail", json: ["jsonrpc": "2.0", "id": 2, "method": "tools/list"], headers: inSession)
        let tools = (remote.messages(list).first?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        #expect(tools.contains { $0["name"] as? String == "search_messages" })
        #expect(remote.readOnlyCalls.all == [false])

        // Another grant cannot use this session.
        let other = try await remote.signIn()
        var stolen = inSession
        stolen["Authorization"] = "Bearer \(other["access_token"] as! String)"
        #expect(try await remote.request("POST", "/me/mail", json: ["jsonrpc": "2.0", "id": 3, "method": "tools/list"], headers: stolen).status == 404)

        // Disconnecting the app ends its access.
        guard case .valid(let grant) = remote.access.validate(access) else { Issue.record("token not valid"); return }
        try remote.access.revoke(grant: grant.id)
        #expect(try await remote.request("POST", "/me/mail", json: ["jsonrpc": "2.0", "id": 4, "method": "tools/list"], headers: inSession).status == 401)
    }

    @Test func readOnlyGrantGivesAReadOnlyToolbox() async throws {
        let remote = try await Remote()
        defer { Task { await remote.stop() } }
        let tokens = try await remote.signIn(readOnly: true)
        let auth = Remote.mcpHeaders.merging(["Authorization": "Bearer \(tokens["access_token"] as! String)"]) { _, new in new }
        #expect(try await remote.request("POST", "/me/mail", json: Remote.initialize, headers: auth).status == 200)
        #expect(remote.readOnlyCalls.all == [true])
    }

    @Test func refreshRotatesAndCatchesReuse() async throws {
        let remote = try await Remote()
        defer { Task { await remote.stop() } }
        let tokens = try await remote.signIn()
        let client = tokens["client_id"] as! String
        let first = tokens["refresh_token"] as! String
        let (status, _, body) = try await remote.request("POST", "/me/mail/oauth/token", form: ["grant_type": "refresh_token", "refresh_token": first, "client_id": client])
        #expect(status == 200)
        let second = remote.object(body)["refresh_token"] as! String
        #expect(second != first)
        // Within the grace minute, the replaced token still works (a client that lost the answer tries again).
        _ = try remote.access.refresh(first, clientID: client, now: Date().addingTimeInterval(10))
        // Past it, the replaced token again means someone else has a copy, and the grant ends.
        #expect(throws: RemoteAccess.OAuthError.self) { try remote.access.refresh(first, clientID: client, now: Date().addingTimeInterval(120)) }
        #expect(remote.access.grants.isEmpty)
    }

    @Test func wrongVerifierAndReusedCodeFail() async throws {
        let remote = try await Remote()
        defer { Task { await remote.stop() } }
        try remote.access.setPasscode("correct horse")
        let client = try await remote.register()
        let verifier = String(repeating: "w", count: 60)
        let query = remote.query(client: client, challenge: RemoteAccess.challenge(for: verifier))
        let (_, _, answer) = try await remote.request("POST", "/me/mail/oauth/approve", json: ["query": query, "approve": true, "passcode": "correct horse"])
        let issued = try #require(remote.code(in: remote.object(answer)["redirect"] as! String))
        let wrong = try await remote.request(
            "POST", "/me/mail/oauth/token",
            form: ["grant_type": "authorization_code", "code": issued, "client_id": client, "code_verifier": String(repeating: "x", count: 60), "redirect_uri": "https://claude.ai/api/mcp/auth_callback"])
        #expect(wrong.status == 400)
        #expect(remote.object(wrong.body)["error"] as? String == "invalid_grant")
        // The code was spent by the failed try.
        let again = try await remote.request(
            "POST", "/me/mail/oauth/token",
            form: ["grant_type": "authorization_code", "code": issued, "client_id": client, "code_verifier": verifier, "redirect_uri": "https://claude.ai/api/mcp/auth_callback"])
        #expect(again.status == 400)
    }

    @Test func wrongPasscodesLockThePageOut() async throws {
        let remote = try await Remote()
        defer { Task { await remote.stop() } }
        try remote.access.setPasscode("correct horse")
        let client = try await remote.register()
        let query = remote.query(client: client, challenge: RemoteAccess.challenge(for: String(repeating: "v", count: 50)))
        for _ in 0..<RemoteServer.maximumFailures {
            #expect(try await remote.request("POST", "/me/mail/oauth/approve", json: ["query": query, "approve": true, "passcode": "nope"]).status == 403)
        }
        // Even the right passcode waits now.
        #expect(try await remote.request("POST", "/me/mail/oauth/approve", json: ["query": query, "approve": true, "passcode": "correct horse"]).status == 429)
    }

    @Test func menuBarApprovalSendsTheBrowserBack() async throws {
        let remote = try await Remote()
        defer { Task { await remote.stop() } }
        remote.harness.approvals.beat()
        let client = try await remote.register()
        let query = remote.query(client: client, challenge: RemoteAccess.challenge(for: String(repeating: "v", count: 50)))
        let page = try await remote.request("GET", "/me/mail/oauth/authorize" + query)
        #expect(page.status == 200)
        let html = String(decoding: page.body, as: UTF8.self)
        #expect(html.contains("Connect Claude to Apple Mail?"))
        #expect(html.contains("Approve on my Mac"))
        #expect(page.headers["content-security-policy"]?.contains("frame-ancestors 'none'") == true)

        let (_, _, asked) = try await remote.request("POST", "/me/mail/oauth/ask", json: ["query": query])
        let ticket = try #require(remote.object(asked)["ticket"] as? String)
        var pending: [ApprovalRequest] = []
        for _ in 0..<40 where pending.isEmpty {
            try await Task.sleep(nanoseconds: 50_000_000)
            pending = remote.harness.approvals.pending()
        }
        let request = try #require(pending.first)
        #expect(request.action == .connect)
        #expect(request.to == ["claude.ai"])
        try remote.harness.approvals.decide(request.id, approve: true)
        var redirect: String?
        for _ in 0..<40 where redirect == nil {
            try await Task.sleep(nanoseconds: 100_000_000)
            redirect = remote.object(try await remote.request("GET", "/me/mail/oauth/ask/\(ticket)").body)["redirect"] as? String
        }
        #expect(remote.code(in: try #require(redirect)) != nil)
    }

    @Test func unknownClientsAndRedirectsAreRefusedOnThePage() async throws {
        let remote = try await Remote()
        defer { Task { await remote.stop() } }
        let unknown = try await remote.request("GET", "/me/mail/oauth/authorize" + remote.query(client: "nobody", challenge: String(repeating: "a", count: 43)))
        #expect(unknown.status == 400)
        let client = try await remote.register()
        var components = URLComponents(string: "/me/mail/oauth/authorize" + remote.query(client: client, challenge: String(repeating: "a", count: 43)))!
        components.queryItems = components.queryItems!.map { $0.name == "redirect_uri" ? .init(name: "redirect_uri", value: "https://evil.example/cb") : $0 }
        #expect(try await remote.request("GET", components.string!).status == 400)
        // Registration refuses addresses a browser could be sent to harmfully.
        let bad = try await remote.request("POST", "/me/mail/oauth/register", json: ["redirect_uris": ["javascript:alert(1)"]])
        #expect(bad.status == 400)
    }

    @Test func storeKeepsNoUsableSecret() async throws {
        let remote = try await Remote()
        defer { Task { await remote.stop() } }
        let tokens = try await remote.signIn()
        let file = String(decoding: try Data(contentsOf: remote.access.file.url), as: UTF8.self)
        #expect(!file.contains(tokens["access_token"] as! String))
        #expect(!file.contains(tokens["refresh_token"] as! String))
        #expect(!file.contains("correct horse"))
        let mode = try FileManager.default.attributesOfItem(atPath: remote.access.file.url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }
}
