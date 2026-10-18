import Foundation
import MailStore

/// A mailbox as AppleScript addresses it: account UUID (empty for "On My Mac") and path.
public struct MailboxTarget: Sendable, Hashable, CustomStringConvertible {
    public var accountID: String
    public var path: String

    public init(accountID: String, path: String) {
        self.accountID = accountID
        self.path = path
    }

    public init(_ mailbox: Mailbox) {
        let isLocal = MailboxURL(mailbox.url)?.scheme == "local"
        self.init(accountID: isLocal ? "" : mailbox.accountID, path: mailbox.path)
    }

    public var description: String { accountID.isEmpty ? "On My Mac/\(path)" : "\(accountID)/\(path)" }
}

public enum DeliveryMode: String, Sendable, CaseIterable, Codable {
    /// Saved to the account's Drafts mailbox.
    case draft
    /// Opened in a Mail compose window for the user to review and send.
    case open
    /// Sent immediately.
    case send
}

public struct OutgoingMessage: Sendable, Hashable {
    public var from: String?
    public var to: [String]
    public var cc: [String]
    public var bcc: [String]
    public var subject: String
    /// Plain text (also the fallback when `html` is set).
    public var body: String
    /// Formatted body; when set, Mail sends a multipart HTML email.
    public var html: String?
    public var attachments: [String]

    public init(
        from: String? = nil, to: [String], cc: [String] = [], bcc: [String] = [], subject: String, body: String,
        html: String? = nil, attachments: [String] = []
    ) {
        self.html = html
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
        self.attachments = attachments
    }
}

/// An open compose object in Mail (outgoing messages are addressed by a per-session id).
public struct ComposeHandle: Sendable, Hashable {
    public var id: Int32
    public init(id: Int32) { self.id = id }
}

public struct AutomationAccount: Sendable, Hashable, Codable {
    public var id: String
    public var name: String
    public var enabled: Bool
    public var emailAddresses: [String]
}

/// Everything the server asks Mail.app to do. A protocol so tests can record calls.
public protocol MailAutomating: Sendable {
    func accounts() async throws -> [AutomationAccount]
    func move(ids: [Int64], from: MailboxTarget, to: MailboxTarget) async throws -> Int
    func setState(ids: [Int64], in mailbox: MailboxTarget, read: Bool?, flagged: Bool?, flagColor: FlagColor?) async throws -> Int
    func trash(ids: [Int64], in mailbox: MailboxTarget) async throws -> Int
    func createMailbox(_ target: MailboxTarget) async throws
    func checkForNewMail(accountID: String?) async throws
    /// Returns the compose object for `.draft` (still open; close it once the draft is stored).
    @discardableResult
    func compose(_ message: OutgoingMessage, mode: DeliveryMode) async throws -> ComposeHandle?
    @discardableResult
    func reply(
        to id: Int64, in mailbox: MailboxTarget, body: String, html: String?, replyAll: Bool, cc: [String], bcc: [String],
        attachments: [String], mode: DeliveryMode) async throws -> ComposeHandle?
    /// Closes a compose object without saving again.
    func closeCompose(_ handle: ComposeHandle) async throws
    func open(_ id: Int64, in mailbox: MailboxTarget) async throws
    /// Runs `body` with Mail automation reserved for this caller, across processes, so a bulk change
    /// and the check of its outcome cannot interleave with another client's changes.
    func exclusive<T>(_ body: () async throws -> T) async throws -> T
}

extension MailAutomating {
    public func exclusive<T>(_ body: () async throws -> T) async throws -> T { try await body() }
}

/// Drives Mail.app with raw Apple Events (see ``MailSpec``). Calls run on a
/// private serial queue and are serialized across every server process by
/// ``AutomationLock``, because Mail handles one scripting request at a time.
public final class MailAutomation: MailAutomating {
    private let sender: MailEventSender
    private let lockTimeout: TimeInterval
    private let queue = DispatchQueue(label: "apple-mail-mcp.apple-events")

    public init(eventTimeout: TimeInterval = 60, lockTimeout: TimeInterval = 30) {
        sender = MailEventSender(timeout: eventTimeout)
        self.lockTimeout = lockTimeout
    }

