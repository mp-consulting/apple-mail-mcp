import Foundation
import Security

/// The secret that turns indexed words into opaque tokens (see ``BodyIndex``).
///
/// Mail's own store is behind Full Disk Access; the index file is not. Without this key the
/// index holds no text, only keyed hashes, so a process that can read the file still cannot
/// read mail. The key lives in the login Keychain, where macOS asks before handing it to any
/// app other than the ones that created it.
public struct BodyIndexKey: Sendable, Equatable {
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) {
        precondition(bytes.count == 16, "the body index key is 16 bytes")
        self.bytes = bytes
    }

    public static func random() -> BodyIndexKey { BodyIndexKey(bytes: KeychainSecret.random(16)) }

    /// The key for an index at `url`. The real index (the default location) always uses the login Keychain's. An
    /// index elsewhere, which `mail-bench` builds on generated or throwaway data, may use a fixed key from
    /// `APPLE_MAIL_MCP_TEST_INDEX_KEY` (32 hex digits) instead, so the server it starts reads that index without a
    /// Keychain prompt. Where the index is decides, not the environment alone: no variable makes the real index
    /// use a key someone else knows.
    public static func provider(forIndexAt url: URL) -> @Sendable () throws -> BodyIndexKey {
        if let key = testKey(forIndexAt: url, environment: ProcessInfo.processInfo.environment) { return { key } }
        return fromKeychain
    }

    static func testKey(forIndexAt url: URL, environment: [String: String]) -> BodyIndexKey? {
        let real = BodyIndex.defaultURL().standardizedFileURL.resolvingSymlinksInPath().path
        guard url.standardizedFileURL.resolvingSymlinksInPath().path != real,
            let hex = environment["APPLE_MAIL_MCP_TEST_INDEX_KEY"]
        else { return nil }
        return BodyIndexKey(hex: hex)
    }

    /// 32 hex digits; nil for anything else.
    public init?(hex: String) {
        let digits = Array(hex.utf8)
        guard digits.count == 32 else { return nil }
        var bytes: [UInt8] = []
        for index in stride(from: 0, to: 32, by: 2) {
            guard let byte = UInt8(String(decoding: digits[index..<index + 2], as: UTF8.self), radix: 16) else { return nil }
            bytes.append(byte)
        }
        self.init(bytes: bytes)
    }

    public var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }

    static let service = "apple-mail-mcp.body-index"
    static let account = "token-key"

    /// Reads the key from the login Keychain, creating it on first use.
    ///
    /// When this runs from the app bundle, the item trusts both the menu bar app and the server
    /// next to it, so neither is prompted for a key the other created.
    public static func fromKeychain() throws -> BodyIndexKey {
        do {
            return BodyIndexKey(bytes: try KeychainSecret.load(
                service: service, account: account, length: 16, label: "Apple Mail MCP search index key",
                description: "Unlocks the body search index of Apple Mail MCP"))
        } catch KeychainSecret.Failure.keychain(let status) {
            throw BodyIndexKeyError.keychain(status)
        } catch {
            throw BodyIndexKeyError.malformed
        }
    }
}

/// A random secret in the login Keychain, created on first use and shared by the executables of this app bundle.
public enum KeychainSecret {
    public enum Failure: Error, Sendable {
        case keychain(OSStatus)
        case malformed
    }

    public static func random(_ length: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return bytes
    }

    public static func load(service: String, account: String, length: Int, label: String, description: String) throws -> [UInt8] {
        if let existing = try read(service: service, account: account, length: length) { return existing }
        let bytes = random(length)
        var item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: label,
            kSecAttrDescription as String: description,
            kSecValueData as String: Data(bytes),
        ]
        if let access = bundleAccess(label) { item[kSecAttrAccess as String] = access }
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem, let raced = try read(service: service, account: account, length: length) { return raced }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        return bytes
    }

    private static func read(service: String, account: String, length: Int) throws -> [UInt8]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        guard let data = result as? Data, data.count == length else { throw Failure.malformed }
        return [UInt8](data)
    }

    /// An access list naming every executable in this app bundle's Contents/MacOS, or nil
    /// outside a bundle (the creating program alone is then trusted, the Keychain default).
    private static func bundleAccess(_ label: String) -> SecAccess? {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let directory = executable.deletingLastPathComponent()
        guard directory.lastPathComponent == "MacOS", directory.deletingLastPathComponent().lastPathComponent == "Contents",
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return nil }
        let trusted: [SecTrustedApplication] = names.compactMap { name in
            var app: SecTrustedApplication?
            let path = directory.appending(path: name).path
            return SecTrustedApplicationCreateFromPath(path, &app) == errSecSuccess ? app : nil
        }
        guard !trusted.isEmpty else { return nil }
        var access: SecAccess?
        let status = SecAccessCreate(label as CFString, trusted as CFArray, &access)
        return status == errSecSuccess ? access : nil
    }
}

public enum BodyIndexKeyError: Error, CustomStringConvertible, Sendable {
    case keychain(OSStatus)
    case malformed

    public var description: String {
        switch self {
        case .keychain(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "The search index key is not available from the Keychain (\(message)). Body searches scan messages instead."
        case .malformed:
            return "The search index key in the Keychain is malformed; delete \"Apple Mail MCP search index key\" in Keychain Access to start over."
        }
    }
}
