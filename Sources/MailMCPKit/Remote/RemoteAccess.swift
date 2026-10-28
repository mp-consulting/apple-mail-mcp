import CommonCrypto
import CryptoKit
import Foundation

/// OAuth 2.1 for remote MCP clients (claude.ai and the Claude apps, through a tunnel): dynamic client registration
/// (RFC 7591), the authorization code grant with PKCE (S256 only), refresh tokens rotated at each use, revocation
/// (RFC 7009). There are no accounts: the person approves a connection with the passcode set in the menu bar app,
/// or with Allow in the menu bar app itself.
///
/// `remote-access.json` in the support folder (owner-only, shared with the menu bar app, which lists and disconnects
/// apps and sets the passcode) keeps the clients and grants with the SHA-256 of every token and the passcode's
/// PBKDF2 hash, so the file holds nothing usable. Authorization codes stay in the server's memory for five minutes.
public final class RemoteAccess: @unchecked Sendable {
    public struct Client: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var redirectURIs: [String]
        public var created: Date
    }

    /// What one approval gave one client, and its current tokens.
    public struct Grant: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var clientID: String
        /// Only the reading tools.
        public var readOnly: Bool
        public var created: Date
        public var lastUsed: Date?
        var accessHashes: [String]
        var accessExpires: Date
        var refreshHashes: [String]
        var refreshExpires: Date
        /// The refresh token the last refresh replaced, still taken for a minute (a client that lost the answer, or
        /// sent two refreshes at once). After that, it is a stolen copy and ends the grant.
        var previousRefreshHash: String?
        var previousUntil: Date?
        var codeHash: String?
    }

    public struct Passcode: Codable, Sendable, Equatable {
        var salt: String
        var hash: String
        var rounds: Int
    }

    public struct State: Codable, Sendable, Equatable {
        public var clients: [Client] = []
        public var grants: [Grant] = []
        public var passcode: Passcode?
        public init() {}
    }

    public struct Tokens: Sendable {
        public var access: String
        public var refresh: String
        public var expiresIn: Int
        public var grant: Grant
    }

    public enum Validation: Sendable, Equatable {
        case valid(Grant)
        case expired
        case unknown
    }

    struct Code: Sendable {
        var clientID: String
        var readOnly: Bool
        var redirectURI: String
        var redirectURIGiven: Bool
        var challenge: String
        var expires: Date
    }

    public static let accessPrefix = "ama_"
    public static let refreshPrefix = "amr_"
    public static let accessLifetime: TimeInterval = 3600
    public static let refreshLifetime: TimeInterval = 90 * 86_400
    static let codeLifetime: TimeInterval = 300
    static let refreshGrace: TimeInterval = 60
    static let maximumClients = 50
    static let unusedClientLifetime: TimeInterval = 86_400
    static let passcodeRounds = 310_000

    public static var defaultURL: URL { SharedPaths.supportDirectory.appending(path: "remote-access.json") }

    let file: SharedJSONFile<State>
    private let lock = NSLock()
    private var codes: [String: Code] = [:]

    public init(url: URL = RemoteAccess.defaultURL) {
        file = SharedJSONFile(url: url, empty: State())
    }

    public var state: State { file.value }
    public func client(id: String) -> Client? { state.clients.first { $0.id == id } }
    public var grants: [Grant] { state.grants.sorted { $0.created > $1.created } }

    // MARK: Passcode

    public var hasPasscode: Bool { state.passcode != nil }

    /// Sets the passcode (at least 8 characters), or removes it with nil; either way every grant stays.
    public func setPasscode(_ passcode: String?) throws {
        if let passcode {
            guard passcode.count >= 8 else { throw ToolError("The passcode needs at least 8 characters.") }
            let salt = Self.random(16)
            let derived = Self.pbkdf2(passcode, salt: salt, rounds: Self.passcodeRounds)
            try file.modify { $0.passcode = Passcode(salt: salt.base64EncodedString(), hash: derived.base64EncodedString(), rounds: Self.passcodeRounds) }
        } else {
            try file.modify { $0.passcode = nil }
        }
    }

    public func checkPasscode(_ candidate: String) -> Bool {
        guard let stored = state.passcode, let salt = Data(base64Encoded: stored.salt), let expected = Data(base64Encoded: stored.hash) else { return false }
        return Self.constantTimeEqual(Self.pbkdf2(candidate, salt: salt, rounds: stored.rounds), expected)
    }

    static func pbkdf2(_ password: String, salt: Data, rounds: Int) -> Data {
        var derived = Data(count: 32)
        let passwordBytes = Array(password.utf8)
        _ = derived.withUnsafeMutableBytes { out in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes.map { CChar(bitPattern: $0) }, passwordBytes.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds),
                    out.bindMemory(to: UInt8.self).baseAddress, 32)
            }
        }
        return derived
    }

    // MARK: Registration

    public enum OAuthError: Error, Equatable, Sendable {
        case invalidRequest(String)
        case invalidClient(String)
        case invalidGrant(String)
        case unsupportedGrantType(String)
        case invalidRedirectURI(String)
        case invalidClientMetadata(String)

        public var code: String {
            switch self {
            case .invalidRequest: "invalid_request"
            case .invalidClient: "invalid_client"
            case .invalidGrant: "invalid_grant"
            case .unsupportedGrantType: "unsupported_grant_type"
            case .invalidRedirectURI: "invalid_redirect_uri"
            case .invalidClientMetadata: "invalid_client_metadata"
            }
        }

        public var message: String {
            switch self {
            case .invalidRequest(let text), .invalidClient(let text), .invalidGrant(let text), .unsupportedGrantType(let text),
                 .invalidRedirectURI(let text), .invalidClientMetadata(let text): text
            }
        }

        public var status: Int { if case .invalidClient = self { 401 } else { 400 } }
    }

    /// Registers a public client (PKCE proves it; no secret) from its RFC 7591 metadata.
    public func register(_ metadata: [String: Any], now: Date = Date()) throws -> Client {
        guard let list = metadata["redirect_uris"] as? [Any], !list.isEmpty, list.count <= 10 else {
            throw OAuthError.invalidRedirectURI("redirect_uris lists one to ten addresses")
        }
        var redirects: [String] = []
        for entry in list {
            guard let uri = entry as? String, Self.acceptableRedirect(uri) else {
                throw OAuthError.invalidRedirectURI("a redirect URI is https, or http on this machine, without a fragment")
            }
            redirects.append(uri)
        }
        if let method = metadata["token_endpoint_auth_method"] as? String, method != "none" {
            throw OAuthError.invalidClientMetadata("only public clients (token_endpoint_auth_method none, with PKCE) are accepted")
        }
        if let grants = metadata["grant_types"] as? [Any], !grants.allSatisfy({ ["authorization_code", "refresh_token"].contains($0 as? String ?? "") }) {
            throw OAuthError.invalidClientMetadata("grant_types are authorization_code and refresh_token")
        }
        let name = ((metadata["client_name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) ? "" : String(name.prefix(80))
        let client = Client(id: UUID().uuidString.lowercased(), name: shown.isEmpty ? "An MCP client" : shown, redirectURIs: redirects, created: now)
        let added = try file.modify { state -> Bool in
            Self.prune(&state, now: now)
            if state.clients.count >= Self.maximumClients {
                let granted = Set(state.grants.map(\.clientID))
                guard let oldest = state.clients.indices.filter({ !granted.contains(state.clients[$0].id) })
                    .min(by: { state.clients[$0].created < state.clients[$1].created }) else { return false }
                state.clients.remove(at: oldest)
            }
            state.clients.append(client)
            return true
        }
        guard added else { throw OAuthError.invalidClientMetadata("too many apps are connected; disconnect one first") }
        return client
    }

    static func acceptableRedirect(_ uri: String) -> Bool {
        guard uri.count <= 2000, let components = URLComponents(string: uri), let scheme = components.scheme?.lowercased(), components.fragment == nil,
              let host = components.host, !host.isEmpty else { return false }
        switch scheme {
        case "https": return true
        case "http": return ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host.lowercased())
        default: return false
        }
    }

    private static func prune(_ state: inout State, now: Date) {
        state.grants.removeAll { $0.refreshExpires <= now }
        let granted = Set(state.grants.map(\.clientID))
        state.clients.removeAll { !granted.contains($0.id) && now.timeIntervalSince($0.created) > unusedClientLifetime }
    }

    // MARK: Codes and tokens

    public func issueCode(clientID: String, readOnly: Bool, redirectURI: String, redirectURIGiven: Bool, challenge: String, now: Date = Date()) -> String {
        let code = Self.randomToken()
        lock.withLock {
            codes = codes.filter { $0.value.expires > now }
            codes[Self.hash(code)] = Code(
                clientID: clientID, readOnly: readOnly, redirectURI: redirectURI, redirectURIGiven: redirectURIGiven, challenge: challenge,
                expires: now.addingTimeInterval(Self.codeLifetime))
        }
        return code
    }

    /// Trades a code for tokens: once, within five minutes, by its client, with the same redirect URI and the PKCE
    /// verifier of its challenge. A second try ends what the first one got.
    public func exchange(code: String, clientID: String, redirectURI: String?, verifier: String?, now: Date = Date()) throws -> Tokens {
        let hash = Self.hash(code)
        guard let issued = lock.withLock({ codes.removeValue(forKey: hash) }) else {
            try file.modify { $0.grants.removeAll { $0.codeHash == hash } }
            throw OAuthError.invalidGrant("the code is unknown, used or expired")
        }
        guard issued.expires > now else { throw OAuthError.invalidGrant("the code expired") }
        guard issued.clientID == clientID else { throw OAuthError.invalidGrant("the code was issued to another client") }
        guard redirectURI == issued.redirectURI || (redirectURI == nil && !issued.redirectURIGiven) else {
            throw OAuthError.invalidGrant("redirect_uri differs from the authorization request's")
        }
        guard let verifier, Self.verifierIsValid(verifier), Self.constantTimeEqual(Data(Self.challenge(for: verifier).utf8), Data(issued.challenge.utf8)) else {
            throw OAuthError.invalidGrant("code_verifier does not match the code challenge")
        }
        let access = Self.accessPrefix + Self.randomToken()
        let refresh = Self.refreshPrefix + Self.randomToken()
        let grant = Grant(
            id: UUID().uuidString.lowercased(), clientID: clientID, readOnly: issued.readOnly, created: now, lastUsed: now,
            accessHashes: [Self.hash(access)], accessExpires: now.addingTimeInterval(Self.accessLifetime),
            refreshHashes: [Self.hash(refresh)], refreshExpires: now.addingTimeInterval(Self.refreshLifetime), codeHash: hash)
        try file.modify { state in
            Self.prune(&state, now: now)
            state.grants.append(grant)
        }
        return Tokens(access: access, refresh: refresh, expiresIn: Int(Self.accessLifetime), grant: grant)
    }

    /// New tokens for a refresh token, which is replaced.
    public func refresh(_ token: String, clientID: String, now: Date = Date()) throws -> Tokens {
        let hash = Self.hash(token)
        let access = Self.accessPrefix + Self.randomToken()
        let refresh = Self.refreshPrefix + Self.randomToken()
        let grant = try file.modify { state -> Result<Grant, OAuthError> in
            guard let index = state.grants.firstIndex(where: { $0.refreshHashes.contains(hash) || $0.previousRefreshHash == hash }) else {
                return .failure(.invalidGrant("the refresh token is unknown or revoked"))
            }
            var grant = state.grants[index]
            guard grant.clientID == clientID else { return .failure(.invalidGrant("the refresh token was issued to another client")) }
            let current = grant.refreshHashes.contains(hash)
            if !current, (grant.previousUntil ?? .distantPast) <= now {
                state.grants.remove(at: index)
                return .failure(.invalidGrant("the refresh token was already used; connect again"))
            }
            guard grant.refreshExpires > now else { return .failure(.invalidGrant("the refresh token expired; connect again")) }
            if current {
                grant.previousRefreshHash = hash
                grant.previousUntil = now.addingTimeInterval(Self.refreshGrace)
                grant.refreshHashes = [Self.hash(refresh)]
                grant.accessHashes = [Self.hash(access)]
            } else {
                grant.refreshHashes = Array((grant.refreshHashes + [Self.hash(refresh)]).suffix(2))
                grant.accessHashes = Array((grant.accessHashes + [Self.hash(access)]).suffix(2))
            }
            grant.refreshExpires = now.addingTimeInterval(Self.refreshLifetime)
            grant.accessExpires = now.addingTimeInterval(Self.accessLifetime)
            grant.lastUsed = now
            state.grants[index] = grant
            return .success(grant)
        }.get()
        return Tokens(access: access, refresh: refresh, expiresIn: Int(Self.accessLifetime), grant: grant)
    }

    /// RFC 7009: a token of this client ends its grant; anything else is ignored.
    public func revoke(token: String, clientID: String) throws {
        let hash = Self.hash(token)
        try file.modify { $0.grants.removeAll { $0.clientID == clientID && ($0.accessHashes.contains(hash) || $0.refreshHashes.contains(hash) || $0.previousRefreshHash == hash) } }
    }

    /// The menu bar app's Disconnect.
    public func revoke(grant id: String) throws {
        try file.modify { $0.grants.removeAll { $0.id == id } }
    }

    public func revokeAll() throws {
        try file.modify { $0.grants.removeAll() }
    }

    /// The grant an access token belongs to. Its last use is noted at most every ten minutes, to keep writes rare.
    public func validate(_ presented: String, now: Date = Date()) -> Validation {
        guard presented.hasPrefix(Self.accessPrefix), presented.utf8.count <= 128 else { return .unknown }
        let hash = Self.hash(presented)
        guard let grant = state.grants.first(where: { $0.accessHashes.contains(hash) }) else { return .unknown }
        guard grant.accessExpires > now else { return .expired }
        if grant.lastUsed.map({ now.timeIntervalSince($0) >= 600 }) ?? true {
            try? file.modify { state in
                if let index = state.grants.firstIndex(where: { $0.id == grant.id }) { state.grants[index].lastUsed = now }
            }
        }
        return .valid(grant)
    }

    /// Whether a grant still exists (an open session ends once its app is disconnected).
    public func grantExists(_ id: String) -> Bool { state.grants.contains { $0.id == id } }

    // MARK: Primitives

    static func verifierIsValid(_ verifier: String) -> Bool {
        (43...128).contains(verifier.utf8.count) && verifier.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) || [0x2D, 0x2E, 0x5F, 0x7E].contains(byte)
        }
    }

    static func challengeIsValid(_ challenge: String) -> Bool {
        challenge.utf8.count == 43 && challenge.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) || byte == 0x2D || byte == 0x5F
        }
    }

    public static func challenge(for verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }

    static func hash(_ token: String) -> String { SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined() }

    static func random(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    static func randomToken() -> String { base64URL(random(32)) }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