    /// 0 when allowed; -1743 denied; -1744 needs consent; -600 Mail not running.
    public func permissionStatus(askIfNeeded: Bool = false) -> Int {
        sender.permissionStatus(askIfNeeded: askIfNeeded)
    }

    private func run<T: Sendable>(_ body: @escaping @Sendable (MailEventSender) throws -> T) async throws -> T {
        let sender = self.sender
        let queue = self.queue
        return try await AutomationLock.withLock(timeout: lockTimeout) {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    continuation.resume(with: Result { try body(sender) })
                }
            }
        }
    }

    public func exclusive<T>(_ body: () async throws -> T) async throws -> T {
        try await AutomationLock.withLock(timeout: lockTimeout, body)
    }

    public func accounts() async throws -> [AutomationAccount] {
        try await run { mail in
            let every = MailSpec.every("mact", of: nil)
            let ids = AEValue(try mail.get(MailSpec.property("ID  ", of: every))).list
            let names = AEValue(try mail.get(MailSpec.property("pnam", of: every))).list
            let enabled = AEValue(try mail.get(MailSpec.property("isac", of: every))).list
            let addresses = AEValue(try mail.get(MailSpec.property("emad", of: every))).list
            return ids.enumerated().compactMap { index, value in
                guard let id = value.string else { return nil }
                return AutomationAccount(
                    id: id,
                    name: index < names.count ? names[index].string ?? id : id,
                    enabled: index < enabled.count ? enabled[index].bool ?? true : true,
                    emailAddresses: index < addresses.count ? addresses[index].list.compactMap(\.string) : [])
            }
        }
    }

    /// Runs `body` for each id, counting successes; ids Mail no longer has (-1728) are skipped.
    private static func forEach(_ ids: [Int64], _ body: (Int64) throws -> Void) throws -> Int {
        var done = 0
        for id in ids {
            do {
                try body(id)
                done += 1
            } catch let error as AppleEventError where error.number == -1728 || error.number == -1719 {
                continue
            }
        }
        return done
    }

    public func move(ids: [Int64], from: MailboxTarget, to: MailboxTarget) async throws -> Int {
        try await run { mail in
            try Self.forEach(ids) { id in
                try mail.send("core", "move", direct: MailSpec.message(id, in: from), ["insh": MailSpec.mailbox(to)])
            }
        }
    }

    public func setState(ids: [Int64], in mailbox: MailboxTarget, read: Bool?, flagged: Bool?, flagColor: FlagColor?) async throws -> Int {
        try await run { mail in
            try Self.forEach(ids) { id in
                let message = MailSpec.message(id, in: mailbox)
                if let read {
                    try mail.set(MailSpec.property("isrd", of: message), to: NSAppleEventDescriptor(boolean: read))
                }
                if let flagColor {
                    try mail.set(MailSpec.property("isfl", of: message), to: NSAppleEventDescriptor(boolean: true))
                    try mail.set(MailSpec.property("fidx", of: message), to: NSAppleEventDescriptor(int32: Int32(flagColor.rawValue)))
                } else if let flagged {
                    try mail.set(MailSpec.property("isfl", of: message), to: NSAppleEventDescriptor(boolean: flagged))
                }
            }
        }
    }

    public func trash(ids: [Int64], in mailbox: MailboxTarget) async throws -> Int {
        try await run { mail in
            try Self.forEach(ids) { id in
                try mail.send("core", "delo", direct: MailSpec.message(id, in: mailbox))
            }
        }
    }

    public func createMailbox(_ target: MailboxTarget) async throws {
        try await run { mail in
            _ = try mail.make(
                "mbxp", at: target.accountID.isEmpty ? nil : MailSpec.account(id: target.accountID),
                properties: ["pnam": NSAppleEventDescriptor(string: target.path)])
        }
    }

    public func checkForNewMail(accountID: String?) async throws {
        try await run { mail in
            var parameters: [String: NSAppleEventDescriptor] = [:]
            if let accountID, !accountID.isEmpty { parameters["acna"] = MailSpec.account(id: accountID) }
            try mail.send("emal", "chma", parameters)
        }
    }

    private static func addRecipients(_ mail: MailEventSender, to message: NSAppleEventDescriptor, to: [String], cc: [String], bcc: [String]) throws {
        for (cls, addresses) in [("trcp", to), ("crcp", cc), ("brcp", bcc)] {
            for address in addresses {
                _ = try mail.make(
                    cls, at: MailSpec.insertion("end ", of: MailSpec.every(cls, of: message)),
                    properties: ["radd": NSAppleEventDescriptor(string: address)])
            }
        }
    }

    private static func addAttachments(_ mail: MailEventSender, to message: NSAppleEventDescriptor, paths: [String]) throws {
        // All files go in back to back; ``waitForAttachments`` then waits once for Mail to embed them.
        for path in paths {
            let lastParagraph = MailSpec.object(
                want: "cpar", form: "indx", seld: NSAppleEventDescriptor(int32: -1),
                from: MailSpec.property("ctnt", of: message))
            _ = try mail.make(
                "atts", at: MailSpec.insertion("afte", of: lastParagraph), properties: ["atfn": MailSpec.fileURL(path)])
        }
    }

    /// Polls `count of attachments of content of m` until every file is embedded (max ~10 s).
    private static func waitForAttachments(_ mail: MailEventSender, _ message: NSAppleEventDescriptor, expected: Int) {
        guard expected > 0 else { return }
        let content = MailSpec.property("ctnt", of: message)
        let kind = ["kocl": NSAppleEventDescriptor(typeCode: fourCC("atts"))]
        for _ in 0..<50 {
            if let reply = try? mail.send("core", "cnte", direct: content, kind), Int(reply.int32Value) >= expected { break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        // A short settle: the count updates before Mail has finished copying the last file.
        Thread.sleep(forTimeInterval: 0.3)
    }

    /// RTF for an HTML body, converted on the main thread before the Apple Events run.
    private static func rtf(_ html: String?) async throws -> Data? {
        guard let html, !html.isEmpty else { return nil }
        return try await MainActor.run { try RichText.rtf(fromHTML: html) }
    }

    private static func richText(_ rtf: Data) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(descriptorType: fourCC("RTF "), data: rtf) ?? NSAppleEventDescriptor(string: "")
    }

    private static func handle(_ message: NSAppleEventDescriptor) -> ComposeHandle? {
        message.forKeyword(fourCC("seld")).map { ComposeHandle(id: $0.int32Value) }
    }

    private static func finish(_ mail: MailEventSender, _ message: NSAppleEventDescriptor, mode: DeliveryMode, attachments: Int = 0) throws {
        // Saving or sending before Mail has embedded every file drops the late ones.
        waitForAttachments(mail, message, expected: attachments)
        switch mode {
        case .send:
            let sent = try mail.send("emsg", "send", direct: message)
            if sent.descriptorType == fourCC("bool") || sent.descriptorType == fourCC("fals"), !sent.booleanValue {
                throw AppleEventError(number: -1, message: "Mail reported that sending failed")
            }
        case .draft:
            // Saving is asynchronous and closing too early discards it, so the caller closes the
            // compose object (``closeCompose``) once the draft shows up in Mail's database.
            try mail.send("core", "save", direct: message)
        case .open:
            try mail.set(MailSpec.property("pvis", of: message), to: NSAppleEventDescriptor(boolean: true))
            try mail.send("misc", "actv")
        }
    }

    @discardableResult
    public func compose(_ outgoing: OutgoingMessage, mode: DeliveryMode) async throws -> ComposeHandle? {
        let rtf = try await Self.rtf(outgoing.html)
        return try await run { mail in
            let message = try mail.make(
                "bcke",
                properties: [
                    "subj": NSAppleEventDescriptor(string: outgoing.subject),
                    "ctnt": NSAppleEventDescriptor(string: outgoing.body),
                    "pvis": NSAppleEventDescriptor(boolean: false),
                ])
            if let rtf { try mail.set(MailSpec.property("ctnt", of: message), to: Self.richText(rtf)) }
            if let from = outgoing.from, !from.isEmpty {
                try mail.set(MailSpec.property("sndr", of: message), to: NSAppleEventDescriptor(string: from))
            }
            try Self.addRecipients(mail, to: message, to: outgoing.to, cc: outgoing.cc, bcc: outgoing.bcc)
            try Self.addAttachments(mail, to: message, paths: outgoing.attachments)
            try Self.finish(mail, message, mode: mode, attachments: outgoing.attachments.count)
            return mode == .draft ? Self.handle(message) : nil
        }
    }

    @discardableResult
    public func reply(
        to id: Int64, in mailbox: MailboxTarget, body: String, html: String?, replyAll: Bool, cc: [String], bcc: [String],
        attachments: [String], mode: DeliveryMode
    ) async throws -> ComposeHandle? {
        let rtf = try await Self.rtf(html)
        return try await run { mail in
            // `reply` gives the threading headers (In-Reply-To, References). Mail always opens a
            // window for it, and the body (with our own quote) replaces Mail's as plain text.
            let reply = try mail.send(
                "emal", "rpms", direct: MailSpec.message(id, in: mailbox),
                ["ropw": NSAppleEventDescriptor(boolean: false), "rpal": NSAppleEventDescriptor(boolean: replyAll)])
            try mail.set(
                MailSpec.property("ctnt", of: reply), to: rtf.map(Self.richText) ?? NSAppleEventDescriptor(string: body))
            try Self.addRecipients(mail, to: reply, to: [], cc: cc, bcc: bcc)
            try Self.addAttachments(mail, to: reply, paths: attachments)
            try Self.finish(mail, reply, mode: mode, attachments: attachments.count)
            return mode == .draft ? Self.handle(reply) : nil
        }
    }

    public func closeCompose(_ handle: ComposeHandle) async throws {
        try await run { mail in
            let message = MailSpec.object(
                want: "bcke", form: "ID  ", seld: NSAppleEventDescriptor(int32: handle.id), from: nil)
            try mail.send("core", "clos", direct: message, ["savo": NSAppleEventDescriptor(enumCode: fourCC("no  "))])
        }
    }

    public func open(_ id: Int64, in mailbox: MailboxTarget) async throws {
        try await run { mail in
            try mail.send("aevt", "odoc", direct: MailSpec.message(id, in: mailbox))
            try mail.send("misc", "actv")
        }
    }
}

