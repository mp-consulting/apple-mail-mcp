import Foundation

/// One tool call, as shown in the menu bar app. Never contains message bodies.
public struct ActivityEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID = UUID()
    public var date: Date
    public var pid: Int32
    public var client: String?
    public var tool: String
    public var ok: Bool
    public var milliseconds: Int
    /// Short outcome, e.g. "12 results" or "moved 3 to Archive".
    public var summary: String
    public var isWrite: Bool
    /// `message://` link of the message the call was about, when there is one.
    public var link: String?

    public init(
        date: Date, pid: Int32, client: String?, tool: String, ok: Bool, milliseconds: Int, summary: String, isWrite: Bool,
        link: String? = nil
    ) {
        self.link = link
        self.date = date
        self.pid = pid
        self.client = client
        self.tool = tool
        self.ok = ok
        self.milliseconds = milliseconds
        self.summary = summary
        self.isWrite = isWrite
    }
}

/// Append-only JSON-lines journal shared by all server processes.
public final class ActivityLog: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private let maxBytes: Int

    public init(url: URL = SharedPaths.activityLog, maxBytes: Int = 1_000_000) {
        self.url = url
        self.maxBytes = maxBytes
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public func append(_ entry: ActivityEntry) {
        guard var line = try? Self.encoder.encode(entry) else { return }
        line.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        SharedPaths.ensureDirectory(url.deletingLastPathComponent())
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
        if size > maxBytes {
            let rotated = url.appendingPathExtension("1")
            try? FileManager.default.removeItem(at: rotated)
            try? FileManager.default.moveItem(at: url, to: rotated)
        }
        // O_APPEND writes of one line are atomic across processes.
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { return }
        line.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
        close(fd)
    }

    /// Most recent entries first. Reads only the end of the log, growing the window until it holds `limit` lines.
    public func recent(limit: Int = 50) -> [ActivityEntry] {
        var entries: [ActivityEntry] = []
        // The current file, then the rotated one if more entries are needed.
        for file in [url, url.appendingPathExtension("1")] {
            guard entries.count < limit else { break }
            for line in Self.lastLines(of: file, count: limit - entries.count) {
                if let entry = try? Self.decoder.decode(ActivityEntry.self, from: line) { entries.append(entry) }
                if entries.count >= limit { break }
            }
        }
        return entries
    }

    /// Size and modification date of the log and its rotated copy: when equal, `recent` returns the same entries.
    public struct Stamp: Equatable, Sendable {
        fileprivate var parts: [[Int64]]
    }

    public func stamp() -> Stamp {
        Stamp(parts: [url, url.appendingPathExtension("1")].map { file in
            var info = stat()
            guard stat(file.path, &info) == 0 else { return [] }
            return [Int64(info.st_size), Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec), Int64(info.st_ino)]
        })
    }

    /// Up to `count` complete lines from the end of `file`, newest first.
    static func lastLines(of file: URL, count: Int) -> [Data] {
        guard count > 0, let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return [] }
        var window: UInt64 = 32 * 1024
        while true {
            let start = size > window ? size - window : 0
            guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.read(upToCount: Int(size - start))
            else { return [] }
            var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
            // Mid-file, the first line is cut off.
            if start > 0, !lines.isEmpty { lines.removeFirst() }
            if lines.count >= count || start == 0 { return lines.suffix(count).reversed().map { Data($0) } }
            window *= 4
        }
    }
}

/// A request to send mail, waiting for the user's decision in the menu bar app.
public struct ApprovalRequest: Codable, Sendable, Hashable, Identifiable {
    public enum Status: String, Codable, Sendable { case pending, approved, denied }
    /// What the user is asked to allow.
    public enum Kind: String, Codable, Sendable {
        /// Send an email (now, or at `sendAt`).
        case send
        /// Move or trash many messages; `subject` says what, `bodyPreview` lists them.
        case change
        /// Unsubscribe from a mailing list; `to` holds where the request goes.
        case unsubscribe
    }

    public var id: UUID
    public var created: Date
    public var tool: String
    public var client: String?
    public var from: String?
    public var to: [String]
    public var cc: [String]
    public var bcc: [String]
    public var subject: String
    public var bodyPreview: String
    public var attachments: [String]
    public var status: Status
    public var decided: Date?
    /// For a reply or forward: the original message, to look at before deciding.
    public var originalLink: String?
    /// Nil for requests written by older servers, which only asked about sending.
    public var kind: Kind?
    /// A scheduled send: when it goes out.
    public var sendAt: Date?
    /// The menu bar app's signature over the decision and everything shown (see ``SigningKey``).
    public var signature: String?

    public var action: Kind { kind ?? .send }

    /// What a decision signs: the request as the server wrote it, the answer and when it was given.
    func signedFields(status: Status, decided: Date?) -> [String] {
        [
            "approval", id.uuidString, status.rawValue, SigningKey.seconds(decided), tool, action.rawValue, from ?? "",
            SigningKey.list(to), SigningKey.list(cc), SigningKey.list(bcc), subject, bodyPreview, SigningKey.list(attachments),
            SigningKey.seconds(sendAt), originalLink ?? "",
        ]
    }

