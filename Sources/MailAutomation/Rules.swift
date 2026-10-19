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

    /// The `Header` Mail saves for this condition (`-[MFMessageCriterion dictionaryRepresentation]`); a header
    /// condition saves the header's own name. "To or cc" saves as `AnyRecipient`, like "any recipient".
    public var savedName: String {
        switch self {
        case .from: "From"
        case .to: "To"
        case .cc: "Cc"
        case .toOrCc, .anyRecipient: "AnyRecipient"
        case .subject: "Subject"
        case .body: "Body"
        case .header: "Header"
        case .account: "Account"
        case .attachmentType: "AttachmentType"
        case .everyMessage: "AnyMessage"
        case .junk: "IsJunkMail"
        case .inContacts: "SenderIsInAddressBook"
        case .notInContacts: "SenderIsNotInAddressBook"
        case .inPreviousRecipients: "SenderIsInAddressHistory"
        case .notInPreviousRecipients: "SenderIsNotInAddressHistory"
        }
    }

    /// The field for a saved `Header`; nil for Mail condition types the tools do not make. Any other name is a
    /// message header (``RuleField/header``).
    public static func saved(_ name: String, mailTypes: Set<String>) -> (field: RuleField, header: String?)? {
        if name != "Header", let field = allCases.first(where: { $0.savedName == name && $0 != .toOrCc }) { return (field, nil) }
        return mailTypes.contains(name) || name == "Compound" ? nil : (.header, name)
    }

    /// Whether the condition compares text (and so needs a value).
    public var takesValue: Bool {
        switch self {
        case .everyMessage, .junk, .inContacts, .notInContacts, .inPreviousRecipients, .notInPreviousRecipients: false
        default: true
        }
    }
}

public enum RuleQualifier: String, Sendable, CaseIterable, Codable {
    case contains
    case notContains = "not_contains"
    case beginsWith = "begins_with"
    case endsWith = "ends_with"
    case equals

    /// The `Qualifier` Mail saves (none for contains).
    public var savedName: String {
        switch self {
        case .contains: "Contains"
        case .notContains: "DoesNotContain"
        case .beginsWith: "BeginsWith"
        case .endsWith: "EndsWith"
        case .equals: "IsEqualTo"
        }
    }

    public init?(savedName: String) {
        guard let match = Self.allCases.first(where: { $0.savedName == savedName }) else { return nil }
        self = match
    }

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
public struct RuleSpec: Sendable, Hashable, Codable {
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

/// What a rule update changes (see ``MailAutomation/updateRule(named:_:)``): nil and ``RuleChange/keep`` leave a part
/// as it is.
public struct RuleUpdate: Sendable, Hashable {
    public var name: String?
    public var enabled: Bool?
    public var allMustMatch: Bool?
    /// Replaces every condition.
    public var conditions: [RuleCondition]?
    public var moveTo: RuleChange<MailboxTarget> = .keep
    public var copyTo: RuleChange<MailboxTarget> = .keep
    public var markRead: Bool?
    public var flag: RuleChange<FlagColor> = .keep
    public var color: RuleChange<RuleColor> = .keep
    public var delete: Bool?
    public var forwardTo: RuleChange<[String]> = .keep
    public var redirectTo: RuleChange<[String]> = .keep
    public var replyText: RuleChange<String> = .keep
    public var stopEvaluating: Bool?

    public init() {}

    /// Whether the update makes the rule send mail out (forward, redirect or auto-reply).
    public var addsSending: Bool {
        if case .set = forwardTo { return true }
        if case .set = redirectTo { return true }
        if case .set = replyText { return true }
        return false
    }
}

public enum RuleChange<Value: Sendable & Hashable>: Sendable, Hashable {
    case keep
    case set(Value)
    case clear
}

/// Mail saves its rule list when a rule's property changes through its setters (`handleDidChangeIfNeeded`), which a
/// scripted `make` and every scripted `set` do, except `enabled` (`setIsActive:` only marks the rule changed) and
/// `delete` (`removeRuleAtIndex:`). The save copies the list as it is 1.5 s to a minute later. So every change here
/// ends by renaming the rule to a temporary name and back: two real changes, which save everything done before them,
/// whatever Mail's change flag says.
extension MailAutomation {
    public func createRule(_ rule: RuleSpec) async throws {
        try await run { mail in
            try Self.make(rule, mail)
            try Self.saveSoon(rule.name, mail)
        }
    }

