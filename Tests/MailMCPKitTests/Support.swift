import Foundation
import MCP
import MailAutomation
import MailFixtures
import MailStore

@testable import MailMCPKit

/// Records every request instead of talking to Mail.
final class RecordingAutomation: MailAutomating, @unchecked Sendable {
    enum Call: Equatable {
        case move([Int64], MailboxTarget, MailboxTarget)
        case setState([Int64], MailboxTarget, Bool?, Bool?, FlagColor?)
        case trash([Int64], MailboxTarget)
        case createMailbox(MailboxTarget)
        case check(String?)
        case compose(OutgoingMessage, DeliveryMode)
        case reply(Int64, MailboxTarget, String, Bool, DeliveryMode)
        case open(Int64)
        case createRule(RuleSpec)
        case setRuleEnabled(String, Bool, Int)
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] { lock.withLock { _calls } }
    var lastReplyHTML: String?
    /// Runs inside `move`, e.g. to simulate Mail re-inserting the message under a new id.
    var onMove: (@Sendable ([Int64], MailboxTarget) -> Void)?
    /// Runs inside `createMailbox`, e.g. to make the mailbox appear in the fixture.
    var onCreateMailbox: (@Sendable (MailboxTarget) -> Void)?
    /// Runs inside `compose`, e.g. to simulate Mail sending and then the Apple Event timing out.
    var onCompose: (@Sendable (OutgoingMessage, DeliveryMode) throws -> Void)?
    /// Runs inside `trash`, e.g. to simulate Mail moving the messages to Trash (or more than that).
    var onTrash: (@Sendable ([Int64], MailboxTarget) -> Void)?
    /// Runs inside `createRule` and `setRuleEnabled`, e.g. to write the rule files as Mail would.
    var onRuleChange: (@Sendable (Call) -> Void)?
    /// What `ruleNames` returns: the rules Mail has in memory.
    var mailRuleNames: [String] = []
    private var exclusiveDepth = 0
    private var _unguardedChanges = 0
    /// Moves and trashes requested outside `exclusive` (should stay 0).
    var unguardedChanges: Int { lock.withLock { _unguardedChanges } }

    private func record(_ call: Call) { lock.withLock { _calls.append(call) } }
    private func recordChange(_ call: Call) {
        lock.withLock {
            _calls.append(call)
            if exclusiveDepth == 0 { _unguardedChanges += 1 }
        }
    }
    private func adjustDepth(_ delta: Int) { lock.withLock { exclusiveDepth += delta } }

    func exclusive<T>(_ body: () async throws -> T) async throws -> T {
        adjustDepth(1)
        defer { adjustDepth(-1) }
        return try await body()
    }

    func accounts() async throws -> [AutomationAccount] { [] }

    func move(ids: [Int64], from: MailboxTarget, to: MailboxTarget) async throws -> Int {
        recordChange(.move(ids, from, to))
        onMove?(ids, to)
        return ids.count
    }

    func setState(ids: [Int64], in mailbox: MailboxTarget, read: Bool?, flagged: Bool?, flagColor: FlagColor?) async throws -> Int {
        record(.setState(ids, mailbox, read, flagged, flagColor))
        return ids.count
    }

    func trash(ids: [Int64], in mailbox: MailboxTarget) async throws -> Int {
        recordChange(.trash(ids, mailbox))
        onTrash?(ids, mailbox)
        return ids.count
    }

    func createMailbox(_ target: MailboxTarget) async throws {
        record(.createMailbox(target))
        onCreateMailbox?(target)
    }
    func checkForNewMail(accountID: String?) async throws { record(.check(accountID)) }
    func compose(_ message: OutgoingMessage, mode: DeliveryMode) async throws -> ComposeHandle? {
        record(.compose(message, mode))
        try onCompose?(message, mode)
        return nil
    }

    func closeCompose(_ handle: ComposeHandle) async throws {}

    func reply(
        to id: Int64, in mailbox: MailboxTarget, body: String, html: String?, replyAll: Bool, cc: [String], bcc: [String],
        attachments: [String], mode: DeliveryMode
    ) async throws -> ComposeHandle? {
        lastReplyHTML = html
        record(.reply(id, mailbox, body, replyAll, mode))
        return nil
    }

