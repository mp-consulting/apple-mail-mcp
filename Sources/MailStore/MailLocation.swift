import Foundation

/// Where Mail keeps its data. Defaults to the newest `~/Library/Mail/V<n>`;
/// tests and the synthetic benchmark point it at a generated tree instead.
public struct MailLocation: Sendable, Hashable {
    /// `~/Library/Mail/V10`
    public var root: URL
    /// `~/Library/Accounts/Accounts4.sqlite`, used only to resolve account names.
    public var accountsDatabase: URL?

    public init(root: URL, accountsDatabase: URL? = nil) {
        self.root = root
        self.accountsDatabase = accountsDatabase
    }

    public var envelopeIndex: URL { root.appending(path: "MailData/Envelope Index") }

    public enum LocationError: Error, CustomStringConvertible {
        case notFound(String)
        case noAccess(String)

        public var description: String {
            switch self {
            case .notFound(let path):
                "Apple Mail data not found under \(path). Is Mail set up for this user?"
            case .noAccess(let path):
                """
                Cannot read \(path). Grant Full Disk Access to the app that launches this server \
                (System Settings → Privacy & Security → Full Disk Access), e.g. Claude, your terminal, \
                or "Apple Mail MCP.app".
                """
            }
        }
    }

    /// Finds the highest `V<n>` folder in `~/Library/Mail`. Honors `APPLE_MAIL_MCP_MAIL_ROOT`.
    public static func discover(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> MailLocation {
        let accounts = home.appending(path: "Library/Accounts/Accounts4.sqlite")
        if let override = environment["APPLE_MAIL_MCP_MAIL_ROOT"], !override.isEmpty {
            return MailLocation(root: URL(filePath: (override as NSString).expandingTildeInPath), accountsDatabase: accounts)
        }
        let mail = home.appending(path: "Library/Mail")
        let entries: [String]
        do {
            entries = try FileManager.default.contentsOfDirectory(atPath: mail.path)
        } catch let error as NSError where error.code == NSFileReadNoPermissionError {
            throw LocationError.noAccess(mail.path)
        } catch {
            throw LocationError.notFound(mail.path)
        }
        let versions = entries.compactMap { name -> Int? in
            guard name.hasPrefix("V"), let n = Int(name.dropFirst()) else { return nil }
            return n
        }
        guard let newest = versions.max() else { throw LocationError.notFound(mail.path) }
        let root = mail.appending(path: "V\(newest)")
        let location = MailLocation(root: root, accountsDatabase: accounts)
        if !FileManager.default.isReadableFile(atPath: location.envelopeIndex.path) {
            throw LocationError.noAccess(location.envelopeIndex.path)
        }
        return location
    }
}
