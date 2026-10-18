import AppKit
import Foundation
import MCP
import MailAutomation
import MailStore

/// What a tool touches, for listing, policy checks and the activity log.
public enum ToolKind: String, Sendable {
    /// Reads Mail's data on disk only.
    case read
    /// Writes files the user asked for (saved attachments, exports).
    case fileWrite
    /// Changes Mail state: move, flag, trash, create mailbox.
    case mailChange
    /// Creates outgoing mail (draft, compose window or send).
    case compose
}

public struct ToolReply: Sendable {
    public var json: JSON
    public var summary: String
    /// The message this call was about (or the draft it saved): the menu bar app offers "Show in Mail".
    public var messageID: Int64? = nil
}

public struct ToolDefinition: Sendable {
    public var tool: Tool
    public var kind: ToolKind
    public var run: @Sendable (Arguments) async throws -> ToolReply
}

/// All MCP tools, bound to a store, an automation backend and the user's settings.
public final class MailToolbox: @unchecked Sendable {
    /// The Mail store, opened on first use. Throws a setup message (e.g. Full Disk Access) until it opens,
    /// so the server always starts and every tool can explain what is missing.
    public var store: MailStore {
        get throws {
            try lock.withLock {
                if let opened = _store { return opened }
                let opened = try storeProvider()
                _store = opened
                return opened
            }
        }
    }
    private let storeProvider: @Sendable () throws -> MailStore
    private var _store: MailStore?
    public let automation: any MailAutomating
    public let settings: SettingsProvider
    public let approvals: ApprovalCenter
    public let activity: ActivityLog?
    public let bodyIndexURL: URL
    /// Where the body index key comes from: the Keychain, or a fixed key in tests.
    public let bodyIndexKey: @Sendable () throws -> BodyIndexKey
    /// Started with --read-only: mail-changing and compose tools are not even listed.
    public let readOnly: Bool
    /// How long moves and trashes wait for Mail's database to show their outcome (tests shorten it).
    public var verification = ChangeVerification()
    public var clientName: String? {
        get { lock.withLock { _clientName } }
        set { lock.withLock { _clientName = newValue } }
    }

    private let lock = NSLock()
    private var _clientName: String?
    private var _bodyIndex: BodyIndex?
    private var registeredSettingsAddresses: [String] = []
    private var askedMailForAddresses = false

    public convenience init(
        store: MailStore, automation: any MailAutomating, settings: SettingsProvider = SettingsProvider(),
        approvals: ApprovalCenter = ApprovalCenter(), activity: ActivityLog? = ActivityLog(),
        bodyIndexURL: URL = SharedPaths.bodyIndex,
        bodyIndexKey: @escaping @Sendable () throws -> BodyIndexKey = BodyIndexKey.fromKeychain, readOnly: Bool = false
    ) {
        self.init(
            storeProvider: { store }, automation: automation, settings: settings, approvals: approvals,
            activity: activity, bodyIndexURL: bodyIndexURL, bodyIndexKey: bodyIndexKey, readOnly: readOnly)
    }

    public init(
        storeProvider: @escaping @Sendable () throws -> MailStore, automation: any MailAutomating,
        settings: SettingsProvider = SettingsProvider(), approvals: ApprovalCenter = ApprovalCenter(),
        activity: ActivityLog? = ActivityLog(), bodyIndexURL: URL = SharedPaths.bodyIndex,
        bodyIndexKey: @escaping @Sendable () throws -> BodyIndexKey = BodyIndexKey.fromKeychain, readOnly: Bool = false
    ) {
        self.storeProvider = storeProvider
        self.automation = automation
        self.settings = settings
        self.approvals = approvals
        self.activity = activity
        self.bodyIndexURL = bodyIndexURL
        self.bodyIndexKey = bodyIndexKey
        self.readOnly = readOnly
    }

    public static let instructions = """
        Apple Mail on this Mac. Reads come straight from Mail's local database and message files, so they are \
        fast and never disturb Mail; changes and sending go through Mail itself.
        Workflow: find messages with search_messages (or inbox_overview / needs_response), then act on them by \
        their numeric "id". Ids are Mail's own and change when a message moves: move_messages returns the new ids.
        Compose, reply and forward default to mode "draft" (saved to Drafts). Use mode "open" to leave a compose \
        window for the user, or "send" to deliver immediately when the user clearly asked to send.
        """

