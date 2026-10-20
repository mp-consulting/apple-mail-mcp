import Foundation
import MCP
import MailAutomation
import MailStore

/// `apply_rules`: Mail's rule engine (`MFMessageRouter`) redone on the read side, because Mail gives other apps no
/// way to run Message › Apply Rules (no scripting command, no Shortcuts action). It follows the engine: rules in
/// Mail's order (or as named), all or any of a rule's conditions, an address condition matched on the address and
/// the name, comparisons that ignore case, and the first rule that moves, deletes or stops evaluating ends a
/// message's turn. Messages in Sent, Drafts, Trash and Outbox are left out, as Mail leaves them out of its rules.
/// The actions go through the tools used by hand (moves and trashes checked in Mail's database, undoable, asked
/// for above the user's threshold), so a dry run shows exactly what will happen.
extension MailToolbox {
    var applyRules: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "apply_rules", "Apply Mail rules",
                """
                Run Mail rules on messages already in a mailbox (what Message › Apply Rules does in Mail): every \
                enabled rule in Mail's order, or the rules named. Dry run by default: shows which messages each rule \
                matches and what would happen; pass dry_run false to do it. Rules whose conditions or actions this \
                cannot reproduce exactly are skipped and listed (forwarding, replies and AppleScripts among them); \
                notifications and sounds are not played. Moves, flags and trashes can be undone with undo_change.
                """,
                Schema.object(
                    [
                        "rules": Schema.strings("Rules to apply, by name (default: every enabled rule, in Mail's order)"),
                        "mailbox": Schema.string("Mailbox to apply them to (path or role, e.g. inbox)"),
                        "account": Schema.string("Account of the mailbox"),
                        "ids": Schema.ids("Or these messages"),
                        "limit": Schema.integer("Newest messages of the mailbox to look at (default 100)", minimum: 1, maximum: 1000),
                        "dry_run": Schema.boolean("Only show what would happen (default true)"),
                    ]), kind: .mailChange),
            kind: .mailChange
        ) { [automation] arguments in
            let store = try self.store
            let dryRun = try arguments.bool("dry_run") ?? true
            if !dryRun { try self.requireMailChanges() }

            // Which rules, in Mail's order.
            let saved = store.rules()
            let names = try arguments.strings("rules")
            let chosen: [MailRule]
            if names.isEmpty {
                chosen = saved.filter { $0.enabled == true }
                guard !chosen.isEmpty else { throw ToolError("No rule is turned on; name the rules to apply") }
            } else {
                chosen = try names.map { name in
                    let matching = saved.filter { $0.name == name }
                    guard matching.count == 1 else {
                        throw ToolError(matching.isEmpty ? "No rule named \"\(name)\" (mail_setup lists them)" : "\(matching.count) rules are named \"\(name)\"")
                    }
                    return matching[0]
                }
            }

            // Which messages.
            var messages: [MessageSummary]
            let ids = try arguments.ids("ids")
            if !ids.isEmpty {
                try self.checkBatch(ids)
                messages = try store.messages(ids: ids)
            } else {
                let mailboxIDs = try self.resolveMailboxIDs(arguments, accountID: try self.resolveAccountID(arguments))
                guard !mailboxIDs.isEmpty else { throw ToolError("Give mailbox (e.g. inbox) or ids") }
                var query = MessageQuery()
                query.mailboxIDs = mailboxIDs
                query.includeTrashAndJunk = true
                query.limit = try arguments.int("limit", default: 100, in: 1...1000)
                messages = try store.search(query).messages
            }
            var boxes: [Int64: Mailbox] = [:]
            for id in Set(messages.map(\.mailboxID)) { boxes[id] = try store.mailbox(id: id) }
            let excludedRoles: Set<MailboxRole> = [.sent, .drafts, .trash, .outbox]
            let leftOut = messages.filter { boxes[$0.mailboxID].map { excludedRoles.contains($0.role) } ?? false }.count
            messages.removeAll { boxes[$0.mailboxID].map { excludedRoles.contains($0.role) } ?? false }

            // Rules that cannot be applied as Mail would, and the mailboxes the others name.
            let evaluator = try RuleEvaluator(store: store, contacts: [:])
            var skipped: [(String, String)] = []
            var usable: [(rule: MailRule, move: Mailbox?, copy: Mailbox?)] = []
            for rule in chosen {
                if let reason = RuleEvaluator.unsupported(rule) { skipped.append((rule.name, reason)); continue }
                let move = try rule.definition.moveTo.map { try store.mailbox(ruleURL: $0) }
                let copy = try rule.definition.copyTo.map { try store.mailbox(ruleURL: $0) }
                if rule.definition.moveTo != nil, move == nil { skipped.append((rule.name, "its move mailbox no longer exists")); continue }
                if rule.definition.copyTo != nil, copy == nil { skipped.append((rule.name, "its copy mailbox no longer exists")); continue }
                usable.append((rule, move ?? nil, copy ?? nil))
            }
            // Contacts conditions: look each sender up once.
            if usable.contains(where: { $0.rule.criteria.contains { $0.field.hasPrefix("SenderIs") && $0.field.contains("AddressBook") } }) {
                var known: [String: Bool] = [:]
                lookups: for address in Set(messages.map { $0.sender.address.lowercased() }) {
                    switch await self.contacts.search(address, limit: 5) {
                    case .found(let cards):
                        known[address] = cards.contains { $0.emails.contains { $0.address.caseInsensitiveCompare(address) == .orderedSame } }
                    case .unavailable(let reason):
                        let needsContacts = { (rule: MailRule) in rule.criteria.contains { $0.field.contains("AddressBook") } }
                        for entry in usable where needsContacts(entry.rule) { skipped.append((entry.rule.name, "it needs Contacts: \(reason)")) }
                        usable.removeAll { needsContacts($0.rule) }
                        break lookups
                    }
                }
                evaluator.contacts = known
            }

            // What happens to each message.
            var plans: [Int64: RulePlan] = [:]
            var matched: [String: [MessageSummary]] = [:]
            var undecided: [Int64] = []
            var ignored = Set<String>()
            for message in messages {
                var plan = RulePlan()
                for (rule, move, copy) in usable {
                    let outcome = try evaluator.evaluate(rule, message, mailbox: boxes[message.mailboxID])
                    if outcome == .unknown { undecided.append(message.id); break }
                    guard outcome == .match else { continue }
                    matched[rule.name, default: []].append(message)
                    plan.rules.append(rule.name)
                    let actions = rule.definition
                    if actions.markRead, !message.isRead { plan.markRead = true }
                    if let index = actions.flag, let flag = FlagColor(rawValue: index), message.flagColor != flag || !message.isFlagged { plan.flag = flag }
                    if let rgb = actions.color {
                        if actions.colorsText { ignored.insert("text colours") }
                        else if let color = MailRuleActions.colorNames[rgb].flatMap(RuleColor.init(rawValue:)) { plan.color = color }
                        else { ignored.insert("custom colours") }
                    }
                    if actions.notifies { ignored.insert("notifications") }
                    if actions.sound != nil { ignored.insert("sounds") }
                    if let copy, copy.id != message.mailboxID { plan.copyTo.append(copy) }
                    if let move, move.id != message.mailboxID { plan.moveTo = move }
                    if actions.deletes { plan.trash = true }
                    if actions.stopEvaluating || actions.deletes || move != nil { break }
                }
                if !plan.isEmpty { plans[message.id] = plan }
            }

            let summary = Self.planSummary(plans)
            var done: [JSON] = []
            if !dryRun, !plans.isEmpty {
                // One question for the whole run (above the user's threshold), not one per move or trash batch.
                try await self.authorizeApply(plans, messages: messages, rules: usable.map(\.rule), matched: matched)
                done = try await Self.$changesApproved.withValue(true) {
                    try await self.carryOut(plans, messages: messages, boxes: boxes, automation: automation)
                }
            }
            let json = JSON.obj([
                ("dry_run", dryRun ? .bool(true) : nil),
                ("messages", .int(Int64(messages.count))),
                ("changed", .int(Int64(plans.count))),
                ("left_out", leftOut > 0 ? .string("\(leftOut) in Sent, Drafts, Trash or Outbox") : nil),
                ("rules", .array(usable.map { entry in
                    let hits = matched[entry.rule.name] ?? []
                    return .obj([
                        ("name", .string(entry.rule.name)), ("matched", .int(Int64(hits.count))),
                        ("actions", .array(entry.rule.actions.map(JSON.string))),
                        ("examples", hits.isEmpty ? nil : .array(hits.prefix(10).map { message in
                            .obj([("id", .int(message.id)), ("from", .string(message.sender.formatted)), ("subject", .string(message.subject))])
                        })),
                    ])
                })),
                ("skipped_rules", skipped.isEmpty ? nil : .array(skipped.map { .obj([("name", .string($0.0)), ("reason", .string($0.1))]) })),
                ("not_evaluated", undecided.isEmpty ? nil : .obj([
                    ("ids", .array(undecided.prefix(50).map { .int($0) })),
                    ("reason", .string("Mail has not downloaded these messages yet, so their body and headers cannot be checked")),
                ])),
                ("ignored", ignored.isEmpty ? nil : .array(ignored.sorted().map(JSON.string))),
                ("plan", summary),
                ("done", done.isEmpty ? nil : .array(done)),
            ])
            let verb = dryRun ? "would change" : "changed"
            return ToolReply(json: json, summary: "\(verb) \(plans.count) of \(messages.count) messages with \(usable.count) rules")
        }
    }

    /// Asks once before changing more messages than the user's threshold, listing each rule and what it does.
    private func authorizeApply(
        _ plans: [Int64: RulePlan], messages: [MessageSummary], rules: [MailRule], matched: [String: [MessageSummary]]
    ) async throws {
        let threshold = settings.current.approveChangesAbove
        guard threshold > 0, plans.count > threshold else { return }
        var lines = rules.compactMap { rule -> String? in
            guard let hits = matched[rule.name], !hits.isEmpty else { return nil }
            return "\(rule.name): \(hits.count) — \(rule.actions.joined(separator: ", "))"
        }
        lines.append("")
        let changed = messages.filter { plans[$0.id] != nil }
        lines += changed.prefix(15).map { "\($0.sender.name ?? $0.sender.address) — \($0.subject)" }
        if changed.count > 15 { lines.append("… and \(changed.count - 15) more") }
        try await askUser(
            ApprovalRequest(
                id: UUID(), created: Date(), tool: "apply_rules", client: clientName, from: nil, to: [], cc: [], bcc: [],
                subject: "Apply \(rules.count == 1 ? "rule \"\(rules[0].name)\"" : "\(rules.count) rules") to \(changed.count) messages",
                bodyPreview: lines.joined(separator: "\n"), attachments: [], status: .pending, decided: nil, kind: .change),
            what: "Applying rules to \(changed.count) messages", declined: "The user declined. Nothing was changed.", nothing: "Nothing was changed.")
    }

    /// Carries out the plan through the tools used by hand: marks and flags first, then colours and copies, then
    /// moves and trashes (which give messages new ids).
    private func carryOut(
        _ plans: [Int64: RulePlan], messages: [MessageSummary], boxes: [Int64: Mailbox], automation: any MailAutomating
    ) async throws -> [JSON] {
        let order = messages.map(\.id).filter { plans[$0] != nil }
        let batch = max(1, settings.current.maxBatchSize)
        var done: [JSON] = []
        func run(_ tool: String, _ ids: [Int64], _ extra: [String: Value]) async throws {
            for start in stride(from: 0, to: ids.count, by: batch) {
                var arguments = extra
                arguments["ids"] = .array(ids[start..<min(start + batch, ids.count)].map { .int(Int($0)) })
                guard let definition = definitions.first(where: { $0.tool.name == tool }) else { return }
                let reply = try await definition.run(Arguments(arguments))
                done.append(.obj([("tool", .string(tool)), ("result", .string(reply.summary))]))
            }
        }
        let byID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        func mailbox(_ id: Int64) -> Mailbox? { byID[id].flatMap { boxes[$0.mailboxID] } }
        // A mailbox where a move or trash just went wrong is left alone as a whole, before anything changes.
        try checkBreaker(Array(Set(order.compactMap { mailbox($0)?.id })).sorted().compactMap { boxes[$0] })

        let read = order.filter { plans[$0]!.markRead }
        if !read.isEmpty { try await run("update_messages", read, ["read": .bool(true)]) }
        for flag in FlagColor.allCases {
            let ids = order.filter { plans[$0]!.flag == flag }
            if !ids.isEmpty { try await run("update_messages", ids, ["flag_color": .string(flag.name)]) }
        }
        for color in RuleColor.allCases {
            let ids = order.filter { plans[$0]!.color == color }
            for (box, group) in Dictionary(grouping: ids, by: { mailbox($0) }) {
                guard let box else { continue }
                let refs = try messageRefs(group.compactMap { byID[$0] }, in: box)
                let count = try await automation.exclusive { try await automation.setColor(refs, in: MailboxTarget(box), color: color) }
                done.append(.obj([("action", .string("colour \(color.rawValue)")), ("count", .int(Int64(count)))]))
            }
        }
        var copies: [String: (source: Mailbox, destination: Mailbox, ids: [Int64])] = [:]
        for id in order {
            guard let source = mailbox(id) else { continue }
            for destination in plans[id]!.copyTo {
                copies["\(source.id)→\(destination.id)", default: (source, destination, [])].ids.append(id)
            }
        }
        for (_, copy) in copies.sorted(by: { $0.key < $1.key }) {
            let refs = try messageRefs(copy.ids.compactMap { byID[$0] }, in: copy.source)
            let count = try await automation.exclusive {
                try await automation.copy(refs, from: MailboxTarget(copy.source), to: MailboxTarget(copy.destination))
            }
            done.append(.obj([("action", .string("copy to \(copy.destination.path)")), ("count", .int(Int64(count)))]))
        }
        do {
            for (_, group) in Dictionary(grouping: order.filter { plans[$0]!.moveTo != nil && !plans[$0]!.trash }, by: { plans[$0]!.moveTo!.id }).sorted(by: { $0.key < $1.key }) {
                let destination = plans[group[0]]!.moveTo!
                try await run("move_messages", group, ["to_mailbox": .string(destination.path), "to_account": .string(destination.accountID)])
            }
            let trash = order.filter { plans[$0]!.trash }
            if !trash.isEmpty { try await run("trash_messages", trash, [:]) }
        } catch where !done.isEmpty {
            // A batch that went wrong pauses its mailbox (see `ChangeBreaker`): report what was done up to there.
            done.append(.obj([("stopped", .string("\(error)"))]))
        }
        return done
    }

    static func planSummary(_ plans: [Int64: RulePlan]) -> JSON {
        let values = Array(plans.values)
        func count(_ test: (RulePlan) -> Bool) -> Int64 { Int64(values.filter(test).count) }
        let flags = FlagColor.allCases.compactMap { flag -> JSON? in
            let n = count { $0.flag == flag }
            return n == 0 ? nil : .obj([("color", .string(flag.name)), ("count", .int(n))])
        }
        let colors = RuleColor.allCases.compactMap { color -> JSON? in
            let n = count { $0.color == color }
            return n == 0 ? nil : .obj([("color", .string(color.rawValue)), ("count", .int(n))])
        }
        let moves = Dictionary(grouping: values.compactMap { $0.trash ? nil : $0.moveTo }, by: \.path).sorted { $0.key < $1.key }
        let copies = Dictionary(grouping: values.flatMap(\.copyTo), by: \.path).sorted { $0.key < $1.key }
        return .obj([
            ("mark_read", count(\.markRead) > 0 ? .int(count(\.markRead)) : nil),
            ("flag", flags.isEmpty ? nil : .array(flags)),
            ("colour", colors.isEmpty ? nil : .array(colors)),
            ("copy", copies.isEmpty ? nil : .array(copies.map { .obj([("to", .string($0.key)), ("count", .int(Int64($0.value.count)))]) })),
            ("move", moves.isEmpty ? nil : .array(moves.map { .obj([("to", .string($0.key)), ("count", .int(Int64($0.value.count)))]) })),
            ("trash", count(\.trash) > 0 ? .int(count(\.trash)) : nil),
        ])
    }
}

