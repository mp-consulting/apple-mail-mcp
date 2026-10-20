import Foundation
import Testing

@testable import MailAutomation
@testable import MailStore

@Suite("Apple Event descriptors")
struct AppleEventTests {
    func field(_ descriptor: NSAppleEventDescriptor, _ key: String) -> NSAppleEventDescriptor? {
        descriptor.forKeyword(fourCC(key))
    }

    func code(_ descriptor: NSAppleEventDescriptor?) -> String? {
        guard let value = descriptor?.typeCodeValue ?? descriptor?.enumCodeValue else { return nil }
        return String(bytes: withUnsafeBytes(of: value.bigEndian) { Array($0) }, encoding: .macOSRoman)
    }

    @Test func fourCharCodes() {
        #expect(fourCC("mssg") == 0x6D73_7367)
        #expect(fourCC("ID  ") == 0x4944_2020)
    }

    /// Same shape AppleScript produces for `message id 42 of mailbox "Archive/2020" of account id "X"`.
    @Test func messageSpecifier() throws {
        let spec = MailSpec.message(42, in: MailboxTarget(accountID: "ACCOUNT", path: "Archive/2020"))
        #expect(spec.descriptorType == fourCC("obj "))
        #expect(code(field(spec, "want")) == "mssg")
        #expect(code(field(spec, "form")) == "ID  ")
        #expect(field(spec, "seld")?.int32Value == 42)
        let mailbox = try #require(field(spec, "from"))
        #expect(code(field(mailbox, "want")) == "mbxp")
        #expect(code(field(mailbox, "form")) == "name")
        #expect(field(mailbox, "seld")?.stringValue == "Archive/2020")
        let account = try #require(field(mailbox, "from"))
        #expect(code(field(account, "want")) == "mact")
        #expect(field(account, "seld")?.stringValue == "ACCOUNT")
        #expect(field(account, "from")?.descriptorType == fourCC("null"))
    }

    /// Same shape AppleScript produces for `every message of mailbox "Archive/2005" of account id "X" whose
    /// message id = "abc@example.test"`: Mail tests the header itself, no id-to-index lookup.
    @Test func messageByHeaderSpecifier() throws {
        let spec = MailSpec.message(header: "abc@example.test", in: MailboxTarget(accountID: "ACCOUNT", path: "Archive/2005"))
        #expect(spec.descriptorType == fourCC("obj "))
        #expect(code(field(spec, "want")) == "mssg")
        #expect(code(field(spec, "form")) == "test")
        #expect(field(try #require(field(spec, "from")), "seld")?.stringValue == "Archive/2005")
        let test = try #require(field(spec, "seld"))
        #expect(test.descriptorType == fourCC("cmpd"))
        #expect(code(field(test, "relo")) == "=   ")
        #expect(field(test, "obj2")?.stringValue == "abc@example.test")
        let property = try #require(field(test, "obj1"))
        #expect(code(field(property, "want")) == "prop")
        #expect(code(field(property, "seld")) == "meid")  // `message id` in Mail's sdef
        #expect(field(property, "from")?.descriptorType == fourCC("exmn"))
    }

    /// Trashing sends `move … to <the account's Trash>`: a `delete` (`core/delo`) on a message removes by index, even
    /// with a `whose` specifier, and has taken the neighbour.
    @Test func trashIsAMoveNeverADelete() throws {
        let trash = MailboxTarget(accountID: "ACCOUNT", path: "Deleted Messages")
        let event = MessageEvent.trash(to: trash)
        #expect(event.eventClass == "core" && event.eventID == "move")
        #expect(event.eventID != MessageEvent.delete.eventID)
        let destination = try #require(event.parameters["insh"])
        #expect(code(field(destination, "want")) == "mbxp")
        #expect(field(destination, "seld")?.stringValue == "Deleted Messages")
        #expect(field(try #require(field(destination, "from")), "seld")?.stringValue == "ACCOUNT")
        #expect(MessageEvent.delete.eventID == "delo" && MessageEvent.delete.parameters.isEmpty)
    }