    /// Turns a rule on or off, keeping it as it is (same id, conditions and actions).
    public func setRuleEnabled(named name: String, enabled: Bool) async throws {
        try await run { mail in
            try mail.set(MailSpec.property("isac", of: Self.rule(named: name)), to: NSAppleEventDescriptor(boolean: enabled))
            try Self.saveSoon(name, mail)
        }
    }

    /// Deletes a rule: renamed first (a real change, which starts Mail's save), then deleted at once, so the save
    /// writes the list without it.
    public func deleteRule(named name: String) async throws {
        try await run { mail in
            let temporary = Self.temporaryName(name)
            try mail.set(MailSpec.property("pnam", of: Self.rule(named: name)), to: NSAppleEventDescriptor(string: temporary))
            try mail.send("core", "delo", direct: Self.rule(named: temporary))
        }
    }

    /// Replaces a rule with `spec` (for changes scripting cannot make in place, such as fewer conditions): the new
    /// rule is made in full under a temporary name, then the old one is deleted and the new one takes `spec.name`. A
    /// new rule that fails half-way is deleted again and the old one stays.
    public func replaceRule(named name: String, with spec: RuleSpec) async throws {
        try await run { mail in
            var draft = spec
            draft.name = Self.temporaryName(spec.name)
            do {
                try Self.make(draft, mail)
            } catch {
                _ = try? mail.send("core", "delo", direct: Self.rule(named: draft.name))
                throw error
            }
            let old = Self.temporaryName(name)
            try mail.set(MailSpec.property("pnam", of: Self.rule(named: name)), to: NSAppleEventDescriptor(string: old))
            try mail.send("core", "delo", direct: Self.rule(named: old))
            try mail.set(MailSpec.property("pnam", of: Self.rule(named: draft.name)), to: NSAppleEventDescriptor(string: spec.name))
            try Self.saveSoon(spec.name, mail)
        }
    }