/// What the rules do to one message.
struct RulePlan {
    var markRead = false
    var flag: FlagColor?
    var color: RuleColor?
    var copyTo: [Mailbox] = []
    var moveTo: Mailbox?
    var trash = false
    var rules: [String] = []

    var isEmpty: Bool { !markRead && flag == nil && color == nil && copyTo.isEmpty && moveTo == nil && !trash }
}

/// Matches messages against saved Mail rules the way `-[MFMessageCriterion _evaluateMessage:…]` does.
final class RuleEvaluator {
    enum Outcome { case match, noMatch, unknown }

    let store: MailStore
    var contacts: [String: Bool]
    private let vips: Set<String>
    private let accounts: [MailAccount]
    private var details: [Int64: MessageDetail?] = [:]
    private var recipients: [Int64: (to: [EmailAddress], cc: [EmailAddress])] = [:]
    private var history: [String: Bool] = [:]

    init(store: MailStore, contacts: [String: Bool]) throws {
        self.store = store
        self.contacts = contacts
        vips = Set(store.vips().flatMap(\.addresses).map { $0.lowercased() })
        accounts = try store.accounts()
    }

    /// Mail's condition types (`+[MFMessageCriterion criterionIdentifierToTypeMapping]`); any other name is a header.
    static let mailCriteria: Set<String> = [
        "AllMailboxes", "AnyAttachment", "AnyMessage", "AnyRecipient", "AnyRecipientIncludesFullName", "AttachmentType", "Body",
        "Category", "Compound", "ContainsAttachments", "DateLastViewed", "DateReceived", "DateSent", "DisplayDate", "Flag",
        "FlaggedStatus", "FollowUpEndDate", "FollowUpStartDate", "From", "GlobalMessageID", "GmailLabel", "Header",
        "InSpecialMailbox", "IncludeMessagesInConversations", "IsDigitallySigned", "IsEncrypted", "IsInConversations",
        "IsJunkMail", "MatadorCriterion", "MessageID", "MessageNumber", "MessageType", "MightBeJunkMail",
        "NoRecipientIncludesFullName", "NotInASpecialMailbox", "NotInJunkMailbox", "NotInTrashMailbox", "PriorityIsHigh",
        "PriorityIsLow", "PriorityIsNormal", "ReadLaterDate", "SendLaterDate", "SenderBucket", "SenderIsInAddressBook",
        "SenderIsInAddressHistory", "SenderIsMemberOfGroup", "SenderIsMemberOfVIPSenders", "SenderIsNotInAddressBook",
        "SenderIsNotInAddressHistory", "SenderIsNotMemberOfGroup", "Size",
    ]
    static let supported: Set<String> = [
        "AnyAttachment", "AnyMessage", "AnyRecipient", "Body", "ContainsAttachments", "From", "IsJunkMail", "NotInJunkMailbox",
        "NotInTrashMailbox", "SenderIsInAddressBook", "SenderIsInAddressHistory", "SenderIsMemberOfVIPSenders",
        "SenderIsNotInAddressBook", "SenderIsNotInAddressHistory", "Account",
    ]
    static let textQualifiers: Set<String> = ["Contains", "DoesNotContain", "BeginsWith", "EndsWith", "IsEqualTo"]

