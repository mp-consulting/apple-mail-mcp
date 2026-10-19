import AppKit
import Foundation
import MailStore

/// What a rule condition looks at (Mail's `RuleType`).
public enum RuleField: String, Sendable, CaseIterable, Codable {
    case from, to, cc
    case toOrCc = "to_or_cc"
    case anyRecipient = "any_recipient"
    case subject, body
    /// Any header, named by ``RuleCondition/header``.
    case header, account
    case attachmentType = "attachment_type"
    case everyMessage = "every_message"
    case junk
    case inContacts = "in_contacts"
    case notInContacts = "not_in_contacts"
    case inPreviousRecipients = "in_previous_recipients"
    case notInPreviousRecipients = "not_in_previous_recipients"

    var code: String {
        switch self {
        case .from: "tfro"
        case .to: "ttoo"
        case .cc: "tccc"
        case .toOrCc: "ttoc"
        case .anyRecipient: "tanr"
        case .subject: "tsub"
        case .body: "tmec"
        case .header: "thdk"
        case .account: "tacc"
        case .attachmentType: "tatt"
        case .everyMessage: "tevm"
        case .junk: "tmij"
        case .inContacts: "tsii"
        case .notInContacts: "tsin"
        case .inPreviousRecipients: "tsah"
        case .notInPreviousRecipients: "tnah"
        }
    }

    /// Whether the condition compares text (and so needs a value).
    public var takesValue: Bool {
        switch self {
        case .everyMessage, .junk, .inContacts, .notInContacts, .inPreviousRecipients, .notInPreviousRecipients: false
        default: true
        }
    }

    /// Every condition type Mail's dictionary lists, ours or not ("sender is VIP" and the group ones share codes),
    /// so a rule whose conditions all have one of these can be copied condition by condition.
    static let scriptableCodes: Set<FourCharCode> = Set(
        ["tacc", "tanr", "tccc", "tevm", "tfro", "thdk", "tmec", "tmij", "tsii", "tsah", "tsim", "tsin", "tnah", "tsig",
         "tsub", "ttoo", "ttoc", "tatt"].map(fourCC))
}

public enum RuleQualifier: String, Sendable, CaseIterable, Codable {
    case contains
    case notContains = "not_contains"
    case beginsWith = "begins_with"
    case endsWith = "ends_with"
    case equals

    var code: String {
        switch self {
        case .contains: "rqco"
        case .notContains: "rqdn"
        case .beginsWith: "rqbw"
        case .endsWith: "rqew"
        case .equals: "rqie"
        }
    }
}

/// The colour a rule gives matching messages in the message list (Mail's `HighlightColors`).
public enum RuleColor: String, Sendable, CaseIterable, Codable {
    case red, orange, yellow, green, blue, purple, gray

    var code: String {
        switch self {
        case .red: "ccre"
        case .orange: "ccor"
        case .yellow: "ccye"
        case .green: "ccgr"
        case .blue: "ccbl"
        case .purple: "ccpu"
        case .gray: "ccgy"
        }
    }
}

public struct RuleCondition: Sendable, Hashable, Codable {
    public var field: RuleField
    public var qualifier: RuleQualifier
    public var value: String
    /// The header name for ``RuleField/header``, e.g. `List-Id`.
    public var header: String?

    public init(field: RuleField, qualifier: RuleQualifier = .contains, value: String = "", header: String? = nil) {
        self.field = field
        self.qualifier = qualifier
        self.value = value
        self.header = header
    }
}

/// A new Mail rule: its conditions and what it does to matching messages.
public struct RuleSpec: Sendable, Hashable {
    public var name: String
    public var enabled: Bool
    public var allMustMatch: Bool
    public var conditions: [RuleCondition]
    public var moveTo: MailboxTarget?
    public var copyTo: MailboxTarget?
    public var markRead: Bool
    public var flag: FlagColor?
    public var color: RuleColor?
    public var delete: Bool
    public var forwardTo: [String]
    public var redirectTo: [String]
    public var replyText: String?
    public var stopEvaluating: Bool

    public init(
        name: String, enabled: Bool = true, allMustMatch: Bool = true, conditions: [RuleCondition], moveTo: MailboxTarget? = nil,
        copyTo: MailboxTarget? = nil, markRead: Bool = false, flag: FlagColor? = nil, color: RuleColor? = nil, delete: Bool = false,
        forwardTo: [String] = [], redirectTo: [String] = [], replyText: String? = nil, stopEvaluating: Bool = false
    ) {
        self.name = name
        self.enabled = enabled
        self.allMustMatch = allMustMatch
        self.conditions = conditions
        self.moveTo = moveTo
        self.copyTo = copyTo
        self.markRead = markRead
        self.flag = flag
        self.color = color
        self.delete = delete
        self.forwardTo = forwardTo
        self.redirectTo = redirectTo
        self.replyText = replyText
        self.stopEvaluating = stopEvaluating
    }