    /// Changes a rule's name, conditions or actions in place.
    public func updateRule(named name: String, _ update: RuleUpdate) async throws {
        try await run { mail in
            let rule = Self.rule(named: name)
            func set(_ code: String, _ value: NSAppleEventDescriptor) throws { try mail.set(MailSpec.property(code, of: rule), to: value) }
            func set(_ code: String, _ value: Bool?) throws { if let value { try set(code, NSAppleEventDescriptor(boolean: value)) } }
            if let conditions = update.conditions {
                // Never `delete` a rule condition: `-[MFMessageRule(Applescript) removeFromCriteriaAtIndex:]` calls itself
                // until Mail runs out of stack and crashes. Existing conditions are rewritten in place, extra ones added;
                // fewer conditions need ``replaceRule(named:with:)``.
                let existing = Int(try mail.send("core", "cnte", direct: rule, ["kocl": NSAppleEventDescriptor(typeCode: fourCC("rucr"))]).int32Value)
                guard conditions.count >= existing else {
                    throw AppleEventError(number: -1, message: "\(name) has \(existing) conditions; scripting cannot remove one (Mail crashes)")
                }
                for (index, condition) in conditions.enumerated() {
                    if index < existing { try Self.rewrite(index + 1, of: rule, to: condition, mail) } else { try Self.add(condition, to: rule, mail) }
                }
            }
            try set("racm", update.allMustMatch)
            try set("rmre", update.markRead)
            try set("rdme", update.delete)
            try set("rser", update.stopEvaluating)
            switch update.moveTo {
            case .keep: break
            case .set(let target): try set("rtme", MailSpec.mailbox(target)); try set("rstm", true)
            case .clear: try set("rstm", false)
            }
            switch update.copyTo {
            case .keep: break
            case .set(let target): try set("rcmb", MailSpec.mailbox(target)); try set("rscm", true)
            case .clear: try set("rscm", false)
            }
            switch update.flag {
            case .keep: break
            case .set(let flag): try set("rmfl", true); try set("rfcl", NSAppleEventDescriptor(int32: Int32(flag.rawValue)))
            case .clear: try set("rmfl", false)
            }
            switch update.color {
            case .keep: break
            case .set(let color): try set("rcme", NSAppleEventDescriptor(enumCode: fourCC(color.code))); try set("htuc", false)
            case .clear: try set("rcme", NSAppleEventDescriptor(enumCode: fourCC("ccno")))
            }
            for (code, change) in [("rfad", update.forwardTo), ("rrad", update.redirectTo)] {
                switch change {
                case .keep: break
                case .set(let addresses): try set(code, NSAppleEventDescriptor(string: addresses.joined(separator: ",")))
                case .clear: try set(code, NSAppleEventDescriptor(string: ""))
                }
            }
            switch update.replyText {
            case .keep: break
            case .set(let text): try set("rrte", NSAppleEventDescriptor(string: text))
            case .clear: try set("rrte", NSAppleEventDescriptor(string: ""))
            }
            try set("isac", update.enabled)
            var current = name
            if let newName = update.name, newName != name {
                try set("pnam", NSAppleEventDescriptor(string: newName))
                current = newName
            }
            try Self.saveSoon(current, mail)
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
        for condition in spec.conditions { try add(condition, to: rule, mail) }
        if let target = spec.moveTo {
            try mail.set(MailSpec.property("rtme", of: rule), to: MailSpec.mailbox(target))
            try mail.set(MailSpec.property("rstm", of: rule), to: NSAppleEventDescriptor(boolean: true))
        }
        if let target = spec.copyTo {
            try mail.set(MailSpec.property("rcmb", of: rule), to: MailSpec.mailbox(target))
            try mail.set(MailSpec.property("rscm", of: rule), to: NSAppleEventDescriptor(boolean: true))
        }
        // `make` leaves new rules disabled (`insertInRules:atIndex:` sets it); `saveSoon` follows and saves this too.
        if spec.enabled { try mail.set(MailSpec.property("isac", of: rule), to: NSAppleEventDescriptor(boolean: true)) }
    }

    private static func add(_ condition: RuleCondition, to rule: NSAppleEventDescriptor, _ mail: MailEventSender) throws {
        var fields: [String: NSAppleEventDescriptor] = [
            "rtyp": NSAppleEventDescriptor(enumCode: fourCC(condition.field.code)),
            "rqua": NSAppleEventDescriptor(enumCode: fourCC(condition.field.takesValue ? condition.qualifier.code : "rqno")),
        ]
        if condition.field.takesValue { fields["rexp"] = NSAppleEventDescriptor(string: condition.value) }
        if let header = condition.header { fields["rhed"] = NSAppleEventDescriptor(string: header) }
        _ = try mail.make("rucr", at: MailSpec.insertion("end ", of: MailSpec.every("rucr", of: rule)), properties: fields)
    }

    private static func rewrite(_ index: Int, of rule: NSAppleEventDescriptor, to condition: RuleCondition, _ mail: MailEventSender) throws {
        let criterion = MailSpec.object(want: "rucr", form: "indx", seld: NSAppleEventDescriptor(int32: Int32(index)), from: rule)
        func set(_ code: String, _ value: NSAppleEventDescriptor) throws { try mail.set(MailSpec.property(code, of: criterion), to: value) }
        try set("rtyp", NSAppleEventDescriptor(enumCode: fourCC(condition.field.code)))
        if let header = condition.header { try set("rhed", NSAppleEventDescriptor(string: header)) }
        try set("rqua", NSAppleEventDescriptor(enumCode: fourCC(condition.field.takesValue ? condition.qualifier.code : "rqno")))
        if condition.field.takesValue { try set("rexp", NSAppleEventDescriptor(string: condition.value)) }
    }

    /// Renames the rule to a temporary name and back: two real changes, so Mail saves its list (with everything
    /// changed before) whatever its change flag says.
    private static func saveSoon(_ name: String, _ mail: MailEventSender) throws {
        let temporary = temporaryName(name)
        try mail.set(MailSpec.property("pnam", of: rule(named: name)), to: NSAppleEventDescriptor(string: temporary))
        try mail.set(MailSpec.property("pnam", of: rule(named: temporary)), to: NSAppleEventDescriptor(string: name))
    }

    static func temporaryName(_ name: String) -> String { "\(name) (apple-mail-mcp \(UUID().uuidString.prefix(8)))" }
}

extension String {
    init(fourCharCode code: FourCharCode) {
        self = String(bytes: withUnsafeBytes(of: code.bigEndian) { Array($0) }, encoding: .macOSRoman) ?? "????"
    }
}