    // MARK: Shared state

    var bodyIndex: BodyIndex? {
        lock.lock()
        defer { lock.unlock() }
        if _bodyIndex == nil { _bodyIndex = BodyIndex.openIfPresent(url: bodyIndexURL, key: bodyIndexKey) }
        return _bodyIndex
    }

    /// The body index for `query`'s body text, when one is built and unlocked. Without the Keychain key the
    /// index cannot be read: `locked` is then true and searches scan recent messages instead.
    func searchIndex(for query: MessageQuery) -> (index: BodyIndex?, locked: Bool) {
        guard query.bodyText != nil, let index = bodyIndex else { return (nil, false) }
        return index.isUnlocked ? (index, false) : (nil, true)
    }

    func openBodyIndexForWriting() throws -> BodyIndex {
        if let existing = bodyIndex { return existing }
        let created = try BodyIndex(url: bodyIndexURL, key: bodyIndexKey)
        lock.withLock { _bodyIndex = created }
        return created
    }

    var pathGuard: PathGuard {
        let current = settings.current
        return PathGuard(writeAllowlist: current.writeDirectories, attachAllowlist: current.attachDirectories)
    }

    /// Feeds "me" addresses from settings and, when already permitted, from Mail itself.
    private func refreshOwnAddresses() async {
        guard let store = try? self.store else { return }
        let extra = settings.current.ownAddresses
        let accounts = (try? store.accounts()) ?? []
        if extra != registeredSettingsAddresses, let first = accounts.first {
            store.registerOwnAddresses(extra, accountID: first.id)
            registeredSettingsAddresses = extra
        }
        guard !lock.withLock({ askedMailForAddresses }) else { return }
        lock.withLock { askedMailForAddresses = true }
        // Only ask Mail when automation is already allowed and Mail is running: never prompt for a read.
        if let live = automation as? MailAutomation, live.permissionStatus(askIfNeeded: false) == 0,
           let infos = try? await automation.accounts()
        {
            for info in infos { store.registerOwnAddresses(info.emailAddresses, accountID: info.id) }
        }
    }

    // MARK: Resolution helpers

    func resolveAccountID(_ arguments: Arguments, key: String = "account") throws -> String? {
        guard let name = try arguments.string(key) else { return nil }
        return try store.resolveAccount(name).id
    }

    func resolveMailboxIDs(_ arguments: Arguments, accountID: String?, key: String = "mailbox") throws -> [Int64] {
        guard let name = try arguments.string(key) else { return [] }
        if name.lowercased() == "all" { return [] }
        return try store.resolveMailboxes(name, accountID: accountID).map(\.id)
    }

    /// Messages for `ids` grouped with their mailbox; unknown ids are returned separately.
    func locate(_ ids: [Int64]) throws -> (groups: [(Mailbox, [MessageSummary])], missing: [Int64]) {
        let found = try store.messages(ids: ids)
        let foundIDs = Set(found.map(\.id))
        var groups: [Int64: (Mailbox, [MessageSummary])] = [:]
        var order: [Int64] = []
        for message in found {
            guard let mailbox = try store.mailbox(id: message.mailboxID) else { continue }
            if groups[mailbox.id] == nil {
                groups[mailbox.id] = (mailbox, [])
                order.append(mailbox.id)
            }
            groups[mailbox.id]!.1.append(message)
        }
        return (order.compactMap { groups[$0] }, ids.filter { !foundIDs.contains($0) })
    }

    func requireMailChanges() throws {
        guard settings.current.allowMailChanges else {
            throw ToolError("Changing mail is turned off (Apple Mail MCP settings → \"Allow changes to mail\").")
        }
    }

    func checkBatch(_ ids: [Int64]) throws {
        guard !ids.isEmpty else { throw ToolError("ids is required") }
        let limit = settings.current.maxBatchSize
        guard ids.count <= limit else {
            throw ToolError("Too many messages (\(ids.count)); the limit per call is \(limit). Split the work or raise maxBatchSize in settings.")
        }
    }

    static func mode(_ arguments: Arguments) throws -> DeliveryMode {
        guard let text = try arguments.string("mode") else { return .draft }
        guard let mode = DeliveryMode(rawValue: text.lowercased()) else { throw ToolError("mode must be draft, open or send") }
        return mode
    }