    /// Whether the rule sends mail out of the account (forward, redirect or auto-reply).
    public var sendsMail: Bool { !forwardTo.isEmpty || !redirectTo.isEmpty || replyText != nil }
}

/// A rule Mail has that scripting cannot copy faithfully, so it is left alone.
public struct RuleCopyError: Error, CustomStringConvertible, Sendable {
    public var description: String
}

/// Mail saves its rule list only after a `make` (a scripted `set` or `delete` changes its memory alone), and the
/// save copies the list as it is when it runs, 1.5 s to about a minute later. So every rule change here includes a
/// `make`, and the changes around it (such as `enabled`, which `make` ignores) go in with it.
extension MailAutomation {
    public func createRule(_ rule: RuleSpec) async throws {
        try await run { mail in try Self.make(rule, mail) }
    }

    /// Turns a rule on or off. A scripted `set` alone is never saved, so the rule is made again with the same
    /// properties and conditions: the copy is built in full under a temporary name, and only then does it replace
    /// the original, so a copy that fails leaves the original alone. `expectedConditions` (from the saved rule)
    /// guards against a copy that would lose some.
    public func setRuleEnabled(named name: String, enabled: Bool, expectedConditions: Int) async throws {
        try await run { mail in
            let rule = Self.rule(named: name)
            let properties = try Self.fields(of: mail.get(MailSpec.property("pALL", of: rule)))
            let conditions = Self.items(try mail.get(MailSpec.property("pALL", of: MailSpec.every("rucr", of: rule))))
                .map(Self.fields)
            guard conditions.count == expectedConditions else {
                throw RuleCopyError(description: "Mail shows \(conditions.count) conditions for \"\(name)\" but its saved rule has \(expectedConditions)")
            }
            for condition in conditions {
                guard let type = condition["rtyp"]?.enumCodeValue, RuleField.scriptableCodes.contains(type) else {
                    throw RuleCopyError(description: "\"\(name)\" has a condition scripting cannot copy")
                }
            }
            // `make` cannot take object references (the move and copy mailboxes): those are set afterwards, and the
            // switches they turn on are set back to the original's.
            let isReference = { (value: NSAppleEventDescriptor) in value.descriptorType == fourCC("obj ") }
            let temporary = "\(name) (apple-mail-mcp \(UUID().uuidString.prefix(8)))"
            var plain = properties.filter { $0.key != "isac" && !isReference($0.value) }
            plain["pnam"] = NSAppleEventDescriptor(string: temporary)
            _ = try mail.make("rule", at: MailSpec.insertion("end ", of: MailSpec.every("rule", of: nil)), properties: plain)
            let copy = Self.rule(named: temporary)
            do {
                for (key, value) in properties where isReference(value) {
                    try mail.set(MailSpec.property(key, of: copy), to: value)
                }
                for key in ["rstm", "rscm"] {
                    if let value = properties[key] { try mail.set(MailSpec.property(key, of: copy), to: value) }
                }
                for condition in conditions {
                    _ = try mail.make("rucr", at: MailSpec.insertion("end ", of: MailSpec.every("rucr", of: copy)), properties: condition)
                }
            } catch {
                _ = try? mail.send("core", "delo", direct: copy)
                throw error
            }
            // The copy is complete: it takes the original's place.
            try mail.send("core", "delo", direct: rule)
            try mail.set(MailSpec.property("pnam", of: copy), to: NSAppleEventDescriptor(string: name))
            if enabled { try mail.set(MailSpec.property("isac", of: rule), to: NSAppleEventDescriptor(boolean: true)) }
        }
    }

    /// Names of the rules Mail has now, saved or not.
    public func ruleNames() async throws -> [String] {
        try await run { mail in
            AEValue(try mail.get(MailSpec.property("pnam", of: MailSpec.every("rule", of: nil)))).list.compactMap(\.string)
        }
    }

    /// When the running Mail started; a rule change older than that and not saved is gone.
    public static func mailLaunchDate() -> Date? {
        NSRunningApplication.runningApplications(withBundleIdentifier: MailEventSender.bundleIdentifier).compactMap(\.launchDate).max()
    }

    static func rule(named name: String) -> NSAppleEventDescriptor {
        MailSpec.object(want: "rule", form: "name", seld: NSAppleEventDescriptor(string: name), from: nil)
    }

