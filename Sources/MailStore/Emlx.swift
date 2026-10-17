import Foundation

/// Mail's on-disk message format: a decimal byte count line, that many bytes
/// of RFC 822 message, then an XML plist with Mail's own flags.
/// `.partial.emlx` files have attachment bodies stripped; those live under
/// `Attachments/<rowid>/<part>/<filename>` next to the `Messages` folder.
public struct EmlxFile: Sendable {
    public var url: URL
    public var isPartial: Bool
    /// The RFC 822 message bytes.
    public var message: Data

    public init(url: URL) throws {
        self.url = url
        isPartial = url.lastPathComponent.hasSuffix(".partial.emlx")
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        message = Self.extractMessage(data)
    }

    public init(url: URL, data: Data) {
        self.url = url
        isPartial = url.lastPathComponent.hasSuffix(".partial.emlx")
        message = Self.extractMessage(data)
    }

    static func extractMessage(_ data: Data) -> Data {
        guard let newline = data.firstIndex(of: 0x0A) else { return data }
        let countText = String(decoding: data[data.startIndex..<newline], as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        let start = data.index(after: newline)
        guard let count = Int(countText), count >= 0 else { return data[start...] }
        let end = min(data.endIndex, start + count)
        return Data(data[start..<end])
    }
}

/// Finds `.emlx` files and attachment folders for messages.
///
/// Layout: `<root>/<account>/<A.mbox>/<B.mbox>/<store-uuid>/Data/<d…>/Messages/<rowid>[.partial].emlx`
/// where `<d…>` are the decimal digits of `rowid / 1000` in reverse order
/// (rowid 142529 → `Data/2/4/1/Messages`; rowids below 1000 → `Data/Messages`).
public final class MessageFileLocator: @unchecked Sendable {
    private let root: URL
    private let lock = NSLock()
    private var storeDirectoryCache: [String: [URL]] = [:]

    public init(root: URL) { self.root = root }

    public static func dataSubpath(forRowID rowID: Int64) -> String {
        let bucket = rowID / 1000
        guard bucket > 0 else { return "Data" }
        return "Data/" + String(String(bucket).reversed()).map(String.init).joined(separator: "/")
    }

    /// Candidate `<store-uuid>` folders for a mailbox (usually exactly one).
    func storeDirectories(for mailbox: MailboxURL) -> [URL] {
        let key = mailbox.relativeDirectory
        lock.lock()
        if let cached = storeDirectoryCache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let mailboxDirectory = root.appending(path: key, directoryHint: .isDirectory)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: mailboxDirectory, includingPropertiesForKeys: nil)) ?? []
        let stores = entries.filter {
            UUID(uuidString: $0.lastPathComponent) != nil
                && FileManager.default.fileExists(atPath: $0.appending(path: "Data").path)
        }
        lock.lock()
        storeDirectoryCache[key] = stores
        lock.unlock()
        return stores
    }

    /// The `.emlx` (full preferred over partial) for `rowID` in `mailbox`, if downloaded.
    public func emlxURL(rowID: Int64, mailbox: MailboxURL) -> URL? {
        let subpath = Self.dataSubpath(forRowID: rowID) + "/Messages/"
        let fm = FileManager.default
        for store in storeDirectories(for: mailbox) {
            let full = store.appending(path: subpath + "\(rowID).emlx")
            if fm.fileExists(atPath: full.path) { return full }
            let partial = store.appending(path: subpath + "\(rowID).partial.emlx")
            if fm.fileExists(atPath: partial.path) { return partial }
        }
        return nil
    }

    /// Folder holding the attachment for `partID` of `rowID`, if Mail downloaded it separately.
    public func attachmentFile(rowID: Int64, mailbox: MailboxURL, partID: String) -> URL? {
        let subpath = Self.dataSubpath(forRowID: rowID) + "/Attachments/\(rowID)/\(partID)"
        for store in storeDirectories(for: mailbox) {
            let folder = store.appending(path: subpath, directoryHint: .isDirectory)
            if let file = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .first(where: { !$0.lastPathComponent.hasPrefix(".") })
            {
                return file
            }
        }
        return nil
    }
}