    /// Why this rule cannot be applied as Mail would apply it, or nil.
    static func unsupported(_ rule: MailRule) -> String? {
        if rule.criteria.isEmpty { return "it has no conditions" }
        for criterion in rule.criteria {
            if criterion.field == "Compound" || !criterion.children.isEmpty { return "it has a compound condition" }
            if mailCriteria.contains(criterion.field), !supported.contains(criterion.field) {
                return "its \(criterion.field) condition is not supported here"
            }
            if !textQualifiers.contains(criterion.qualifier) { return "its \(criterion.qualifier) comparison is not supported here" }
        }
        let actions = rule.definition
        if actions.autoResponse != 0 { return "it sends mail (forward, redirect or reply); use Message › Apply Rules in Mail" }
        if actions.appleScript != nil { return "it runs an AppleScript; use Message › Apply Rules in Mail" }
        return nil
    }

    func evaluate(_ rule: MailRule, _ message: MessageSummary, mailbox: Mailbox?) throws -> Outcome {
        var unknown = false
        for criterion in rule.criteria {
            switch try evaluate(criterion, message, mailbox) {
            case .match: if !rule.allMustMatch { return .match }
            case .noMatch: if rule.allMustMatch { return .noMatch }
            case .unknown: unknown = true
            }
        }
        if unknown { return .unknown }
        return rule.allMustMatch ? .match : .noMatch
    }