    private static func make(_ spec: RuleSpec, _ mail: MailEventSender) throws {
        var properties: [String: NSAppleEventDescriptor] = [
            "pnam": NSAppleEventDescriptor(string: spec.name),
            "racm": NSAppleEventDescriptor(boolean: spec.allMustMatch),
            "rser": NSAppleEventDescriptor(boolean: spec.stopEvaluating),
            "rmre": NSAppleEventDescriptor(boolean: spec.markRead),
            "rdme": NSAppleEventDescriptor(boolean: spec.delete),
        ]
        if let flag = spec.flag {
            properties["rmfl"] = NSAppleEventDescriptor(boolean: true)
            properties["rfcl"] = NSAppleEventDescriptor(int32: Int32(flag.rawValue))
        }
        if let color = spec.color {
            properties["rcme"] = NSAppleEventDescriptor(enumCode: fourCC(color.code))
            properties["htuc"] = NSAppleEventDescriptor(boolean: false)
        }
        if !spec.forwardTo.isEmpty { properties["rfad"] = NSAppleEventDescriptor(string: spec.forwardTo.joined(separator: ",")) }
        if !spec.redirectTo.isEmpty { properties["rrad"] = NSAppleEventDescriptor(string: spec.redirectTo.joined(separator: ",")) }
        if let reply = spec.replyText { properties["rrte"] = NSAppleEventDescriptor(string: reply) }
        // New rules start disabled whatever `make` is told; conditions and the rest follow at once, inside the
        // window before Mail's save copies the list.
        _ = try mail.make("rule", at: MailSpec.insertion("end ", of: MailSpec.every("rule", of: nil)), properties: properties)
        let rule = rule(named: spec.name)
        for condition in spec.conditions {
            var fields: [String: NSAppleEventDescriptor] = [
                "rtyp": NSAppleEventDescriptor(enumCode: fourCC(condition.field.code)),
                "rqua": NSAppleEventDescriptor(enumCode: fourCC(condition.field.takesValue ? condition.qualifier.code : "rqno")),
            ]
            if condition.field.takesValue { fields["rexp"] = NSAppleEventDescriptor(string: condition.value) }
            if let header = condition.header { fields["rhed"] = NSAppleEventDescriptor(string: header) }
            _ = try mail.make("rucr", at: MailSpec.insertion("end ", of: MailSpec.every("rucr", of: rule)), properties: fields)
        }
        if let target = spec.moveTo {
            try mail.set(MailSpec.property("rtme", of: rule), to: MailSpec.mailbox(target))
            try mail.set(MailSpec.property("rstm", of: rule), to: NSAppleEventDescriptor(boolean: true))
        }
        if let target = spec.copyTo {
            try mail.set(MailSpec.property("rcmb", of: rule), to: MailSpec.mailbox(target))
            try mail.set(MailSpec.property("rscm", of: rule), to: NSAppleEventDescriptor(boolean: true))
        }
        if spec.enabled { try mail.set(MailSpec.property("isac", of: rule), to: NSAppleEventDescriptor(boolean: true)) }
    }

    static func items(_ list: NSAppleEventDescriptor) -> [NSAppleEventDescriptor] {
        guard list.descriptorType == fourCC("list") else { return list.descriptorType == fourCC("null") ? [] : [list] }
        return (0..<list.numberOfItems).compactMap { list.atIndex($0 + 1) }
    }

    /// The keyword → value pairs of a `properties` record, ready to `make` again: without `class`, `missing value`
    /// (Mail cannot take one back) and empty text (the default, which Mail refuses to set: forward, redirect and
    /// reply addresses and texts).
    static func fields(of record: NSAppleEventDescriptor) -> [String: NSAppleEventDescriptor] {
        guard record.numberOfItems > 0 else { return [:] }
        var fields: [String: NSAppleEventDescriptor] = [:]
        for index in 1...record.numberOfItems {
            let keyword = record.keywordForDescriptor(at: index)
            guard let value = record.atIndex(index), keyword != fourCC("pcls") else { continue }
            let missing = value.descriptorType == fourCC("null") || value.descriptorType == fourCC("msng")
                || (value.descriptorType == fourCC("type") && value.typeCodeValue == fourCC("msng"))
            let emptyText = value.descriptorType == fourCC("utxt") && value.stringValue?.isEmpty == true
            guard !missing, !emptyText else { continue }
            fields[String(fourCharCode: keyword)] = value
        }
        return fields
    }
}

extension String {
    init(fourCharCode code: FourCharCode) {
        self = String(bytes: withUnsafeBytes(of: code.bigEndian) { Array($0) }, encoding: .macOSRoman) ?? "????"
    }
}
