import Foundation

/// A JSON file shared by every server process and the menu bar app: owner-only, read-modify-write under a
/// lock file so two writers never lose each other's change.
final class SharedJSONFile<Value: Codable & Sendable>: @unchecked Sendable {
    let url: URL
    private let empty: Value
    private let lock = NSLock()

    init(url: URL, empty: Value) {
        self.url = url
        self.empty = empty
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    var value: Value {
        lock.withLock { load() }
    }

    private func load() -> Value {
        guard let data = try? Data(contentsOf: url) else { return empty }
        return (try? Self.decoder.decode(Value.self, from: data)) ?? empty
    }

    /// Applies `change` to the current contents and saves them; returns what `change` returned.
    @discardableResult
    func modify<T>(_ change: (inout Value) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        SharedPaths.ensureDirectory(url.deletingLastPathComponent())
        let lockFD = open(url.path + ".lock", O_WRONLY | O_CREAT, 0o600)
        if lockFD >= 0 { flock(lockFD, LOCK_EX) }
        defer {
            if lockFD >= 0 {
                flock(lockFD, LOCK_UN)
                close(lockFD)
            }
        }
        var current = load()
        let result = try change(&current)
        // A change that was not saved did not happen: callers (claiming due sends, the undo journal) must know.
        try Self.encoder.encode(current).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return result
    }
}
