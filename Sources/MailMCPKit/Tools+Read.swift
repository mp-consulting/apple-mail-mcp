import Foundation
import MCP
import MailStore

extension MailToolbox {
    var readTools: [ToolDefinition] {
        [
            listAccounts, listMailboxes, inboxOverview, searchMessages, getMessage, getMessages, getThread, listAttachments,
            getMessageSource, extractInvoiceFields, statistics, topSenders, awaitingReply, needsResponse, bodyIndexTool,
        ]
    }

    // MARK: Accounts and mailboxes

    var listAccounts: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "list_accounts", "List accounts", "Mail accounts with their addresses and inbox counts.",
                Schema.object([:]), kind: .read),
            kind: .read
        ) { _ in
            let store = try self.store
            let accounts = try store.accounts()
            let mailboxes = try store.mailboxes()
            let items: [JSON] = accounts.map { account in
                let inboxes = mailboxes.filter { $0.accountID == account.id && $0.role == .inbox }
                return .obj([
                    ("name", .string(account.name)),
                    ("id", .string(account.id)),
                    ("type", .string(account.kind)),
                    ("addresses", account.emailAddresses.isEmpty ? nil : .array(account.emailAddresses.map { .string($0) })),
                    ("mailboxes", .int(Int64(mailboxes.filter { $0.accountID == account.id }.count))),
                    ("inbox_unread", inboxes.isEmpty ? nil : .int(Int64(inboxes.reduce(0) { $0 + $1.unreadCount }))),
                ])
            }
            return ToolReply(json: .obj([("accounts", .array(items))]), summary: "\(accounts.count) accounts")
        }
    }

    var listMailboxes: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "list_mailboxes", "List mailboxes",
                "Mailboxes (folders) with message and unread counts. Paths are what other tools accept as `mailbox`.",
                Schema.object([
                    "account": Schema.string("Account name, id or address; omit for all accounts"),
                    "include_empty": Schema.boolean("Include mailboxes with no messages (default true)"),
                ]), kind: .read),
            kind: .read
        ) { arguments in
            let store = try self.store
            let accountID = try self.resolveAccountID(arguments)
            let includeEmpty = try arguments.bool("include_empty") ?? true
            let accounts = Dictionary(uniqueKeysWithValues: try store.accounts().map { ($0.id, $0.name) })
            let boxes = try store.mailboxes(accountID: accountID).filter { includeEmpty || $0.totalCount > 0 }
            var byAccount: [(String, [JSON])] = []
            for (account, list) in Dictionary(grouping: boxes, by: \.accountID).sorted(by: { accounts[$0.key] ?? "" < accounts[$1.key] ?? "" }) {
                byAccount.append((accounts[account] ?? account, list.map { box in
                    .obj([
                        ("path", .string(box.path)),
                        ("role", box.role == .other ? nil : .string(box.role.rawValue)),
                        ("messages", .int(Int64(box.totalCount))),
                        ("unread", box.unreadCount > 0 ? .int(Int64(box.unreadCount)) : nil),
                        ("label", box.sourceMailboxID != nil ? .bool(true) : nil),
                    ])
                }))
            }
            return ToolReply(
                json: .object(byAccount.map { ($0.0, .array($0.1)) }), summary: "\(boxes.count) mailboxes")
        }
    }

    var inboxOverview: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "inbox_overview", "Inbox overview",
                "One-call dashboard: unread counts per account, the latest unread messages, what likely needs a reply, and flagged mail.",
                Schema.object([
                    "account": Schema.string("Limit to one account"),
                    "recent": Schema.integer("How many recent unread messages to include (default 10)", minimum: 0, maximum: 50),
                ]), kind: .read),
            kind: .read
        ) { arguments in
            let store = try self.store
            let accountID = try self.resolveAccountID(arguments)
            let recentCount = try arguments.int("recent") ?? 10
            let accounts = try store.accounts().filter { accountID == nil || $0.id == accountID }
            let inboxes = try store.mailboxes(accountID: accountID).filter { $0.role == .inbox }
            var unread = MessageQuery()
            unread.mailboxIDs = inboxes.map(\.id)
            unread.isRead = false
            unread.limit = max(1, recentCount)
            let unreadPage = inboxes.isEmpty ? nil : try store.search(unread)
            var flagged = MessageQuery()
            if let accountID { flagged.accountIDs = [accountID] }
            flagged.isFlagged = true
            flagged.limit = 10
            let flaggedPage = try store.search(flagged)
            let needs = try store.needsResponse(days: 7, accountID: accountID, limit: 5)
            let perAccount: [JSON] = accounts.map { account in
                let boxes = inboxes.filter { $0.accountID == account.id }
                return .obj([
                    ("account", .string(account.name)),
                    ("inbox_messages", .int(Int64(boxes.reduce(0) { $0 + $1.totalCount }))),
                    ("inbox_unread", .int(Int64(boxes.reduce(0) { $0 + $1.unreadCount }))),
                ])
            }
            let json = JSON.obj([
                ("accounts", .array(perAccount)),
                ("unread_total", .int(Int64(unreadPage?.total ?? 0))),
                ("recent_unread", recentCount > 0 ? .array((unreadPage?.messages ?? []).prefix(recentCount).map { Render.message($0) }) : nil),
                ("needs_response", .array(needs.map { Render.message($0, preview: false) })),
                ("flagged_total", .int(Int64(flaggedPage.total ?? 0))),
                ("flagged", .array(flaggedPage.messages.map { Render.message($0, preview: false) })),
            ])
            return ToolReply(json: json, summary: "\(unreadPage?.total ?? 0) unread")
        }
    }

    // MARK: Search

    /// Filters shared by search_messages, export_search and grouping.
    static let filterSchema: [String: Value] = [
        "query": Schema.string("Text in the subject, sender or preview; comma-separate alternatives (any matches)"),
        "subject": Schema.string("Text in the subject (comma-separate alternatives)"),
        "sender": Schema.string("Sender name or address (substring)"),
        "recipient": Schema.string("To/Cc/Bcc name or address (substring)"),
        "body": Schema.string("Words in the message body; \"quoted phrase\" for exact phrases"),
        "exclude_subject": Schema.string("Leave out subjects containing any of these (comma-separated)"),
        "exclude_sender": Schema.string("Leave out senders whose name or address contains any of these (comma-separated)"),
        "exclude_replies": Schema.boolean("Leave out replies (Re:, AW:, SV:… subjects)"),
        "exclude_from_self": Schema.boolean("Leave out mail from your own addresses and names (settings: own addresses and names)"),
        "direction": Schema.string(
            "received = not in Sent/Drafts/Outbox and not from you; sent = sent by you; any (default)",
            enum: MessageDirection.allCases.map(\.rawValue)),
        "account": Schema.string("Account name, id or address"),
        "mailbox": Schema.string("Mailbox path or role (inbox, sent, drafts, archive, trash, junk); default all except Trash/Junk"),
        "unread": Schema.boolean("true = only unread, false = only read"),
        "flagged": Schema.boolean("Only flagged (true) or unflagged (false) messages"),
        "flag_color": Schema.string("Flag colour", enum: FlagColor.allCases.map(\.name)),
        "has_attachments": Schema.boolean("Only messages with (true) or without (false) attachments"),
        "category": Schema.string(
            "Mail's categories (macOS 15+), comma-separated: \(MailCategory.allCases.map(\.name).joined(separator: ", "))"),
        "days": Schema.integer("Only the last N days", minimum: 1),
        "date_from": Schema.string("Earliest date received, YYYY-MM-DD"),
        "date_to": Schema.string("Latest date received, YYYY-MM-DD (inclusive)"),
        "include_trash": Schema.boolean("Also search Trash and Junk (default false)"),
        "sort": Schema.string("newest (default) or oldest", enum: ["newest", "oldest"]),
    ]

    /// A store query from the shared filter arguments (paging is left to the caller).
    func messageQuery(_ arguments: Arguments) throws -> MessageQuery {
        let store = try self.store
        var query = MessageQuery()
        let accountID = try resolveAccountID(arguments)
        if let accountID { query.accountIDs = [accountID] }
        query.mailboxIDs = try resolveMailboxIDs(arguments, accountID: accountID)
        let terms = try arguments.strings("query")
        // One term keeps commas-free text as typed; several become alternatives.
        if terms.count == 1 { query.text = terms[0] } else { query.textTerms = terms }
        query.subjectTerms = try arguments.strings("subject")
        query.sender = try arguments.string("sender")
        query.recipient = try arguments.string("recipient")
        query.bodyText = try arguments.string("body")
        query.excludeSubjectTerms = try arguments.strings("exclude_subject")
        query.excludeSenders = try arguments.strings("exclude_sender")
        query.excludeReplies = try arguments.bool("exclude_replies") ?? false
        if try arguments.bool("exclude_from_self") ?? false {
            let current = settings.current
            query.excludeSenderAddresses = Array(try store.ownAddresses()) + current.ownAddresses
            query.excludeSenders += current.ownNames
        }
        if let direction = try arguments.string("direction") {
            guard let value = MessageDirection(rawValue: direction.lowercased()) else {
                throw ToolError("direction must be received, sent or any")
            }
            query.direction = value
        }
        if let unread = try arguments.bool("unread") { query.isRead = !unread }
        query.isFlagged = try arguments.bool("flagged")
        if let color = try arguments.string("flag_color") {
            guard let flag = FlagColor(name: color) else { throw ToolError("unknown flag_color \(color)") }
            query.flagColor = flag
        }
        query.hasAttachments = try arguments.bool("has_attachments")
        query.categories = try arguments.strings("category").map { name in
            guard let value = MailCategory(name: name) else {
                throw ToolError("unknown category \(name); use \(MailCategory.allCases.map(\.name).joined(separator: ", "))")
            }
            return value
        }
        if let days = try arguments.int("days") { query.dateFrom = Date().addingTimeInterval(-Double(days) * 86_400) }
        if let from = try arguments.date("date_from") { query.dateFrom = from }
        query.dateTo = try arguments.date("date_to", endOfDay: true)
        query.includeTrashAndJunk = try arguments.bool("include_trash") ?? false
        query.sortAscending = try arguments.string("sort") == "oldest"
        return query
    }

    var searchMessages: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "search_messages", "Search messages",
                """
                Search mail by any combination of filters; results are newest first with ids and message:// links. \
                Fast on any mailbox size (reads Mail's index directly). `body` searches message text: instant when \
                the body index is built (see body_index), otherwise a bounded scan of recent messages. \
                For hundreds of results use export_search (writes a file) or group_by (counts only).
                """,
                Schema.object(
                    Self.filterSchema.merging([
                        "limit": Schema.integer("Results per page (default 20, max 200)", minimum: 1, maximum: 200),
                        "offset": Schema.integer("Skip this many results (pagination)", minimum: 0),
                        "compact": Schema.boolean("Leave out previews (smaller output; default false)"),
                        "group_by": Schema.string(
                            "Return counts per sender, domain or month instead of messages", enum: GroupKey.allCases.map(\.rawValue)),
                    ]) { a, _ in a }), kind: .read),
            kind: .read
        ) { arguments in
            let store = try self.store
            var query = try self.messageQuery(arguments)
            let (bodyIndex, indexLocked) = self.searchIndex(for: query)
            if let group = try arguments.string("group_by") {
                guard let key = GroupKey(rawValue: group.lowercased()) else { throw ToolError("group_by must be sender, domain or month") }
                let groups = try store.groupCounts(query, by: key, bodyIndex: bodyIndex, limit: try arguments.int("limit") ?? 50)
                let json = JSON.obj([
                    ("group_by", .string(key.rawValue)),
                    ("groups", .array(groups.map { g in
                        .obj([
                            ("key", .string(g.key)), ("name", g.name.map { .string($0) }), ("count", .int(Int64(g.count))),
                            ("unread", g.unread > 0 ? .int(Int64(g.unread)) : nil),
                        ])
                    })),
                ])
                return ToolReply(json: json, summary: "\(groups.count) groups")
            }
            query.limit = min(200, max(1, try arguments.int("limit") ?? 20))
            query.offset = max(0, try arguments.int("offset") ?? 0)
            let compact = try arguments.bool("compact") ?? false
            let page = try store.search(query, bodyIndex: bodyIndex)
            var notes: [JSON] = []
            if indexLocked {
                notes.append(.string("The search index key was not available from the Keychain, so recent messages were scanned instead."))
            }
            if page.scanLimited {
                notes.append(
                    .string(
                        "Body search stopped after scanning \(page.scannedMessages) messages without a complete index. Narrow it (account, mailbox, days) or build the index with body_index action \"update\"."))
            }
            let json = JSON.obj([
                ("total", page.total.map { .int(Int64($0)) }),
                ("offset", .int(Int64(page.offset))),
                ("returned", .int(Int64(page.messages.count))),
                ("has_more", .bool(page.hasMore)),
                ("body_search", page.bodySearchMode.map { .string($0) }),
                ("notes", notes.isEmpty ? nil : .array(notes)),
                ("messages", .array(page.messages.map { Render.message($0, preview: !compact, link: true) })),
            ])
            return ToolReply(json: json, summary: "\(page.total.map(String.init) ?? "\(page.messages.count)+") results")
        }
    }

    // MARK: Messages

    var getMessage: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "get_message", "Read message",
                "Full message: headers, recipients, body text and attachment list.",
                Schema.object(
                    [
                        "id": Schema.integer("Message id"),
                        "max_chars": Schema.integer("Truncate the body to this many characters (default 20000, 0 = no limit)", minimum: 0),
                        "strip_quotes": Schema.boolean("Drop quoted earlier messages from the body (default false)"),
                        "include_html": Schema.boolean("Also return the raw HTML body (default false)"),
                        "include_headers": Schema.boolean("Include every header (default false)"),
                    ], required: ["id"]), kind: .read),
            kind: .read
        ) { arguments in
            let store = try self.store
            guard let id = try arguments.ids("id").first else { throw ToolError("id is required") }
            let detail = try store.detail(id: id)
            let maxChars = try arguments.int("max_chars") ?? 20_000
            var body = detail.textBody ?? ""
            if try arguments.bool("strip_quotes") ?? false { body = MessageContent.stripQuotedReply(body) }
            let truncated = maxChars > 0 && body.count > maxChars
            let s = detail.summary
            let json = JSON.obj([
                ("id", .int(s.id)),
                ("date", Render.date(s.dateReceived)),
                ("from", .string(s.sender.formatted)),
                ("to", Render.addresses(detail.to)),
                ("cc", Render.addresses(detail.cc)),
                ("reply_to", Render.addresses(detail.replyTo)),
                ("subject", .string(s.subject)),
                ("account", .string(s.accountName)),
                ("mailbox", .string(s.mailboxPath)),
                ("unread", s.isRead ? nil : .bool(true)),
                ("flag", s.flagColor.map { .string($0.name) }),
                ("category", s.category.map { .string($0.name) }),
                ("message_id", s.messageIDHeader.map { .string($0) }),
                ("link", s.mailLink.map { .string($0) }),
                ("attachments", detail.attachments.isEmpty ? nil : .array(detail.attachments.map(Self.attachmentJSON))),
                ("body_downloaded", detail.bodyAvailable ? nil : .bool(false)),
                ("note", detail.bodyAvailable ? nil : .string("Mail has not downloaded this message's body yet; showing its preview.")),
                ("body", .string(detail.bodyAvailable ? Render.truncate(body, maxChars) : (s.preview ?? ""))),
                ("body_truncated", truncated ? .bool(true) : nil),
                ("html", try arguments.bool("include_html") ?? false ? detail.htmlBody.map { .string(Render.truncate($0, maxChars)) } : nil),
                ("headers", try arguments.bool("include_headers") ?? false
                    ? .array(detail.headers.map { .string("\($0.name): \($0.value)") }) : nil),
            ])
            return ToolReply(json: json, summary: "message \(id)", messageID: id)
        }
    }

    static func attachmentJSON(_ a: AttachmentInfo) -> JSON {
        .obj([
            ("part", .string(a.partID)),
            ("name", .string(a.filename)),
            ("type", .string(a.mimeType)),
            ("size", a.size.map { .int(Int64($0)) }),
            ("downloaded", a.isDownloaded ? nil : .bool(false)),
        ])
    }

    var getThread: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "get_thread", "Read conversation",
                "Every message in the conversation of a message, oldest first, with bodies (quotes stripped by default).",
                Schema.object(
                    [
                        "id": Schema.integer("Any message id in the conversation"),
                        "max_chars": Schema.integer("Characters of body per message (default 3000, 0 = none)", minimum: 0),
                        "strip_quotes": Schema.boolean("Drop quoted text from each body (default true)"),
                    ], required: ["id"]), kind: .read),
            kind: .read
        ) { arguments in
            let store = try self.store
            guard let id = try arguments.ids("id").first else { throw ToolError("id is required") }
            let maxChars = try arguments.int("max_chars") ?? 3000
            let strip = try arguments.bool("strip_quotes") ?? true
            let messages = try store.thread(of: id, limit: 50)
            let items: [JSON] = messages.map { message in
                var entry: [(String, JSON?)] = [
                    ("id", .int(message.id)), ("date", Render.date(message.dateReceived)),
                    ("from", .string(message.sender.formatted)), ("subject", .string(message.subject)),
                    ("mailbox", .string(message.mailboxPath)),
                ]
                if maxChars > 0, let detail = try? store.detail(id: message.id) {
                    entry.append(("to", Render.addresses(detail.to)))
                    var body = detail.textBody ?? message.preview ?? ""
                    if strip { body = MessageContent.stripQuotedReply(body) }
                    entry.append(("body", .string(Render.truncate(body, maxChars))))
                }
                return .obj(entry)
            }
            return ToolReply(
                json: .obj([("count", .int(Int64(items.count))), ("messages", .array(items))]), summary: "\(items.count) in thread",
                messageID: messages.last?.id ?? id)
        }
    }

    var listAttachments: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "list_attachments", "List attachments", "Attachments of a message with part ids, names, types and sizes.",
                Schema.object(["id": Schema.integer("Message id")], required: ["id"]), kind: .read),
            kind: .read
        ) { arguments in
            let store = try self.store
            guard let id = try arguments.ids("id").first else { throw ToolError("id is required") }
            let detail = try store.detail(id: id)
            return ToolReply(
                json: .obj([("id", .int(id)), ("attachments", .array(detail.attachments.map(Self.attachmentJSON)))]),
                summary: "\(detail.attachments.count) attachments", messageID: id)
        }
    }

    var getMessageSource: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "get_message_source", "Message source",
                "Raw RFC 822 source of a message (headers only by default), e.g. to check authentication results or routing.",
                Schema.object(
                    [
                        "id": Schema.integer("Message id"),
                        "headers_only": Schema.boolean("Only the header block (default true)"),
                        "max_bytes": Schema.integer("Truncate to this many bytes (default 100000)", minimum: 1000),
                    ], required: ["id"]), kind: .read),
            kind: .read
        ) { arguments in
            let store = try self.store
            guard let id = try arguments.ids("id").first else { throw ToolError("id is required") }
            let data = try store.rawSource(id: id)
            var text = MIME.decodeText(data, charset: "utf-8")
            if try arguments.bool("headers_only") ?? true {
                if let range = text.range(of: "\r\n\r\n") ?? text.range(of: "\n\n") { text = String(text[..<range.lowerBound]) }
            }
            let maxBytes = try arguments.int("max_bytes") ?? 100_000
            let truncated = text.utf8.count > maxBytes
            if truncated { text = String(decoding: text.utf8.prefix(maxBytes), as: UTF8.self) }
            return ToolReply(
                json: .obj([("id", .int(id)), ("source", .string(text)), ("truncated", truncated ? .bool(true) : nil)]),
                summary: "\(text.utf8.count) bytes", messageID: id)
        }
    }

    // MARK: Insights

    var statistics: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "mail_statistics", "Mail statistics",
                "Volume, unread and flagged counts, busiest days and hours, top senders and domains, and categories for a period.",
                Schema.object([
                    "account": Schema.string("Account name, id or address"),
                    "mailbox": Schema.string("Mailbox path or role; default all except Trash/Junk"),
                    "days": Schema.integer("Period in days (default 30)", minimum: 1),
                ]), kind: .read),
            kind: .read
        ) { arguments in
            let store = try self.store
            let accountID = try self.resolveAccountID(arguments)
            let mailboxes = try self.resolveMailboxIDs(arguments, accountID: accountID)
            let days = try arguments.int("days") ?? 30
            let stats = try store.statistics(accountID: accountID, mailboxIDs: mailboxes, days: days)
            let busiestDays = stats.perDay.sorted { $0.value > $1.value }.prefix(5)
            let json = JSON.obj([
                ("days", .int(Int64(days))),
                ("received", .int(Int64(stats.received))),
                ("unread", .int(Int64(stats.unread))),
                ("flagged", .int(Int64(stats.flagged))),
                ("with_attachments", .int(Int64(stats.withAttachments))),
                ("sent_by_me", .int(Int64(stats.sentByMe))),
                ("per_day_average", .double((Double(stats.received) / Double(max(1, days)) * 10).rounded() / 10)),
                ("busiest_days", .object(busiestDays.map { ($0.key, .int(Int64($0.value))) })),
                ("per_weekday", .object(
                    ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"].map { ($0, .int(Int64(stats.perWeekday[$0] ?? 0))) })),
                ("per_hour", .object((0..<24).compactMap { hour in stats.perHour[hour].map { (String(format: "%02d", hour), .int(Int64($0))) } })),
                ("categories", stats.categories.isEmpty ? nil : .object(stats.categories.sorted { $0.value > $1.value }.map { ($0.key, .int(Int64($0.value))) })),
                ("top_senders", .array(stats.topSenders.map(Self.senderJSON))),
                ("top_domains", .array(stats.topDomains.map(Self.senderJSON))),
            ])
            return ToolReply(json: json, summary: "\(stats.received) messages in \(days) days")
        }
    }

    static func senderJSON(_ s: SenderCount) -> JSON {
        .obj([("sender", .string(s.key)), ("name", s.name.map { .string($0) }), ("count", .int(Int64(s.count))), ("unread", s.unread > 0 ? .int(Int64(s.unread)) : nil)])
    }

    var topSenders: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "top_senders", "Top senders", "Who sends the most mail (or which domains), with unread counts.",
                Schema.object([
                    "account": Schema.string("Account name, id or address"),
                    "mailbox": Schema.string("Mailbox path or role"),
                    "days": Schema.integer("Period in days (default 30; 0 = all time)", minimum: 0),
                    "by_domain": Schema.boolean("Group by sender domain (default false)"),
                    "limit": Schema.integer("How many (default 15)", minimum: 1, maximum: 200),
                ]), kind: .read),
            kind: .read
        ) { arguments in
            let store = try self.store
            let accountID = try self.resolveAccountID(arguments)
            let mailboxes = try self.resolveMailboxIDs(arguments, accountID: accountID)
            let days = try arguments.int("days") ?? 30
            let senders = try store.topSenders(
                accountID: accountID, mailboxIDs: mailboxes, days: days == 0 ? nil : days,
                byDomain: try arguments.bool("by_domain") ?? false, limit: try arguments.int("limit") ?? 15)
            return ToolReply(json: .obj([("senders", .array(senders.map(Self.senderJSON)))]), summary: "\(senders.count) senders")
        }
    }

    var awaitingReply: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "awaiting_reply", "Awaiting reply",
                "Messages you sent that nobody has answered yet (latest per conversation, at least min_age_hours old).",
                Schema.object([
                    "days": Schema.integer("Look back this many days (default 14)", minimum: 1),
                    "min_age_hours": Schema.integer("Ignore messages younger than this (default 24)", minimum: 0),
                    "account": Schema.string("Account name, id or address"),
                    "limit": Schema.integer("Maximum results (default 25)", minimum: 1, maximum: 200),
                ]), kind: .read),
            kind: .read
        ) { arguments in
            let store = try self.store
            let list = try store.awaitingReply(
                days: try arguments.int("days") ?? 14, minimumAgeHours: try arguments.int("min_age_hours") ?? 24,
                accountID: try self.resolveAccountID(arguments), limit: try arguments.int("limit") ?? 25)
            return ToolReply(json: .obj([("messages", .array(list.map { Render.message($0) }))]), summary: "\(list.count) awaiting reply")
        }
    }

    var needsResponse: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "needs_response", "Needs response",
                """
                Inbox messages from people (not lists, newsletters, promotions or no-reply senders) addressed to you, \
                where the conversation's latest message is theirs.
                """,
                Schema.object([
                    "days": Schema.integer("Look back this many days (default 7)", minimum: 1),
                    "account": Schema.string("Account name, id or address"),
                    "include_read": Schema.boolean("Include messages already read (default true)"),
                    "limit": Schema.integer("Maximum results (default 25)", minimum: 1, maximum: 200),
                ]), kind: .read),
            kind: .read
        ) { arguments in
            let store = try self.store
            let list = try store.needsResponse(
                days: try arguments.int("days") ?? 7, accountID: try self.resolveAccountID(arguments),
                includeRead: try arguments.bool("include_read") ?? true, limit: try arguments.int("limit") ?? 25)
            return ToolReply(json: .obj([("messages", .array(list.map { Render.message($0) }))]), summary: "\(list.count) need a response")
        }
    }

    var bodyIndexTool: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "body_index", "Body search index",
                """
                Status of the local full-text index that makes body searches instant, or update it. The menu bar app \
                keeps it current automatically; "update" indexes new messages for up to time_budget seconds.
                """,
                Schema.object([
                    "action": Schema.string("status (default) or update", enum: ["status", "update"]),
                    "time_budget": Schema.integer("Seconds to spend updating (default 25)", minimum: 1, maximum: 600),
                ]), kind: .read),
            kind: .read
        ) { arguments in
            let store = try self.store
            let action = try arguments.string("action") ?? "status"
            var updated: BodyIndex.UpdateResult?
            if action == "update" {
                let index = try self.openBodyIndexForWriting()
                updated = try index.update(from: store, timeBudget: Double(try arguments.int("time_budget") ?? 25))
            }
            guard let index = self.bodyIndex else {
                return ToolReply(
                    json: .obj([("built", .bool(false)), ("hint", .string("Run body_index with action \"update\", or let the menu bar app build it."))]),
                    summary: "no index")
            }
            let status = try index.status()
            let total = try store.messageCount()
            let remaining = try store.countMessages(after: status.coveredThrough)
            let json = JSON.obj([
                ("built", .bool(true)),
                ("indexed_messages", .int(Int64(status.indexedMessages))),
                ("messages_in_mail", .int(Int64(total))),
                ("not_yet_indexed", .int(Int64(remaining))),
                ("waiting_for_download", .int(Int64(status.pendingMessages))),
                ("size_mb", .double((Double(status.sizeBytes) / 1_048_576 * 10).rounded() / 10)),
                ("last_update", status.lastUpdate.map(Render.date)),
                ("this_update", updated.map { .obj([("indexed", .int(Int64($0.indexed))), ("seconds", .double(($0.duration * 10).rounded() / 10))]) }),
            ])
            return ToolReply(json: json, summary: updated.map { "indexed \($0.indexed)" } ?? "\(status.indexedMessages) indexed")
        }
    }
}
