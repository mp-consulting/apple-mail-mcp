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

/// A rule from Mail › Settings › Rules.
public struct MailRule: Sendable, Hashable {
    public var id: String
    public var name: String
    /// From `RulesActiveState.plist` when Mail keeps one; nil when unknown.
    public var enabled: Bool?
    public var allMustMatch: Bool
    public var criteria: [MailCriterion]
    /// What the rule does, e.g. `move to Archive`, `mark as read`, `stop evaluating rules`.
    public var actions: [String]
    /// The same actions as Mail saves them, for applying the rule.
    public var definition: MailRuleActions = MailRuleActions()
}

/// A rule's actions, from the keys Mail saves (`-[MFMessageRule dictionaryRepresentation]`).
public struct MailRuleActions: Sendable, Hashable {
    /// `MailboxURL` when `ShouldTransferMessage`.
    public var moveTo: String?
    /// `CopyToMailboxURL` when `ShouldCopyMessage`.
    public var copyTo: String?
    public var markRead = false
    /// `FlagColor` (red 0 … gray 6) when `MarkFlagged`.
    public var flag: Int?
    /// `Color`, an RGB value (see ``MailRuleActions/colorNames``); `HighlightTextUsingColor` colours the text instead.
    public var color: Int?
    public var colorsText = false
    public var deletes = false
    public var stopEvaluating = false
    /// `AutoResponseType`: 1 forward, 2 reply, 3 redirect (with `ForwardRecipients`, `RedirectRecipients` and
    /// `ResponseMessage`).
    public var autoResponse = 0
    public var forwardTo: [String] = []
    public var redirectTo: [String] = []
    public var responseText: String?
    /// `NotifyUser` or `SendNotification`.
    public var notifies = false
    public var sound: String?
    public var appleScript: String?

    public init() {}

    /// The RGB values Mail saves for its rule colours.
    public static let colorNames: [Int: String] = [
        0xFF9892: "red", 0xFFCA8B: "orange", 0xFFF19B: "yellow", 0xC9F4A9: "green", 0x9BC9FF: "blue", 0xD7B4E5: "purple",
        0xC7D0DB: "gray",
    ]
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
                criteria: (rule["Criteria"] as? [[String: Any]] ?? []).map(Self.criterion), actions: ruleActions(rule),
                definition: Self.ruleDefinition(rule))
        }
    }

    /// When Mail last wrote each rule file. A rule change shows in `UnsyncedRules.plist` and `RulesActiveState.plist`
    /// at once; `SyncedRules.plist`, which holds the definitions, waits until Mail has its iCloud Drive copy.
    public func ruleFileDates() -> [String: Date] {
        var dates: [String: Date] = [:]
        for name in Self.ruleFiles {
            let path = mailData.appending(path: name).path
            if let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date { dates[name] = date }
        }
        return dates
    }

    public static let ruleFiles = ["SyncedRules.plist", "UnsyncedRules.plist", "RulesActiveState.plist"]

    static func ruleDefinition(_ rule: [String: Any]) -> MailRuleActions {
        func flag(_ key: String) -> Bool { rule[key] as? Bool ?? false }
        var actions = MailRuleActions()
        if flag("ShouldTransferMessage") { actions.moveTo = rule["MailboxURL"] as? String }
        if flag("ShouldCopyMessage") { actions.copyTo = rule["CopyToMailboxURL"] as? String }
        actions.markRead = flag("MarkRead")
        if flag("MarkFlagged") { actions.flag = rule["FlagColor"] as? Int ?? 0 }
        actions.color = rule["Color"] as? Int
        actions.colorsText = flag("HighlightTextUsingColor")
        actions.deletes = flag("Deletes")
        actions.stopEvaluating = flag("StopEvaluatingRules")
        actions.autoResponse = rule["AutoResponseType"] as? Int ?? 0
        actions.forwardTo = rule["ForwardRecipients"] as? [String] ?? []
        actions.redirectTo = rule["RedirectRecipients"] as? [String] ?? []
        actions.responseText = (rule["ResponseMessage"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        actions.notifies = flag("NotifyUser") || flag("SendNotification")
        actions.sound = (rule["SoundName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        actions.appleScript = (rule["AppleScript"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return actions
    }

    private func ruleActions(_ rule: [String: Any]) -> [String] {
        let definition = Self.ruleDefinition(rule)
        var actions: [String] = []
        if let url = definition.moveTo { actions.append("move to \(mailboxName(url))") }
        if let url = definition.copyTo { actions.append("copy to \(mailboxName(url))") }
        if definition.markRead { actions.append("mark as read") }
        if let index = definition.flag { actions.append(FlagColor(rawValue: index).map { "flag \($0.name)" } ?? "flag") }
        if let color = definition.color {
            let name = MailRuleActions.colorNames[color] ?? "a colour"
            actions.append(definition.colorsText ? "colour the text \(name)" : "colour \(name)")
        }
        if definition.deletes { actions.append("delete") }
        switch definition.autoResponse {
        case 0: break
        case 1: actions.append("forward to \(definition.forwardTo.joined(separator: ", "))")
        case 2: actions.append("reply")
        case 3: actions.append("redirect to \(definition.redirectTo.joined(separator: ", "))")
        default: actions.append("respond (type \(definition.autoResponse))")
        }
        if definition.notifies { actions.append("notify") }
        if definition.sound != nil { actions.append("play a sound") }
        if definition.appleScript != nil { actions.append("run an AppleScript") }
        if definition.stopEvaluating { actions.append("stop evaluating rules") }
        return actions
    }

    /// `imap://<account>/Archive` → `Archive (iCloud)`.
    private func mailboxName(_ url: String) -> String {
        guard let parsed = MailboxURL(url) else { return url }
        let account = (try? ruleAccount(parsed))?.name
        return account.map { "\(parsed.path) (\($0))" } ?? parsed.path
    }

    /// The account a rule's mailbox URL names: by id, or by the user name Mail writes there (`me%40icloud.com`).
    private func ruleAccount(_ url: MailboxURL) throws -> MailAccount? {
        let key = url.accountID.removingPercentEncoding ?? url.accountID
        let all = try accounts()
        return all.first { $0.id == key }
            ?? all.first { $0.emailAddresses.contains { $0.caseInsensitiveCompare(key) == .orderedSame } }
    }

    /// The mailbox a rule's `MailboxURL` or `CopyToMailboxURL` names, when exactly one matches.
    public func mailbox(ruleURL: String) throws -> Mailbox? {
        guard let url = MailboxURL(ruleURL) else { return nil }
        let candidates = try mailboxes(accountID: try ruleAccount(url)?.id).filter { $0.path == url.path }
        return candidates.count == 1 ? candidates[0] : nil
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

    /// Signatures kept on this Mac, then those synced with iCloud (listed in iCloud's Mail container), with
    /// their text when the signature file is there.
    public func signatures() -> [MailSignature] {
        let local = mailData.appending(path: "Signatures")
        let cloud = location.root.deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Mobile Documents/com~apple~mail/Data/MailData/Signatures")
        func list(_ url: URL) -> [[String: Any]] {
            guard let data = try? Data(contentsOf: url) else { return [] }
            return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [[String: Any]] ?? []
        }
        var seen = Set<String>()
        let entries = (list(local.appending(path: "AllSignatures.plist")) + list(cloud.appending(path: "ubiquitous_AllSignatures.plist")))
        return entries.compactMap { entry in
            guard let id = entry["SignatureUniqueId"] as? String, seen.insert(id).inserted else { return nil }
            let file = [local.appending(path: "\(id).mailsignature"), cloud.appending(path: "ubiquitous_\(id).mailsignature")]
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
