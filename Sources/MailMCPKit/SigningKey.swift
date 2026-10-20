import CryptoKit
import Foundation
import MailStore

/// Signs what the user approved, so a decision or a scheduled send counts only when the menu bar app or a
/// server of this bundle wrote it. Approvals and schedules are plain files that any process running as the
/// user can edit; without the key, from the Keychain, it cannot produce a valid signature.
public struct SigningKey: Sendable {
    let key: SymmetricKey

    public init(bytes: [UInt8]) {
        precondition(bytes.count == 32, "the signing key is 32 bytes")
        key = SymmetricKey(data: bytes)
    }

    public static let service = "apple-mail-mcp.approvals"
    public static let account = "signing-key"

    /// Reads the key from the Keychain, creating it on first use (see `KeychainSecret`).
    public static func fromKeychain() throws -> SigningKey {
        do {
            return SigningKey(bytes: try KeychainSecret.load(
                service: service, account: account, length: 32, label: "Apple Mail MCP approval key",
                description: "Signs the emails you approve in Apple Mail MCP"))
        } catch KeychainSecret.Failure.keychain(let status) {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            throw ToolError("The approval key is not available from the Keychain (\(message)), so nothing can be approved or scheduled.")
        } catch {
            throw ToolError("The approval key in the Keychain is malformed; delete \"Apple Mail MCP approval key\" in Keychain Access.")
        }
    }

    /// Base64 HMAC-SHA256 of `fields`, each length-prefixed so no two lists of fields sign alike.
    public func sign(_ fields: [String]) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: Self.canonical(fields), using: key)).base64EncodedString()
    }

    public func verify(_ signature: String?, _ fields: [String]) -> Bool {
        guard let signature, let code = Data(base64Encoded: signature) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(code, authenticating: Self.canonical(fields), using: key)
    }

    static func canonical(_ fields: [String]) -> Data {
        var data = Data()
        for field in fields {
            let bytes = Data(field.utf8)
            data.append(contentsOf: withUnsafeBytes(of: UInt32(bytes.count).bigEndian, Array.init))
            data.append(bytes)
        }
        return data
    }

    /// Dates are stored in whole seconds (ISO 8601), so they are signed in whole seconds.
    static func seconds(_ date: Date?) -> String { date.map { String(Int64($0.timeIntervalSince1970.rounded(.down))) } ?? "" }
    static func list(_ items: [String]) -> String { (try? JSONEncoder().encode(items)).map { String(decoding: $0, as: UTF8.self) } ?? "" }
}

/// Fetches the key once, on first use; tests pass a fixed one and never touch the Keychain.
public final class SigningKeyProvider: @unchecked Sendable {
    private let load: @Sendable () throws -> SigningKey
    private let lock = NSLock()
    private var cached: SigningKey?

    public init(_ load: @escaping @Sendable () throws -> SigningKey = SigningKey.fromKeychain) { self.load = load }

    public func key() throws -> SigningKey {
        try lock.withLock {
            if let cached { return cached }
            let key = try load()
            cached = key
            return key
        }
    }
}
