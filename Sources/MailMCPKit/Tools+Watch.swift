import Foundation
import MCP
import MailStore

extension MailToolbox {
    var watchTools: [ToolDefinition] { [waitForMail] }

    /// Messages that arrived after `rowID` and match `query` (its own paging is replaced).
    func arrivals(after rowID: Int64, matching query: MessageQuery) throws -> [MessageSummary] {
        let store = try self.store
        let fresh = try store.indexCandidates(after: rowID, limit: 500).map(\.id)
        guard !fresh.isEmpty else { return [] }
        var narrowed = query
        narrowed.ids = fresh
        narrowed.limit = 50
        narrowed.offset = 0
        return try store.search(narrowed, bodyIndex: nil).messages
    }

    var waitForMail: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "wait_for_mail", "Wait for new mail",
                """
                Wait until new mail matching the filters arrives (received mail only unless direction says \
                otherwise), up to timeout seconds, then return it: e.g. a sign-in code or a reply you are expecting. \
                Pass after_id (the latest_id of a previous call) to also return mail that arrived in between. \
                Reads only; ask Mail to fetch first with check_new_mail if it may not have checked recently.
                """,
                Schema.object(
                    Self.filterSchema.merging([
                        "timeout": Schema.integer("Seconds to wait (default 60, max 300)", minimum: 1, maximum: 300),
                        "after_id": Schema.integer("Only messages newer than this id (default: whatever arrives from now)", minimum: 0),
                    ]) { a, _ in a }), kind: .read),
            kind: .read
        ) { arguments in
            let store = try self.store
            var query = try self.messageQuery(arguments)
            if !arguments.has("direction") { query.direction = .received }
            let start = try arguments.int("after_id").map(Int64.init) ?? store.maxMessageRowID()
            let deadline = Date().addingTimeInterval(Double(try arguments.int("timeout", default: 60, in: 1...300)))
            var found: [MessageSummary] = []
            var version: Int64 = -1
            repeat {
                let current = try store.dataVersion()
                if current != version {
                    version = current
                    found = try self.arrivals(after: start, matching: query)
                    if !found.isEmpty { break }
                }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } while Date() < deadline
            let latest = max(start, try store.maxMessageRowID())
            return ToolReply(
                json: .obj([
                    ("arrived", .int(Int64(found.count))),
                    ("latest_id", .int(latest)),
                    ("timed_out", found.isEmpty ? .bool(true) : nil),
                    ("messages", .array(found.map { Render.message($0, link: true) })),
                ]),
                summary: found.isEmpty ? "nothing new" : "\(found.count) arrived", messageID: found.first?.id)
        }
    }
}

/// Live views of the mailbox as MCP resources. Clients that subscribe get `notifications/resources/updated`
/// when Mail's database changes (new mail, reads, moves), checked every few seconds.
public final class MailResources: @unchecked Sendable {
    public static let unreadURI = "mail://inbox/unread"
    public static let needsResponseURI = "mail://needs-response"

    let toolbox: MailToolbox
    private let lock = NSLock()
    private var subscriptions = Set<String>()
    private var lastVersion: Int64?

    public init(toolbox: MailToolbox) { self.toolbox = toolbox }

    public var resources: [Resource] {
        [
            Resource(
                name: "unread-inbox", uri: Self.unreadURI, title: "Unread in the inbox",
                description: "The 25 newest unread inbox messages of every account, with ids and links.", mimeType: "application/json"),
            Resource(
                name: "needs-response", uri: Self.needsResponseURI, title: "Needs a reply",
                description: "Mail from people from the last 7 days still waiting on you.", mimeType: "application/json"),
        ]
    }

    public func read(_ uri: String) throws -> ReadResource.Result {
        let store = try toolbox.store
        let messages: [MessageSummary]
        switch uri {
        case Self.unreadURI:
            var query = MessageQuery()
            query.mailboxIDs = try store.mailboxes().filter { $0.role == .inbox }.map(\.id)
            query.isRead = false
            query.limit = 25
            messages = query.mailboxIDs.isEmpty ? [] : try store.search(query).messages
        case Self.needsResponseURI:
            messages = try store.needsResponse(days: 7, limit: 25)
        default:
            throw MCPError.invalidParams("Unknown resource \(uri)")
        }
        let json = JSON.obj([("messages", .array(messages.map { Render.message($0, link: true) }))])
        return ReadResource.Result(contents: [.text(json.serialized(), uri: uri, mimeType: "application/json")])
    }

    public func subscribe(_ uri: String) throws {
        guard resources.contains(where: { $0.uri == uri }) else { throw MCPError.invalidParams("Unknown resource \(uri)") }
        lock.withLock { _ = subscriptions.insert(uri) }
    }

    public func unsubscribe(_ uri: String) { lock.withLock { _ = subscriptions.remove(uri) } }

    /// The subscribed URIs to notify, when Mail's database changed since the last look.
    public func changedSubscriptions() -> [String] {
        let subscribed = lock.withLock { subscriptions }
        guard !subscribed.isEmpty, let version = try? toolbox.store.dataVersion() else { return [] }
        let previous = lock.withLock { () -> Int64? in
            defer { lastVersion = version }
            return lastVersion
        }
        guard let previous, previous != version else { return [] }
        return subscribed.sorted()
    }
}