    private static let addressHeaders: Set<String> = ["from", "to", "cc", "bcc", "reply-to", "sender", "resent-from", "resent-to", "resent-cc"]

    private func evaluate(_ criterion: MailCriterion, _ message: MessageSummary, _ mailbox: Mailbox?) throws -> Outcome {
        let sender = message.sender.address.lowercased()
        switch criterion.field {
        case "AnyMessage": return .match
        case "From": return Self.compare(addresses: [message.sender], criterion)
        case "AnyRecipient":
            let list = try recipientsOf(message)
            return Self.compare(addresses: list.to + list.cc, criterion)
        case "Account": return .of(accountMatches(criterion.value ?? "", message))
        case "IsJunkMail": return .of(mailbox?.role == .junk)
        case "NotInJunkMailbox": return .of(mailbox?.role != .junk)
        case "NotInTrashMailbox": return .of(mailbox?.role != .trash)
        case "ContainsAttachments", "AnyAttachment": return .of(message.hasAttachments)
        case "SenderIsMemberOfVIPSenders": return .of(vips.contains(sender))
        case "SenderIsInAddressBook": return .of(contacts[sender] ?? false)
        case "SenderIsNotInAddressBook": return .of(!(contacts[sender] ?? false))
        case "SenderIsInAddressHistory": return .of(try wroteTo(sender))
        case "SenderIsNotInAddressHistory": return .of(!(try wroteTo(sender)))
        case "Body":
            guard let detail = try detailOf(message), detail.bodyAvailable else { return .unknown }
            let text = detail.textBody ?? detail.htmlBody.map(HTMLText.plainText(fromHTML:)) ?? ""
            return Self.compare(texts: [text], criterion)
        default:
            // To, Cc, Subject and any other header, by name.
            switch criterion.field.lowercased() {
            case "to": return Self.compare(addresses: try recipientsOf(message).to, criterion)
            case "cc": return Self.compare(addresses: try recipientsOf(message).cc, criterion)
            case "subject": return Self.compare(texts: [message.subject], criterion)
            default: break
            }
            guard let detail = try detailOf(message) else { return .unknown }
            let values = detail.headers.filter { $0.name.caseInsensitiveCompare(criterion.field) == .orderedSame }.map(\.value)
            if Self.addressHeaders.contains(criterion.field.lowercased()) {
                return Self.compare(addresses: values.flatMap { MIME.parseAddressList($0) }, criterion)
            }
            return Self.compare(texts: values, criterion)
        }
    }

