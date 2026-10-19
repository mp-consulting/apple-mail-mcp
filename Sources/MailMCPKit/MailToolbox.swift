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
    /// Recent changes to mail, for `undo_change`; nil turns undo off.
    public let changes: ChangeJournal?
    /// Snoozes and scheduled sends; nil turns both off.
    public let schedule: ScheduleStore?
    /// Rule changes Mail had not saved when their tool returned; `mail_setup` reports them until it does.
    public let pendingRules: PendingRuleStore?
    /// The user's address book, for `find_contact`.
    public let contacts: any ContactsProviding
    public let bodyIndexURL: URL
    /// Where the body index key comes from: the Keychain, or a fixed key in tests.
    public let bodyIndexKey: @Sendable () throws -> BodyIndexKey
    /// Started with --read-only: mail-changing and compose tools are not even listed.
    public let readOnly: Bool
    /// Sends one-click unsubscribe requests (tests never reach the network).
    public var unsubscribePoster: UnsubscribePoster = MailToolbox.defaultUnsubscribePoster
    /// How long a mailbox Mail just created must stay before snoozed messages go into it (tests shorten it).
    public var mailboxSettle: TimeInterval = 3
    /// How long moves and trashes wait for Mail's database to show their outcome (tests shorten it).
    public var verification = ChangeVerification()
    /// How long rule changes wait for Mail to save its rule files (tests shorten it).
    public var ruleVerification = RuleVerification()
    /// When the running Mail started (nil when it is not running); tests fix it.
    public var mailLaunchDate: @Sendable () -> Date? = { MailAutomation.mailLaunchDate() }
    public var clientName: String? {
        get { lock.withLock { _clientName } }
        set { lock.withLock { _clientName = newValue } }
    }

    private let lock = NSLock()
    private var _listed: (all: [ToolDefinition], byName: [String: ToolDefinition])?
    private var _clientName: String?
    private var _bodyIndex: BodyIndex?
    private var registeredSettingsAddresses: [String] = []
    private var askedMailForAddresses = false

    public convenience init(
        store: MailStore, automation: any MailAutomating, settings: SettingsProvider = SettingsProvider(),
        approvals: ApprovalCenter = ApprovalCenter(), activity: ActivityLog? = ActivityLog(),
        changes: ChangeJournal? = ChangeJournal(), schedule: ScheduleStore? = ScheduleStore(),
        pendingRules: PendingRuleStore? = PendingRuleStore(),
        contacts: any ContactsProviding = SystemContacts(), bodyIndexURL: URL = SharedPaths.bodyIndex,
        bodyIndexKey: (@Sendable () throws -> BodyIndexKey)? = nil, readOnly: Bool = false
    ) {
        self.init(
            storeProvider: { store }, automation: automation, settings: settings, approvals: approvals,
            activity: activity, changes: changes, schedule: schedule, pendingRules: pendingRules, contacts: contacts, bodyIndexURL: bodyIndexURL, bodyIndexKey: bodyIndexKey, readOnly: readOnly)
    }

    public init(
        storeProvider: @escaping @Sendable () throws -> MailStore, automation: any MailAutomating,
        settings: SettingsProvider = SettingsProvider(), approvals: ApprovalCenter = ApprovalCenter(),
        activity: ActivityLog? = ActivityLog(), changes: ChangeJournal? = ChangeJournal(),
        schedule: ScheduleStore? = ScheduleStore(), pendingRules: PendingRuleStore? = PendingRuleStore(),
        contacts: any ContactsProviding = SystemContacts(),
        bodyIndexURL: URL = SharedPaths.bodyIndex,
        bodyIndexKey: (@Sendable () throws -> BodyIndexKey)? = nil, readOnly: Bool = false
    ) {
        self.storeProvider = storeProvider
        self.automation = automation
        self.settings = settings
        self.approvals = approvals
        self.activity = activity
        self.changes = changes
        self.schedule = schedule
        self.pendingRules = pendingRules
        self.contacts = contacts
        self.bodyIndexURL = bodyIndexURL
        self.bodyIndexKey = bodyIndexKey ?? BodyIndexKey.provider(forIndexAt: bodyIndexURL)
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
        let changed = lock.withLock {
            defer { registeredSettingsAddresses = extra }
            return extra != registeredSettingsAddresses
        }
        if changed, let first = accounts.first { store.registerOwnAddresses(extra, accountID: first.id) }
        let firstAsk = lock.withLock {
            defer { askedMailForAddresses = true }
            return !askedMailForAddresses
        }
        guard firstAsk else { return }
        // Only ask Mail when automation is already allowed and Mail is running: never prompt for a read. In the
        // background: the permission check and Mail's answer can take seconds (Mail busy, a system prompt open),
        // and the addresses found in Sent mail already cover a read; Mail's list only adds aliases.
        guard let live = automation as? MailAutomation else { return }
        Task.detached {
            guard live.permissionStatus(askIfNeeded: false) == 0, let infos = try? await live.accounts() else { return }
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
        attachments: [String], originalLink: String? = nil, sendAt: Date? = nil
    ) async throws {
        let current = settings.current
        switch current.sendPolicy {
        case .allow:
            return
        case .never:
            throw ToolError("Sending is turned off (send policy \"never\"). Use mode \"draft\" or \"open\" instead.")
        case .confirm:
            try await askUser(
                ApprovalRequest(
                    id: UUID(), created: Date(), tool: tool, client: clientName, from: from, to: to, cc: cc, bcc: bcc,
                    subject: subject, bodyPreview: Render.truncate(body, 600),
                    attachments: attachments.map { ($0 as NSString).lastPathComponent }, status: .pending, decided: nil,
                    originalLink: originalLink, sendAt: sendAt),
                what: "Sending", declined: "The user declined to send this message. Nothing was sent.", nothing: "Nothing was sent.")
        }
    }

    /// Asks before moving or trashing more messages than the user's threshold (Settings: "Ask me before changing more than").
    func authorizeChange(tool: String, summary: String, messages: [MessageSummary]) async throws {
        let threshold = settings.current.approveChangesAbove
        guard threshold > 0, messages.count > threshold, !Self.changesApproved else { return }
        var lines = messages.prefix(15).map { "\($0.sender.name ?? $0.sender.address) — \($0.subject)" }
        if messages.count > 15 { lines.append("… and \(messages.count - 15) more") }
        try await askUser(
            ApprovalRequest(
                id: UUID(), created: Date(), tool: tool, client: clientName, from: nil, to: [], cc: [], bcc: [], subject: summary,
                bodyPreview: lines.joined(separator: "\n"), attachments: [], status: .pending, decided: nil, kind: .change),
            what: "Changing more than \(threshold) messages",
            declined: "The user declined this change. Nothing was moved.", nothing: "Nothing was moved.")
    }

    /// Set while carrying out a change the user already approved as a whole (`apply_rules`), so the moves and
    /// trashes it is made of do not ask again.
    @TaskLocal static var changesApproved = false

    /// Waits for the user's decision in the menu bar app; throws unless approved.
    func askUser(_ request: ApprovalRequest, what: String, declined: String, nothing: String) async throws {
        guard approvals.isAgentRunning() else {
            throw ToolError(
                "\(what) needs approval in the Apple Mail MCP menu bar app, which is not running. Start it\(request.action == .send ? ", or use mode \"draft\"" : "").")
        }
        let timeout = settings.current.approvalTimeout
        switch try await approvals.requestApproval(request, timeout: timeout) {
        case .approved: return
        case .denied: throw ToolError(declined)
        case .pending: throw ToolError("No approval within \(Int(timeout)) s. \(nothing)")
        }
    }

    // MARK: Tool list

    public var definitions: [ToolDefinition] { readTools + trustTools + watchTools + fileTools + changeTools + ruleTools + undoTools + scheduleTools + composeTools + draftTools }

    /// Tools offered to clients (hides write tools in read-only launches). Built once: every call looks its tool
    /// up here, and building ~40 definitions with their schemas cost more than many of the calls themselves.
    public var listedDefinitions: [ToolDefinition] { listed.all }

    private var listed: (all: [ToolDefinition], byName: [String: ToolDefinition]) {
        if let built = lock.withLock({ _listed }) { return built }
        let all = readOnly ? definitions.filter { $0.kind == .read || $0.kind == .fileWrite } : definitions
        let built = (all, Dictionary(all.map { ($0.tool.name, $0) }, uniquingKeysWith: { first, _ in first }))
        lock.withLock { _listed = built }
        return built
    }

    /// Reads that take milliseconds, run on the stdio reader thread itself (no other thread to wake); while one
    /// runs, the next request waits, so the list is explicit. A body search can scan files: it keeps its own task,
    /// as do every other read, waiting for mail, the index, and every change.
    public func runsOnReaderThread(_ name: String, arguments: [String: Value]?) -> Bool {
        guard Self.quickReads.contains(name), listed.byName[name]?.kind == .read else { return false }
        return name != "search_messages" || arguments?["body"] == nil
    }

    static let quickReads: Set<String> = [
        "list_accounts", "list_mailboxes", "inbox_overview", "search_messages", "get_message", "get_messages", "get_thread",
        "list_attachments", "get_message_source", "list_drafts", "mail_statistics", "top_senders", "awaiting_reply",
        "needs_response", "list_scheduled",
    ]

    /// Runs a tool and logs it. Errors come back as tool errors, never as protocol failures.
    public func call(_ name: String, arguments: [String: Value]?) async -> CallTool.Result {
        let started = Date()
        Trace.mark("start")
        defer { Trace.flush(name) }
        guard let definition = listed.byName[name] else {
            return .init(content: [.text(text: "Unknown tool \(name)", annotations: nil, _meta: nil)], isError: true)
        }
        await refreshOwnAddresses()
        Trace.mark("addresses")
        Self.debug("\(name): addresses ready after \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        var ok = true
        var text: String
        var summary: String
        var link: String?
        do {
            let reply = try await definition.run(Arguments(arguments))
            Trace.mark("tool")
            text = reply.json.serialized()
            Trace.mark("serialize")
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
