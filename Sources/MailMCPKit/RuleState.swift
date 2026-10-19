import Foundation
import MailAutomation
import MailStore

/// A rule change Mail had not saved when its tool returned. Kept in `pending-rules.json` so every server process,
/// and the next session, can tell whether Mail saved it or lost it.
struct PendingRule: Sendable, Hashable, Codable {
    enum Expectation: Sendable, Hashable, Codable {
        /// One rule by that name, as `spec` describes it; when the rule cannot be described (it has actions the
        /// tools do not make), only on or off and the number of conditions are checked.
        case present(spec: RuleSpec?, enabled: Bool, conditions: Int)
        /// No rule by that name.
        case absent
    }

    var name: String
    var expectation: Expectation
    var requested: Date
}

/// Pending rule changes, shared by all server processes. Owner-only.
public final class PendingRuleStore: @unchecked Sendable {
    private let file: SharedJSONFile<[PendingRule]>

    public init(url: URL = SharedPaths.supportDirectory.appending(path: "pending-rules.json")) {
        file = SharedJSONFile(url: url, empty: [])
    }

    var all: [PendingRule] { file.value }

    /// Replaces any entry for the same rule; nil just removes it.
    func set(_ name: String, _ entry: PendingRule?) {
        try? file.modify { list in
            list.removeAll { $0.name == name }
            if let entry { list.append(entry) }
        }
    }

    func replaceAll(_ entries: [PendingRule]) { try? file.modify { $0 = entries } }
}

/// How far Mail got with saving a rule change.
enum RuleSave: Hashable {
    /// The rule is in Mail's files as asked.
    case saved
    /// Mail saved the rule, but not as asked: what differs.
    case differs([String])
    /// Mail saved locally; the definition waits for iCloud Drive. Quitting Mail now loses the change.
    case pendingICloud
    /// Mail has the change but wrote nothing yet (its save can take a minute).
    case saving

    var isSaved: Bool { self == .saved }
    var pending: String? {
        switch self {
        case .pendingICloud: "pending_icloud"
        case .saving: "saving"
        default: nil
        }
    }
    var differences: [String]? {
        if case .differs(let list) = self { return list }
        return nil
    }
}

extension MailToolbox {
    /// A saved rule as the spec that would make it again, or why it cannot be made again by the tools.
    func spec(of rule: MailRule) -> (spec: RuleSpec?, reason: String?) {
        var conditions: [RuleCondition] = []
        for criterion in rule.criteria {
            guard criterion.children.isEmpty, let (field, header) = RuleField.saved(criterion.field, mailTypes: RuleEvaluator.mailCriteria) else {
                return (nil, "its \(criterion.field) condition")
            }
            guard let qualifier = RuleQualifier(savedName: criterion.qualifier) else { return (nil, "its \(criterion.qualifier) comparison") }
            conditions.append(RuleCondition(
                field: field, qualifier: field.takesValue ? qualifier : .contains, value: field.takesValue ? criterion.value ?? "" : "",
                header: header))
        }
        let saved = rule.definition
        if saved.notifies { return (nil, "its notification") }
        if saved.sound != nil { return (nil, "its sound") }
        if saved.appleScript != nil { return (nil, "its AppleScript") }
        if saved.colorsText { return (nil, "its text colour") }
        if let rgb = saved.color, MailRuleActions.colorNames[rgb] == nil { return (nil, "its custom colour") }
        if saved.autoResponse == 1, saved.responseText != nil { return (nil, "its forward text") }
        if ![0, 1, 2, 3].contains(saved.autoResponse) { return (nil, "its response type \(saved.autoResponse)") }
        func target(_ url: String?) -> MailboxTarget?? {
            guard let url else { return .some(nil) }
            return (try? store.mailbox(ruleURL: url)).flatMap { $0 }.map { .some(MailboxTarget($0)) } ?? nil
        }
        guard let move = target(saved.moveTo) else { return (nil, "its move mailbox, which no longer exists") }
        guard let copy = target(saved.copyTo) else { return (nil, "its copy mailbox, which no longer exists") }
        return (RuleSpec(
            name: rule.name, enabled: rule.enabled ?? false, allMustMatch: rule.allMustMatch, conditions: conditions, moveTo: move,
            copyTo: copy, markRead: saved.markRead, flag: saved.flag.flatMap(FlagColor.init(rawValue:)),
            color: saved.color.flatMap { MailRuleActions.colorNames[$0] }.flatMap(RuleColor.init(rawValue:)), delete: saved.deletes,
            forwardTo: saved.autoResponse == 1 ? saved.forwardTo : [], redirectTo: saved.autoResponse == 3 ? saved.redirectTo : [],
            replyText: saved.autoResponse == 2 ? saved.responseText : nil, stopEvaluating: saved.stopEvaluating), nil)
    }