    /// Mail compares with `rangeOfString:options:` ignoring case; "does not contain" holds when no value contains it.
    static func compare(texts: [String], _ criterion: MailCriterion) -> Outcome {
        let expression = criterion.value ?? ""
        if criterion.qualifier == "DoesNotContain" { return .of(!texts.contains { satisfies($0, "Contains", expression) }) }
        return .of(texts.contains { satisfies($0, criterion.qualifier, expression) })
    }

    /// An address matches on the address itself or the display name (`rawAddressFromFullAddress:`, `displayNameFromAddress:`).
    static func compare(addresses: [EmailAddress], _ criterion: MailCriterion) -> Outcome {
        compare(texts: addresses.flatMap { [$0.address] + ($0.name.map { [$0] } ?? []) }, criterion)
    }

    static func satisfies(_ value: String, _ qualifier: String, _ expression: String) -> Bool {
        switch qualifier {
        case "BeginsWith": value.range(of: expression, options: [.caseInsensitive, .anchored]) != nil
        case "EndsWith": value.range(of: expression, options: [.caseInsensitive, .anchored, .backwards]) != nil
        case "IsEqualTo": value.compare(expression, options: .caseInsensitive) == .orderedSame
        default: value.range(of: expression, options: .caseInsensitive) != nil
        }
    }

