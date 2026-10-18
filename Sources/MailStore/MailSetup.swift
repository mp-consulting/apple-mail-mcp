import Foundation

/// One condition of a Mail rule or smart mailbox: `From` `Contains` `alice@example.test`.
public struct MailCriterion: Sendable, Hashable {
    /// Mail's field name: `From`, `Subject`, `AnyRecipient`, `Body`, `NotInTrashMailbox`, `Compound`…
    public var field: String
    /// `Contains` when Mail leaves it out, else `IsEqualTo`, `BeginsWith`, `EndsWith`, `DoesNotContain`…
    public var qualifier: String
    public var value: String?
    /// For `Compound` criteria: the nested conditions.
    public var children: [MailCriterion]
    public var allMustMatch: Bool
}

/// A rule from Mail › Settings › Rules (read-only).
public struct MailRule: Sendable, Hashable {
    public var id: String
    public var name: String
    /// From `RulesActiveState.plist` when Mail keeps one; nil when unknown.
    public var enabled: Bool?
    public var allMustMatch: Bool
    public var criteria: [MailCriterion]
    /// What the rule does, e.g. `move to Archive`, `mark as read`, `stop evaluating rules`.
    public var actions: [String]
}

public struct SmartMailbox: Sendable, Hashable {
    public var id: String
    public var name: String
    public var allMustMatch: Bool
    public var criteria: [MailCriterion]
    /// Smart mailbox folders hold other smart mailboxes.
    public var children: [SmartMailbox]
}

/// A sender marked VIP in Mail (`VIPs.plist`: id → name and addresses).
public struct VIPSender: Sendable, Hashable {
    public var id: String
    public var name: String
    public var addresses: [String]
}

public struct MailSignature: Sendable, Hashable {
    public var id: String
    public var name: String
    public var isRich: Bool
    /// Plain text of the signature, when its file is on this Mac.
    public var text: String?
}

/// Reads Mail's rules, smart mailboxes and signatures from `~/Library/Mail/V10/MailData`. Never writes.
extension MailStore {
    var mailData: URL { location.root.appending(path: "MailData") }

    private func plist(_ name: String) -> Any? {
        guard let data = try? Data(contentsOf: mailData.appending(path: name)) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil)
    }

    /// Rules in Mail's order: synced (iCloud) rules, then rules kept on this Mac only.
    public func rules() -> [MailRule] {
        let active = plist("RulesActiveState.plist") as? [String: Bool]
        let all = (plist("SyncedRules.plist") as? [[String: Any]] ?? []) + (plist("UnsyncedRules.plist") as? [[String: Any]] ?? [])
        return all.compactMap { rule in
            guard let id = rule["RuleId"] as? String else { return nil }
            return MailRule(
                id: id, name: rule["RuleName"] as? String ?? "(unnamed)", enabled: active?[id],
                allMustMatch: rule["AllCriteriaMustBeSatisfied"] as? Bool ?? false,
                criteria: (rule["Criteria"] as? [[String: Any]] ?? []).map(Self.criterion), actions: ruleActions(rule))
        }
    }

    private func ruleActions(_ rule: [String: Any]) -> [String] {
        var actions: [String] = []
        func flag(_ key: String) -> Bool { rule[key] as? Bool ?? false }
        if flag("ShouldTransferMessage"), let url = rule["MailboxURL"] as? String { actions.append("move to \(mailboxName(url))") }
        if flag("ShouldCopyMessage"), let url = rule["CopyToMailboxURL"] as? String { actions.append("copy to \(mailboxName(url))") }
        if flag("MarkRead") { actions.append("mark as read") }
        if flag("MarkFlagged") { actions.append("flag") }
        if flag("Deletes") { actions.append("delete") }
        if flag("HighlightTextUsingColor") { actions.append("colour the message") }
        if flag("NotifyUser") || flag("SendNotification") { actions.append("notify") }
        if let response = rule["AutoResponseType"] as? Int, response != 0 { actions.append("reply, forward or redirect (type \(response))") }
        if flag("StopEvaluatingRules") { actions.append("stop evaluating rules") }
        return actions
    }

    /// `imap://<account>/Archive` → `Archive (iCloud)`.
    private func mailboxName(_ url: String) -> String {
        guard let parsed = MailboxURL(url) else { return url }
        let account = (try? accounts())?.first { $0.id == parsed.accountID }?.name
        return account.map { "\(parsed.path) (\($0))" } ?? parsed.path
    }

    static func criterion(_ raw: [String: Any]) -> MailCriterion {
        MailCriterion(
            field: raw["Header"] as? String ?? raw["Name"] as? String ?? "?",
            qualifier: raw["Qualifier"] as? String ?? "Contains",
            value: (raw["Expression"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            children: (raw["Criteria"] as? [[String: Any]] ?? []).map(criterion),
            allMustMatch: raw["AllCriteriaMustBeSatisfied"] as? Bool ?? false)
    }

    public func vips() -> [VIPSender] {
        let list = plist("VIPs.plist") as? [String: [String: Any]] ?? [:]
        return list.map { id, entry in
            VIPSender(id: id, name: entry["Name"] as? String ?? "", addresses: entry["EmailAddresses"] as? [String] ?? [])
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func smartMailboxes() -> [SmartMailbox] {
        func box(_ raw: [String: Any]) -> SmartMailbox? {
            guard let name = raw["MailboxName"] as? String else { return nil }
            return SmartMailbox(
                id: raw["MailboxID"] as? String ?? name, name: name,
                allMustMatch: raw["MailboxAllCriteriaMustBeSatisfied"] as? Bool ?? false,
                criteria: (raw["MailboxCriteria"] as? [[String: Any]] ?? []).map(Self.criterion),
                children: (raw["MailboxChildren"] as? [[String: Any]] ?? []).compactMap(box))
        }
        let all = (plist("SyncedSmartMailboxes.plist") as? [[String: Any]] ?? []) + (plist("SmartMailboxes.plist") as? [[String: Any]] ?? [])
        return all.compactMap(box)
    }

    /// Signatures in Mail's order, with their text when the signature file is on this Mac (iCloud keeps
    /// synced ones in its Mail container).
    public func signatures() -> [MailSignature] {
        let list = plist("Signatures/AllSignatures.plist") as? [[String: Any]] ?? []
        let folders = [
            mailData.appending(path: "Signatures"),
            location.root.deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "Mobile Documents/com~apple~mail/Data/V10/MailData/Signatures"),
        ]
        return list.compactMap { entry in
            guard let id = entry["SignatureUniqueId"] as? String else { return nil }
            let file = folders.flatMap { [$0.appending(path: "\(id).mailsignature"), $0.appending(path: "ubiquitous_\(id).mailsignature")] }
                .first { FileManager.default.fileExists(atPath: $0.path) }
            return MailSignature(
                id: id, name: entry["SignatureName"] as? String ?? "(unnamed)", isRich: entry["SignatureIsRich"] as? Bool ?? false,
                text: file.flatMap { try? Data(contentsOf: $0) }.flatMap(Self.signatureText))
        }
    }

    /// A `.mailsignature` file is a MIME entity (headers, then HTML).
    static func signatureText(_ data: Data) -> String? {
        let part = MIME.parse(data)
        let body = part.text()
        let text = part.contentType == "text/plain" ? body : HTMLText.plainText(fromHTML: body)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
