import Foundation
import Testing

@testable import MailAutomation

/// Checks how the real Mail.app saves rules changed by raw Apple Events (see "Rules" in CLAUDE.md's Mail facts): a
/// `make` is saved, a property `set` or a `delete` is not. The probe rule matches a random subject and stays disabled,
/// so it never acts on mail.
/// Opt in with APPLE_MAIL_MCP_LIVE_RULES=1 (separate from APPLE_MAIL_MCP_LIVE: this one changes Mail's settings).
@Suite("Live rule probe")
struct RuleProbeTests {
    struct FileState: Equatable, CustomStringConvertible {
        var modified: Date?
        var size: Int?
        var description: String { "\(size.map(String.init) ?? "-") bytes" }
    }

    static let mailData = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Mail/V10/MailData")
    static let ruleFiles = ["SyncedRules.plist", "UnsyncedRules.plist", "RulesActiveState.plist"]

    /// stat works without Full Disk Access; reading the contents does not.
    static func fileStates() -> [String: FileState] {
        Dictionary(uniqueKeysWithValues: ruleFiles.map { name in
            let attributes = try? FileManager.default.attributesOfItem(atPath: mailData.appending(path: name).path)
            return (name, FileState(modified: attributes?[.modificationDate] as? Date, size: (attributes?[.size] as? NSNumber)?.intValue))
        })
    }