    /// What differs between the rule as asked and as Mail saved it, in words; empty when they agree.
    func differences(_ expected: RuleSpec, _ saved: MailRule) -> [String] {
        guard let actual = spec(of: saved).spec else { return ["the saved rule has \(spec(of: saved).reason ?? "parts the tools do not make")"] }
        var out: [String] = []
        func check<T: Equatable>(_ label: String, _ want: T, _ got: T, _ show: (T) -> String = { "\($0)" }) {
            if want != got { out.append("\(label): asked \(show(want)), saved \(show(got))") }
        }
        func normalized(_ conditions: [RuleCondition]) -> [RuleCondition] {
            conditions.map { condition in
                var copy = condition
                if copy.field == .toOrCc { copy.field = .anyRecipient }
                if !copy.field.takesValue { copy.qualifier = .contains; copy.value = "" }
                if copy.field != .header { copy.header = nil }
                if copy.field == .account { copy.value = "" }  // Mail may store the account in its own form
                return copy
            }
        }
        func describe(_ conditions: [RuleCondition]) -> String {
            conditions.map { "\($0.field == .header ? $0.header ?? "header" : $0.field.rawValue) \($0.qualifier.rawValue) \"\($0.value)\"" }
                .joined(separator: "; ")
        }
        func mailbox(_ target: MailboxTarget?) -> String { target?.path ?? "none" }
        check("name", expected.name, actual.name)
        check("enabled", expected.enabled, actual.enabled)
        check("match", expected.allMustMatch ? "all" : "any", actual.allMustMatch ? "all" : "any")
        check("conditions", normalized(expected.conditions), normalized(actual.conditions), describe)
        check("move_to", expected.moveTo, actual.moveTo, mailbox)
        check("copy_to", expected.copyTo, actual.copyTo, mailbox)
        check("mark_read", expected.markRead, actual.markRead)
        check("flag_color", expected.flag, actual.flag) { $0?.name ?? "none" }
        check("color", expected.color, actual.color) { $0?.rawValue ?? "none" }
        check("delete", expected.delete, actual.delete)
        check("forward_to", expected.forwardTo.sorted(), actual.forwardTo.sorted()) { $0.isEmpty ? "none" : $0.joined(separator: ", ") }
        check("redirect_to", expected.redirectTo.sorted(), actual.redirectTo.sorted()) { $0.isEmpty ? "none" : $0.joined(separator: ", ") }
        check("reply_text", expected.replyText, actual.replyText) { $0.map { "\"\(Render.truncate($0, 60))\"" } ?? "none" }
        check("stop_evaluating", expected.stopEvaluating, actual.stopEvaluating)
        return out
    }

    /// Where `pending` stands in Mail's saved rules: nil when it is not there yet, else the differences (empty: saved).
    func check(_ pending: PendingRule, in rules: [MailRule]) -> [String]? {
        let named = rules.filter { $0.name == pending.name }
        switch pending.expectation {
        case .absent:
            return named.isEmpty ? [] : nil
        case .present(let spec, let enabled, let conditions):
            guard named.count == 1, let rule = named.first else { return nil }
            if let spec { return differences(spec, rule) }
            var out: [String] = []
            if rule.enabled != enabled { out.append("enabled: asked \(enabled), saved \(rule.enabled.map(String.init) ?? "unknown")") }
            if rule.criteria.count != conditions { out.append("conditions: asked \(conditions), saved \(rule.criteria.count)") }
            return out
        }
    }

    /// Waits for Mail's rule files to show `pending`'s change, and checks what they hold.
    func waitForRule(_ pending: PendingRule, before: [String: Date]) async throws -> RuleSave {
        let store = try self.store
        let started = Date()
        var wroteLocally = false
        var last: [String]?
        while true {
            last = check(pending, in: store.rules())
            if last?.isEmpty == true { return .saved }
            let dates = store.ruleFileDates()
            wroteLocally = wroteLocally || MailStore.ruleFiles.contains { dates[$0] != before[$0] }
            if Date().timeIntervalSince(started) >= ruleVerification.local + (wroteLocally ? ruleVerification.synced : 0) {
                // A rule that is there but not as asked counts once Mail wrote the file that holds the difference:
                // the definitions for most parts, the on/off state for `enabled`.
                if let last, !last.isEmpty {
                    let definitionsWritten = dates["SyncedRules.plist"] != before["SyncedRules.plist"]
                    let stateWritten = dates["RulesActiveState.plist"] != before["RulesActiveState.plist"]
                    if last.allSatisfy({ $0.hasPrefix("enabled:") }) ? stateWritten : definitionsWritten { return .differs(last) }
                }
                return wroteLocally ? .pendingICloud : .saving
            }
            try await Task.sleep(nanoseconds: UInt64(ruleVerification.interval * 1_000_000_000))
        }
    }

    /// Remembers a change Mail has not saved yet (or forgets one it saved).
    func track(_ save: RuleSave, _ rule: PendingRule) {
        pendingRules?.set(rule.name, save.pending == nil ? nil : rule)
    }

    /// Pending rule changes, checked against Mail's files: saved ones are dropped, the rest reported.
    func pendingRuleStatus(_ rules: [MailRule]) -> [JSON] {
        guard let pendingRules else { return [] }
        let launched = mailLaunchDate()
        var still: [PendingRule] = []
        var report: [JSON] = []
        for entry in pendingRules.all {
            let differences = check(entry, in: rules)
            if differences?.isEmpty == true { continue }
            let change: String
            switch entry.expectation {
            case .absent: change = "deleted"
            case .present(_, let enabled, _): change = enabled ? "on" : "off"
            }
            let status: String
            if let differences, !differences.isEmpty {
                status = "saved differently: " + differences.joined(separator: "; ")
            } else if launched.map({ $0 > entry.requested }) ?? true {
                status = "lost: Mail quit before saving it"
            } else {
                status = "not saved yet"
                still.append(entry)
            }
            report.append(.obj([("name", .string(entry.name)), ("change", .string(change)), ("status", .string(status))]))
        }
        if still.count != pendingRules.all.count { pendingRules.replaceAll(still) }
        return report
    }

    /// The reply fields every rule tool shares: whether Mail saved the change, and what to do if not.
    static func saveFields(_ save: RuleSave) -> [(String, JSON?)] {
        [
            ("saved", .bool(save.isSaved || save.differences != nil)),
            ("pending", save.pending.map(JSON.string)),
            ("note", save.pending == nil ? nil : .string(ruleNote)),
            ("differences", save.differences.map { list in .array(list.map(JSON.string)) }),
            ("warning", save.differences == nil ? nil : .string("Mail saved the rule, but not as asked; check it in Mail › Settings › Rules")),
        ]
    }
}