    private func accountMatches(_ expression: String, _ message: MessageSummary) -> Bool {
        if let url = MailboxURL(expression) {
            let key = url.accountID.removingPercentEncoding ?? url.accountID
            return key == message.accountID
                || accounts.first { $0.id == message.accountID }?.emailAddresses.contains { $0.caseInsensitiveCompare(key) == .orderedSame } == true
        }
        return expression == message.accountID || expression.caseInsensitiveCompare(message.accountName) == .orderedSame
    }

    private func recipientsOf(_ message: MessageSummary) throws -> (to: [EmailAddress], cc: [EmailAddress]) {
        if let known = recipients[message.id] { return known }
        let found = try store.recipients(of: message.id)
        recipients[message.id] = found
        return found
    }

    private func detailOf(_ message: MessageSummary) throws -> MessageDetail? {
        if let known = details[message.id] { return known }
        let found = try? store.detail(id: message.id)
        details[message.id] = found
        return found
    }

    /// "Previous recipients": addresses the user has sent mail to.
    private func wroteTo(_ address: String) throws -> Bool {
        if let known = history[address] { return known }
        let found = try store.correspondents(matching: address, limit: 5).contains { $0.address.lowercased() == address && $0.sent > 0 }
        history[address] = found
        return found
    }
}

extension RuleEvaluator.Outcome {
    static func of(_ value: Bool) -> Self { value ? .match : .noMatch }
}