    public init(
        id: UUID, created: Date, tool: String, client: String?, from: String?, to: [String], cc: [String], bcc: [String],
        subject: String, bodyPreview: String, attachments: [String], status: Status, decided: Date?, originalLink: String? = nil,
        kind: Kind = .send, sendAt: Date? = nil
    ) {
        self.originalLink = originalLink
        self.kind = kind
        self.sendAt = sendAt
        self.id = id
        self.created = created
        self.tool = tool
        self.client = client
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.bodyPreview = bodyPreview
        self.attachments = attachments
        self.status = status
        self.decided = decided
    }
}

/// File-based approval queue: the server writes a request, the menu bar app
/// flips its status, the server polls. Works across any number of processes.
public final class ApprovalCenter: @unchecked Sendable {
    public let directory: URL
    public let heartbeat: URL
    let signing: SigningKeyProvider

    public init(
        directory: URL = SharedPaths.approvals, heartbeat: URL = SharedPaths.agentHeartbeat, signing: SigningKeyProvider = SigningKeyProvider()
    ) {
        self.directory = directory
        self.heartbeat = heartbeat
        self.signing = signing
    }

    private func write(_ request: ApprovalRequest) throws {
        SharedPaths.ensureDirectory(directory)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try Self.encoder.encode(request).write(to: file(request.id), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(request.id).path)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func file(_ id: UUID) -> URL { directory.appending(path: "\(id.uuidString).json") }

    /// True when the menu bar app has written its heartbeat recently.
    public func isAgentRunning(maxAge: TimeInterval = 20) -> Bool {
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: heartbeat.path))?[.modificationDate] as? Date
        else { return false }
        return Date().timeIntervalSince(modified) < maxAge
    }

    /// Called by the menu bar app every few seconds. Only the modification date counts, so once the file
    /// exists a beat just touches it.
    public func beat() {
        if utimes(heartbeat.path, nil) == 0 { return }
        SharedPaths.ensureDirectory(heartbeat.deletingLastPathComponent())
        try? Data(String(ProcessInfo.processInfo.processIdentifier).utf8).write(to: heartbeat, options: .atomic)
    }

    public func submit(_ request: ApprovalRequest) throws { try write(request) }

    public func load(_ id: UUID) -> ApprovalRequest? {
        guard let data = try? Data(contentsOf: file(id)) else { return nil }
        return try? Self.decoder.decode(ApprovalRequest.self, from: data)
    }

    public func pending() -> [ApprovalRequest] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? Self.decoder.decode(ApprovalRequest.self, from: Data(contentsOf: $0)) }
            .filter { $0.status == .pending }
            .sorted { $0.created < $1.created }
    }

    /// Records the user's answer, signed: the server takes an approval only with a valid signature.
    public func decide(_ id: UUID, approve: Bool) throws {
        guard var request = load(id) else { return }
        request.status = approve ? .approved : .denied
        request.decided = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        request.signature = try signing.key().sign(request.signedFields(status: request.status, decided: request.decided))
        try write(request)
    }

    public func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: file(id))
    }

    /// Submits and waits for a decision. Returns the final status; `.pending` on timeout.
    public func requestApproval(_ request: ApprovalRequest, timeout: TimeInterval) async throws -> ApprovalRequest.Status {
        try submit(request)
        defer { remove(request.id) }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let current = load(request.id), current.status != .pending {
                // Checked against the request as this server wrote it: an answer written by anything but the
                // menu bar app, or for a request edited on disk, is no answer, and nothing is sent.
                let fields = request.signedFields(status: current.status, decided: current.decided)
                guard (try? signing.key())?.verify(current.signature, fields) == true else { return .denied }
                return current.status
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        return .pending
    }
}

extension ActivityEntry {
    /// Apps that cannot read Mail right now: a client whose latest call in the last `window` failed for lack of
    /// Full Disk Access (see `LaunchContext.message`). A later successful call from the same client clears it,
    /// so the notice goes away as soon as the grant works, not an hour later.
    public static func appsLackingFullDiskAccess(
        in entries: [ActivityEntry], now: Date = Date(), window: TimeInterval = 3600
    ) -> [String] {
        let recent = entries.filter { now.timeIntervalSince($0.date) < window }
        let latestPerClient = Dictionary(grouping: recent, by: { $0.client ?? "" })
            .compactMap { $0.value.max { $0.date < $1.date } }
            .sorted { $0.date > $1.date }
        var apps: [String] = []
        for entry in latestPerClient where !entry.ok {
            if let app = appName(inFullDiskAccessMessage: entry.summary), !apps.contains(app) { apps.append(app) }
        }
        return apps
    }

    /// "…Full Disk Access to claude, the app…" → "claude".
    public static func appName(inFullDiskAccessMessage text: String) -> String? {
        guard let start = text.range(of: "Full Disk Access to ") else { return nil }
        let name = text[start.upperBound...].prefix { $0 != "," && $0 != "." }
        return name.isEmpty ? nil : String(name)
    }
}
