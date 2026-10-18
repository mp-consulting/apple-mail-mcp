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

    /// Most recent entries first.
    public func recent(limit: Int = 50) -> [ActivityEntry] {
        var entries: [ActivityEntry] = []
        // The current file, then the rotated one if more entries are needed.
        for file in [url, url.appendingPathExtension("1")] {
            guard entries.count < limit, let data = try? Data(contentsOf: file) else { continue }
            for line in data.split(separator: 0x0A).reversed() {
                if let entry = try? Self.decoder.decode(ActivityEntry.self, from: line) { entries.append(entry) }
                if entries.count >= limit { break }
            }
        }
        return entries
    }
}

/// A request to send mail, waiting for the user's decision in the menu bar app.
public struct ApprovalRequest: Codable, Sendable, Hashable, Identifiable {
    public enum Status: String, Codable, Sendable { case pending, approved, denied }

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

    public init(
        id: UUID, created: Date, tool: String, client: String?, from: String?, to: [String], cc: [String], bcc: [String],
        subject: String, bodyPreview: String, attachments: [String], status: Status, decided: Date?, originalLink: String? = nil
    ) {
        self.originalLink = originalLink
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

    public init(directory: URL = SharedPaths.approvals, heartbeat: URL = SharedPaths.agentHeartbeat) {
        self.directory = directory
        self.heartbeat = heartbeat
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

    /// Called by the menu bar app every few seconds.
    public func beat() {
        SharedPaths.ensureDirectory(heartbeat.deletingLastPathComponent())
        try? Data(String(ProcessInfo.processInfo.processIdentifier).utf8).write(to: heartbeat, options: .atomic)
    }

    public func submit(_ request: ApprovalRequest) throws {
        SharedPaths.ensureDirectory(directory)
        try Self.encoder.encode(request).write(to: file(request.id), options: .atomic)
    }

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

    public func decide(_ id: UUID, approve: Bool) throws {
        guard var request = load(id) else { return }
        request.status = approve ? .approved : .denied
        request.decided = Date()
        try Self.encoder.encode(request).write(to: file(id), options: .atomic)
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
            if let current = load(request.id), current.status != .pending { return current.status }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        return .pending
    }
}