/// Cross-process advisory lock (flock) so concurrent server instances queue
/// their Apple Events instead of piling onto Mail's single scripting thread.
/// The kernel releases it if a holder dies, so it can never go stale. Reentrant within a task, so the
/// events sent inside ``MailAutomating/exclusive(_:)`` do not wait for their own caller.
public enum AutomationLock {
    @TaskLocal static var held: Set<String> = []

    public static var path: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/apple-mail-mcp/automation.lock").path
    }

    public struct Busy: Error, CustomStringConvertible {
        public var description: String {
            "Mail automation is busy (another apple-mail-mcp process holds the lock). Try again shortly."
        }
    }

    public static func withLock<T>(
        timeout: TimeInterval, path: String = AutomationLock.path, _ body: () async throws -> T
    ) async throws -> T {
        if held.contains(path) { return try await body() }
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return try await body() }
        defer { close(fd) }
        let deadline = Date().addingTimeInterval(timeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if Date() >= deadline { throw Busy() }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        defer { flock(fd, LOCK_UN) }
        return try await $held.withValue(held.union([path])) { try await body() }
    }
}

extension MailAutomation {
    /// Read status, flag state and flag index of a message, straight from Mail (used to verify writes).
    public func state(of id: Int64, in mailbox: MailboxTarget) async throws -> (read: Bool, flagged: Bool, flagIndex: Int) {
        try await run { mail in
            let message = MailSpec.message(id, in: mailbox)
            let read = try mail.get(MailSpec.property("isrd", of: message)).booleanValue
            let flagged = try mail.get(MailSpec.property("isfl", of: message)).booleanValue
            let index = Int(try mail.get(MailSpec.property("fidx", of: message)).int32Value)
            return (read, flagged, index)
        }
    }
}