    static func validateAddresses(_ list: [String], field: String) throws {
        for address in list where !address.contains("@") || address.hasPrefix("@") || address.hasSuffix("@") {
            throw ToolError("\(field): \"\(address)\" is not an email address")
        }
    }

    /// Applies the send policy; may wait for approval in the menu bar app.
    func authorizeSend(
        tool: String, from: String?, to: [String], cc: [String], bcc: [String], subject: String, body: String,
        attachments: [String], originalLink: String? = nil
    ) async throws {
        let current = settings.current
        switch current.sendPolicy {
        case .allow:
            return
        case .never:
            throw ToolError("Sending is turned off (send policy \"never\"). Use mode \"draft\" or \"open\" instead.")
        case .confirm:
            guard approvals.isAgentRunning() else {
                throw ToolError(
                    "Sending needs approval in the Apple Mail MCP menu bar app, which is not running. Start it, or use mode \"draft\".")
            }
            let request = ApprovalRequest(
                id: UUID(), created: Date(), tool: tool, client: clientName, from: from, to: to, cc: cc, bcc: bcc,
                subject: subject, bodyPreview: Render.truncate(body, 600), attachments: attachments.map { ($0 as NSString).lastPathComponent },
                status: .pending, decided: nil, originalLink: originalLink)
            switch try await approvals.requestApproval(request, timeout: current.approvalTimeout) {
            case .approved: return
            case .denied: throw ToolError("The user declined to send this message. Nothing was sent.")
            case .pending: throw ToolError("No approval within \(Int(current.approvalTimeout)) s. Nothing was sent.")
            }
        }
    }

    // MARK: Tool list

    public var definitions: [ToolDefinition] { readTools + fileTools + changeTools + composeTools }

    /// Tools offered to clients (hides write tools in read-only launches).
    public var listedDefinitions: [ToolDefinition] {
        readOnly ? definitions.filter { $0.kind == .read || $0.kind == .fileWrite } : definitions
    }

    /// Runs a tool and logs it. Errors come back as tool errors, never as protocol failures.
    public func call(_ name: String, arguments: [String: Value]?) async -> CallTool.Result {
        let started = Date()
        guard let definition = listedDefinitions.first(where: { $0.tool.name == name }) else {
            return .init(content: [.text(text: "Unknown tool \(name)", annotations: nil, _meta: nil)], isError: true)
        }
        await refreshOwnAddresses()
        Self.debug("\(name): addresses ready after \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        var ok = true
        var text: String
        var summary: String
        var link: String?
        do {
            let reply = try await definition.run(Arguments(arguments))
            text = reply.json.serialized()
            summary = reply.summary
            if let id = reply.messageID { link = (try? store.message(id: id))?.mailLink }
        } catch {
            ok = false
            text = "Error: \(error)"
            summary = String(describing: error).components(separatedBy: "\n").first ?? "error"
        }
        Self.debug("\(name): finished after \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        activity?.append(
            ActivityEntry(
                date: started, pid: ProcessInfo.processInfo.processIdentifier, client: clientName, tool: name, ok: ok,
                milliseconds: Int(Date().timeIntervalSince(started) * 1000), summary: Render.truncate(summary, 160),
                isWrite: definition.kind != .read, link: link))
        return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: ok ? nil : true)
    }

    static let debugEnabled = ProcessInfo.processInfo.environment["APPLE_MAIL_MCP_DEBUG"] != nil

    static func debug(_ message: @autoclosure () -> String) {
        guard debugEnabled else { return }
        FileHandle.standardError.write(Data("[apple-mail-mcp] \(message())\n".utf8))
    }

    static func tool(
        _ name: String, _ title: String, _ description: String, _ schema: Value, kind: ToolKind, destructive: Bool = false,
        idempotent: Bool = false, openWorld: Bool = false
    ) -> Tool {
        Tool(
            name: name, title: title, description: description, inputSchema: schema,
            annotations: .init(
                title: title, readOnlyHint: kind == .read, destructiveHint: kind == .read ? nil : destructive,
                idempotentHint: kind == .read ? nil : idempotent, openWorldHint: openWorld))
    }
}