    func open(_ id: Int64, in mailbox: MailboxTarget) async throws { record(.open(id)) }

    func createRule(_ rule: RuleSpec) async throws {
        recordChange(.createRule(rule))
        onRuleChange?(.createRule(rule))
    }

    func setRuleEnabled(named name: String, enabled: Bool, expectedConditions: Int) async throws {
        recordChange(.setRuleEnabled(name, enabled, expectedConditions))
        onRuleChange?(.setRuleEnabled(name, enabled, expectedConditions))
    }

    func ruleNames() async throws -> [String] { mailRuleNames }
}

/// Contacts without the Contacts framework.
struct FixedContacts: ContactsProviding {
    var cards = [ContactCard(name: "Alice Martin", organization: "Example", emails: [("work", "alice@example.test")])]

    func search(_ text: String, limit: Int) async -> ContactsLookup {
        .found(cards.filter { $0.name.localizedCaseInsensitiveContains(text) || $0.emails.contains { $0.address.contains(text) } })
    }
}

/// A toolbox over the standard fixture, with its own settings, approvals and log in a temp folder.
struct Harness {
    /// Tests never read the Keychain.
    static let indexKey = BodyIndexKey(bytes: Array(0..<16))
    static let signing = SigningKeyProvider { SigningKey(bytes: Array(0..<32)) }
    let fixture: StandardFixture
    let toolbox: MailToolbox
    let automation: RecordingAutomation
    let support: URL
    let approvals: ApprovalCenter

    /// Most tests send without the approval window; the ones about approvals set their own policy.
    static var sendingAllowed: Settings {
        var settings = Settings()
        settings.sendPolicy = .allow
        return settings
    }

    init(settings: Settings = Harness.sendingAllowed, readOnly: Bool = false) throws {
        fixture = try StandardFixture.make()
        support = fixture.store.directory.appending(path: "support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try settings.save(to: support.appending(path: "settings.json"))
        automation = RecordingAutomation()
        approvals = ApprovalCenter(
            directory: support.appending(path: "approvals"), heartbeat: support.appending(path: "agent.heartbeat"), signing: Self.signing)
        toolbox = MailToolbox(
            store: try fixture.openStore(), automation: automation,
            settings: SettingsProvider(url: support.appending(path: "settings.json")), approvals: approvals,
            activity: ActivityLog(url: support.appending(path: "activity.jsonl")),
            changes: ChangeJournal(url: support.appending(path: "changes.json")),
            schedule: ScheduleStore(
                url: support.appending(path: "scheduled.json"), filesDirectory: support.appending(path: "scheduled-files"), signing: Self.signing),
            contacts: FixedContacts(),
            bodyIndexURL: support.appending(path: "body-index.sqlite"), bodyIndexKey: { Self.indexKey }, readOnly: readOnly)
        // The fake changes the fixture synchronously, so a short wait shows everything.
        toolbox.verification = ChangeVerification(timeout: 0.3, interval: 0.02, settle: 0)
        toolbox.mailboxSettle = 0.05
        // Tests never reach the network.
        toolbox.unsubscribePoster = { url in throw ToolError("network request to \(url) in a test") }
    }

    func id(_ name: String) -> Int64 { fixture.ids[name]! }

    /// Calls a tool and returns its text and error flag.
    func call(_ name: String, _ arguments: [String: Value] = [:]) async -> (text: String, isError: Bool) {
        let result = await toolbox.call(name, arguments: arguments)
        let text = result.content.compactMap { content -> String? in
            if case .text(let text, _, _) = content { return text }
            return nil
        }.joined()
        return (text, result.isError == true)
    }

    /// Calls a tool expecting success and decodes its JSON.
    func json(_ name: String, _ arguments: [String: Value] = [:]) async throws -> [String: Any] {
        let (text, isError) = await call(name, arguments)
        guard !isError else { throw ToolError("tool \(name) failed: \(text)") }
        return try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] ?? [:]
    }

    func remove() { fixture.store.remove() }
}

func ids(_ messages: Any?) -> [Int64] {
    (messages as? [[String: Any]] ?? []).compactMap { ($0["id"] as? NSNumber)?.int64Value }
}

func subjects(_ messages: Any?) -> [String] {
    (messages as? [[String: Any]] ?? []).compactMap { $0["subject"] as? String }
}