    /// A message without a Message-ID is changed by id only when Mail shows the subject and date the store has.
    @Test func idIsCheckedAgainstSubjectAndDate() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let message = MessageRef(id: 7, header: nil, subject: "Re: Invoice 42", dateReceived: date)
        #expect(MailAutomation.matches(message, subject: "Re: Invoice 42 ", received: date.addingTimeInterval(0.6)))
        #expect(!MailAutomation.matches(message, subject: "Invoice 43", received: date))
        #expect(!MailAutomation.matches(message, subject: "Re: Invoice 42", received: date.addingTimeInterval(-86_400)))
        #expect(!MailAutomation.matches(message, subject: "Re: Invoice 42", received: nil))
    }

    @Test func alertsFailFast() {
        #expect(AppleEventError(number: -1713, message: "").description.contains("alert"))
    }

    @Test func localMailboxesHaveNoAccount() {
        let spec = MailSpec.mailbox(MailboxTarget(accountID: "", path: "Outbox"))
        #expect(field(spec, "from")?.descriptorType == fourCC("null"))
    }

    @Test func everyAndInsertionLocation() throws {
        let every = MailSpec.every("trcp", of: MailSpec.account(id: "A"))
        #expect(code(field(every, "form")) == "indx")
        let seld = try #require(field(every, "seld"))
        #expect(seld.descriptorType == fourCC("abso"))
        #expect(seld.data == withUnsafeBytes(of: fourCC("all ")) { Data($0) })  // native byte order, as AppleScript sends it
        let insertion = MailSpec.insertion("end ", of: every)
        #expect(insertion.descriptorType == fourCC("insl"))
        #expect(code(field(insertion, "kpos")) == "end ")
    }

    @Test func propertySpecifier() {
        let spec = MailSpec.property("isrd", of: MailSpec.account(id: "A"))
        #expect(code(field(spec, "want")) == "prop")
        #expect(code(field(spec, "seld")) == "isrd")
    }

    @Test func replyValuesDecode() {
        let list = NSAppleEventDescriptor.list()
        list.insert(NSAppleEventDescriptor(string: "a"), at: 1)
        list.insert(NSAppleEventDescriptor(int32: 7), at: 2)
        list.insert(NSAppleEventDescriptor(boolean: true), at: 3)
        list.insert(NSAppleEventDescriptor.list(), at: 4)
        #expect(AEValue(list) == .list([.string("a"), .int(7), .bool(true), .list([])]))
    }

    @Test func mailboxTargetFromMailbox() {
        let imap = Mailbox(
            id: 1, url: "imap://ACC/Archive/2020", accountID: "ACC", path: "Archive/2020", name: "2020", role: .archive,
            totalCount: 0, unreadCount: 0, sourceMailboxID: nil)
        #expect(MailboxTarget(imap) == MailboxTarget(accountID: "ACC", path: "Archive/2020"))
        let local = Mailbox(
            id: 2, url: "local://LOC/Outbox", accountID: "LOC", path: "Outbox", name: "Outbox", role: .outbox,
            totalCount: 0, unreadCount: 0, sourceMailboxID: nil)
        #expect(MailboxTarget(local).accountID == "")
    }

    @Test func errorsExplainPermissions() {
        #expect(AppleEventError(number: -1743, message: "").description.contains("Automation"))
        #expect(AppleEventError(number: -1728, message: "x").description.contains("moved"))
    }

    @Test func automationLockSerializes() async throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "lock-\(UUID().uuidString)").path
        let counter = Counter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    try await AutomationLock.withLock(timeout: 10, path: path) {
                        let active = await counter.enter()
                        #expect(active == 1)
                        try await Task.sleep(nanoseconds: 20_000_000)
                        await counter.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    @Test func automationLockTimesOut() async throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "lock-\(UUID().uuidString)").path
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        flock(fd, LOCK_EX)
        defer { close(fd) }
        await #expect(throws: AutomationLock.Busy.self) {
            try await AutomationLock.withLock(timeout: 0.2, path: path) {}
        }
    }

    @Test func automationLockIsReentrantForItsHolderOnly() async throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "lock-\(UUID().uuidString)").path
        try await AutomationLock.withLock(timeout: 1, path: path) {
            // The holder's own events go through; another task has to wait (and here gives up).
            try await AutomationLock.withLock(timeout: 0.2, path: path) {}
            let other = Task.detached { try await AutomationLock.withLock(timeout: 0.2, path: path) {} }
            await #expect(throws: AutomationLock.Busy.self) { try await other.value }
        }
    }

    /// Talks to the real Mail.app (read-only). Opt in with APPLE_MAIL_MCP_LIVE=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["APPLE_MAIL_MCP_LIVE"] == "1"))
    func liveAccounts() async throws {
        let accounts = try await MailAutomation().accounts()
        #expect(!accounts.isEmpty)
    }
}

actor Counter {
    var active = 0
    func enter() -> Int {
        active += 1
        return active
    }
    func leave() { active -= 1 }
}