    /// Rule names in a plist, or nil when this process may not read it.
    static func ruleNames(in name: String) -> [String]? {
        guard let data = try? Data(contentsOf: mailData.appending(path: name)),
            let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]]
        else { return nil }
        return list.compactMap { $0["RuleName"] as? String }
    }

    /// Waits up to `timeout` for any rule file to differ from `before`; returns the files that changed.
    static func waitForWrite(since before: [String: FileState], timeout: TimeInterval) -> (changed: [String], after: TimeInterval) {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            let now = fileStates()
            let changed = ruleFiles.filter { now[$0] != before[$0] }
            if !changed.isEmpty { return (changed, Date().timeIntervalSince(start)) }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return ([], timeout)
    }

    static func rule(named name: String) -> NSAppleEventDescriptor {
        MailSpec.object(want: "rule", form: "name", seld: NSAppleEventDescriptor(string: name), from: nil)
    }

    static func ruleNamesInMail(_ mail: MailEventSender) throws -> [String] {
        AEValue(try mail.get(MailSpec.property("pnam", of: MailSpec.every("rule", of: nil)))).list.compactMap(\.string)
    }

    /// `make new rule` with one condition (subject contains `expression`); conditions can only be added once the
    /// rule exists. `make` ignores `enabled`, so it is set afterwards, before the save the `make` starts (≈1.5 s
    /// later) takes its copy of the list.
    static func makeProbeRule(_ mail: MailEventSender, name: String, expression: String, enabled: Bool) throws {
        let made = try mail.make(
            "rule", at: MailSpec.insertion("end ", of: MailSpec.every("rule", of: nil)),
            properties: [
                "pnam": NSAppleEventDescriptor(string: name),
                "isac": NSAppleEventDescriptor(boolean: enabled),
                "racm": NSAppleEventDescriptor(boolean: true),
                "rser": NSAppleEventDescriptor(boolean: true),
                "rcme": NSAppleEventDescriptor(enumCode: fourCC("ccre")),
            ])
        print("probe: make returned \(made.descriptorType == fourCC("obj ") ? "an object specifier" : "type \(made.descriptorType)")")
        _ = try mail.make(
            "rucr", at: MailSpec.insertion("end ", of: MailSpec.every("rucr", of: rule(named: name))),
            properties: [
                "rtyp": NSAppleEventDescriptor(enumCode: fourCC("tsub")),
                "rqua": NSAppleEventDescriptor(enumCode: fourCC("rqco")),
                "rexp": NSAppleEventDescriptor(string: expression),
            ])
        if enabled { try mail.set(MailSpec.property("isac", of: rule(named: name)), to: NSAppleEventDescriptor(boolean: true)) }
    }

    /// Waits for Mail to save after a `make`: the local files within 30 s, then the definitions (up to `synced` s,
    /// since they wait for Mail's iCloud Drive copy). Returns whether `SyncedRules.plist` was written.
    @discardableResult
    static func waitForSave(_ step: String, since before: [String: FileState], synced: TimeInterval) -> Bool {
        let local = waitAndReport(step, since: before, timeout: 30)
        #expect(local.contains("UnsyncedRules.plist") || local.contains("RulesActiveState.plist"), "Mail did not save after \(step) within 30 s")
        if local.contains("SyncedRules.plist") { return true }
        let wrote = waitAndReport("\(step) (definitions)", since: fileStates(), timeout: synced).contains("SyncedRules.plist")
        if !wrote { print("probe:   SyncedRules.plist not written yet: Mail is still waiting for its iCloud Drive copy") }
        return wrote
    }

    static func waitAndReport(_ step: String, since before: [String: FileState], timeout: TimeInterval) -> [String] {
        let write = waitForWrite(since: before, timeout: timeout)
        print("probe: after \(step), changed \(write.changed) in \(String(format: "%.1f", write.after)) s")
        for file in write.changed { print("probe:   \(file): \(before[file]!) → \(fileStates()[file]!)") }
        return write.changed
    }

    /// Creates a disabled rule (or reuses one an earlier run left in Mail), turns it on and off, then deletes it.
    /// Mail saves the create (the definition waits for its iCloud Drive copy) but none of the later changes, so the
    /// deleted rule stays in `SyncedRules.plist` until Mail's next save: any edit in Mail › Settings › Rules, or the
    /// next run's create. Quitting Mail before then brings it back.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["APPLE_MAIL_MCP_LIVE_RULES"] == "1"))
    func scriptedRuleChanges() throws {
        let mail = MailEventSender(timeout: 30)
        let existing = try Self.ruleNamesInMail(mail)
        print("probe: Mail has \(existing.count) rules; files readable: \(Self.ruleNames(in: "SyncedRules.plist") != nil)")
        var before = Self.fileStates()
        let name: String
        if let reused = existing.first(where: { $0.hasPrefix("apple-mail-mcp probe ") }) {
            name = reused
            print("probe: reusing a probe rule already in Mail")
        } else {
            let tag = UUID().uuidString.prefix(8).lowercased()
            name = "apple-mail-mcp probe \(tag)"
            try Self.makeProbeRule(mail, name: name, expression: "apple-mail-mcp-probe-\(tag)", enabled: false)
            let condition = MailSpec.every("rucr", of: Self.rule(named: name))
            #expect(AEValue(try mail.get(MailSpec.property("rexp", of: condition))).list.compactMap(\.string) == ["apple-mail-mcp-probe-\(tag)"])
            #expect(try mail.get(MailSpec.property("rcme", of: Self.rule(named: name))).enumCodeValue == fourCC("ccre"))

            // Saved: the local files at once, the definitions once Mail holds its iCloud Drive copy.
            Self.waitForSave("create", since: before, synced: 15)
            if let names = Self.ruleNames(in: "SyncedRules.plist") { print("probe:   in SyncedRules.plist: \(names.contains(name))") }
            Thread.sleep(forTimeInterval: 3)  // let a late write land before the next step
            before = Self.fileStates()
        }
        let rule = Self.rule(named: name)
        let enabled = MailSpec.property("isac", of: rule)
        #expect(try mail.get(enabled).booleanValue == false)

        // Not saved: a property set changes Mail's memory only.
        for value in [true, false] {
            try mail.set(enabled, to: NSAppleEventDescriptor(boolean: value))
            #expect(try mail.get(enabled).booleanValue == value)
            let changed = Self.waitAndReport(value ? "enable" : "disable", since: before, timeout: 15)
            #expect(changed.isEmpty, "Mail now saves a scripted enabled = \(value): update CLAUDE.md (Rules)")
            before = Self.fileStates()
        }

        // Not saved either: the rule leaves Mail's memory, not the files.
        try mail.send("core", "delo", direct: rule)
        #expect(try !Self.ruleNamesInMail(mail).contains(name))
        let deleted = Self.waitAndReport("delete", since: before, timeout: 15)
        #expect(deleted.isEmpty, "Mail now saves a scripted delete: update CLAUDE.md (Rules)")
        print("probe: deleted \"\(name)\" in Mail; it stays on disk until Mail's next save (any edit in Settings › Rules)")
    }

    /// How a server would change a rule (a scripted `set` is never saved): delete it, then `make` the replacement
    /// under the same name, so the save the `make` starts writes the list without the old rule. The old rule is
    /// disabled and matches "…-old"; the new one is enabled and matches "…-new". Check `SyncedRules.plist` and
    /// `RulesActiveState.plist` afterwards (they need Full Disk Access, e.g. `mail_setup`): one probe rule, enabled,
    /// matching "…-new". Probe rules from earlier runs are deleted first, so the first save drops them too; delete the
    /// last one in Mail › Settings › Rules.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["APPLE_MAIL_MCP_LIVE_RULES"] == "1"))
    func replaceRule() throws {
        let mail = MailEventSender(timeout: 30)
        let tag = UUID().uuidString.prefix(8).lowercased()
        let name = "apple-mail-mcp probe \(tag)"
        let leftovers = try Self.ruleNamesInMail(mail).filter { $0.hasPrefix("apple-mail-mcp probe ") }
        for leftover in leftovers { try mail.send("core", "delo", direct: Self.rule(named: leftover)) }
        print("probe: deleted \(leftovers.count) earlier probe rules; files readable: \(Self.ruleNames(in: "SyncedRules.plist") != nil)")

        var before = Self.fileStates()
        try Self.makeProbeRule(mail, name: name, expression: "apple-mail-mcp-probe-\(tag)-old", enabled: false)
        let first = Self.waitForSave("create", since: before, synced: 30)
        Thread.sleep(forTimeInterval: 3)  // let a late write land before the next step

        // Replace: delete first (memory only), make last (starts the save).
        before = Self.fileStates()
        try mail.send("core", "delo", direct: Self.rule(named: name))
        try Self.makeProbeRule(mail, name: name, expression: "apple-mail-mcp-probe-\(tag)-new", enabled: true)
        #expect(try Self.ruleNamesInMail(mail).filter { $0 == name }.count == 1)
        let condition = MailSpec.every("rucr", of: Self.rule(named: name))
        #expect(AEValue(try mail.get(MailSpec.property("rexp", of: condition))).list.compactMap(\.string) == ["apple-mail-mcp-probe-\(tag)-new"])
        #expect(try mail.get(MailSpec.property("isac", of: Self.rule(named: name))).booleanValue == true)
        let second = Self.waitForSave("replace", since: before, synced: 60)
        print("probe: definitions written after create: \(first), after replace: \(second)")
        if let names = Self.ruleNames(in: "SyncedRules.plist") {
            #expect(names.filter { $0 == name }.count == 1, "SyncedRules.plist should hold exactly one \"\(name)\"")
        }
        print("probe: left \"\(name)\" (enabled, matches \"…-new\"); delete it in Mail › Settings › Rules")
    }

    /// `createRule` and `setRuleEnabled` as the tools call them. Check with `mail_setup` afterwards: one probe rule,
    /// enabled, matching "…-tools", with its move, mark read, colour and stop actions. Delete it in Mail › Settings ›
    /// Rules (or run the probe again, which deletes it first).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["APPLE_MAIL_MCP_LIVE_RULES"] == "1"))
    func ruleCalls() async throws {
        let automation = MailAutomation()
        let mail = MailEventSender(timeout: 30)
        for leftover in try await automation.ruleNames() where leftover.hasPrefix("apple-mail-mcp probe ") {
            try mail.send("core", "delo", direct: Self.rule(named: leftover))
        }
        let account = try #require(try await automation.accounts().first { $0.enabled })
        let tag = UUID().uuidString.prefix(8).lowercased()
        let name = "apple-mail-mcp probe \(tag)"
        var before = Self.fileStates()
        try await automation.createRule(RuleSpec(
            name: name, enabled: false, conditions: [RuleCondition(field: .subject, value: "apple-mail-mcp-probe-\(tag)-tools")],
            moveTo: MailboxTarget(accountID: account.id, path: "INBOX"), markRead: true, color: .blue, stopEvaluating: true))
        Self.waitForSave("createRule", since: before, synced: 90)
        #expect(try await automation.ruleNames().filter { $0 == name }.count == 1)
        #expect(try mail.get(MailSpec.property("rstm", of: Self.rule(named: name))).booleanValue == true)
        try await Task.sleep(nanoseconds: 3_000_000_000)

        before = Self.fileStates()
        try await automation.setRuleEnabled(named: name, enabled: true, expectedConditions: 1)
        Self.waitForSave("setRuleEnabled", since: before, synced: 90)
        let rule = Self.rule(named: name)
        #expect(try mail.get(MailSpec.property("isac", of: rule)).booleanValue == true)
        #expect(try mail.get(MailSpec.property("rmre", of: rule)).booleanValue == true)
        #expect(try mail.get(MailSpec.property("rcme", of: rule)).enumCodeValue == fourCC("ccbl"))
        #expect(AEValue(try mail.get(MailSpec.property("rexp", of: MailSpec.every("rucr", of: rule)))).list.compactMap(\.string)
            == ["apple-mail-mcp-probe-\(tag)-tools"])
        await #expect(throws: RuleCopyError.self) { try await automation.setRuleEnabled(named: name, enabled: false, expectedConditions: 2) }
        print("probe: left \"\(name)\" (enabled, moves to INBOX of \(account.name)); delete it in Mail › Settings › Rules")
    }
}
