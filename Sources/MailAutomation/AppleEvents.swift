import AppKit
import CoreServices
import Foundation

/// Four-character code from a string such as `"mssg"`.
@inline(__always) func fourCC(_ text: String) -> FourCharCode {
    text.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
}

/// An Apple Event error, with the usual codes explained.
public struct AppleEventError: Error, CustomStringConvertible, Sendable {
    public var number: Int
    public var message: String

    public init(number: Int, message: String) {
        self.number = number
        self.message = message
    }

    public var description: String {
        switch number {
        case -1743:
            """
            Not allowed to control Mail. Allow it in System Settings → Privacy & Security → Automation \
            for the app that launched this server (Claude, your terminal, or Apple Mail MCP).
            """
        case -1744: "Mail automation needs your consent; approve the macOS prompt and retry."
        case -1712: "Mail did not answer in time; it may be busy syncing. Try again."
        case -600, -609: "Mail is not running or quit unexpectedly."
        case -1728: "Mail could not find that item (\(message)). It may have been moved; search again for its new id."
        default: "Mail returned error \(number)\(message.isEmpty ? "" : ": \(message)")"
        }
    }
}

/// Object specifiers for Mail's scripting model, built directly as
/// descriptors: no AppleScript source, compilation or string escaping.
enum MailSpec {
    static func object(want: String, form: String, seld: NSAppleEventDescriptor, from: NSAppleEventDescriptor?) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: fourCC(want)), forKeyword: fourCC("want"))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: fourCC(form)), forKeyword: fourCC("form"))
        record.setDescriptor(seld, forKeyword: fourCC("seld"))
        record.setDescriptor(from ?? NSAppleEventDescriptor.null(), forKeyword: fourCC("from"))
        return record.coerce(toDescriptorType: fourCC("obj ")) ?? record
    }

    static func property(_ code: String, of container: NSAppleEventDescriptor?) -> NSAppleEventDescriptor {
        object(want: "prop", form: "prop", seld: NSAppleEventDescriptor(typeCode: fourCC(code)), from: container)
    }

    /// `every <class> of container`
    static func every(_ cls: String, of container: NSAppleEventDescriptor?) -> NSAppleEventDescriptor {
        var all = fourCC("all ")  // OSType data is stored in native byte order
        let seld = NSAppleEventDescriptor(descriptorType: fourCC("abso"), bytes: &all, length: 4)!
        return object(want: cls, form: "indx", seld: seld, from: container)
    }

    static func account(id: String) -> NSAppleEventDescriptor {
        object(want: "mact", form: "ID  ", seld: NSAppleEventDescriptor(string: id), from: nil)
    }

    /// Mailboxes are addressed by full path (`Archive/2020`). Local ("On My Mac") ones sit at the top level.
    static func mailbox(_ target: MailboxTarget) -> NSAppleEventDescriptor {
        object(
            want: "mbxp", form: "name", seld: NSAppleEventDescriptor(string: target.path),
            from: target.accountID.isEmpty ? nil : account(id: target.accountID))
    }

    /// `message id <rowid> of mailbox …`: direct lookup, no `whose` scan.
    static func message(_ id: Int64, in target: MailboxTarget) -> NSAppleEventDescriptor {
        object(want: "mssg", form: "ID  ", seld: NSAppleEventDescriptor(int32: Int32(truncatingIfNeeded: id)), from: mailbox(target))
    }

    /// Insertion location such as `end of to recipients of m`.
    static func insertion(_ position: String, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(container, forKeyword: fourCC("kobj"))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: fourCC(position)), forKeyword: fourCC("kpos"))
        return record.coerce(toDescriptorType: fourCC("insl")) ?? record
    }

    static func list(_ items: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
        let list = NSAppleEventDescriptor.list()
        for (index, item) in items.enumerated() { list.insert(item, at: index + 1) }
        return list
    }

    static func properties(_ values: [String: NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        for (key, value) in values { record.setDescriptor(value, forKeyword: fourCC(key)) }
        return record
    }

    static func fileURL(_ path: String) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(fileURL: URL(filePath: path))
    }
}

/// A value read back from an Apple Event reply.
public indirect enum AEValue: Sendable, Hashable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case list([AEValue])
    case null

    init(_ descriptor: NSAppleEventDescriptor) {
        switch descriptor.descriptorType {
        case fourCC("list"):
            self = .list(descriptor.numberOfItems == 0 ? [] : (1...descriptor.numberOfItems).compactMap {
                descriptor.atIndex($0).map(AEValue.init)
            })
        case fourCC("bool"), fourCC("true"), fourCC("fals"):
            self = .bool(descriptor.booleanValue)
        case fourCC("long"), fourCC("shor"), fourCC("comp"):
            self = .int(Int(descriptor.int32Value))
        case fourCC("null"), fourCC("msng"):
            self = .null
        default:
            self = descriptor.stringValue.map(AEValue.string) ?? .null
        }
    }

    public var string: String? { if case .string(let v) = self { v } else { nil } }
    public var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
    public var list: [AEValue] { if case .list(let v) = self { v } else { [] } }
}

/// Sends Apple Events to Mail and waits for the reply. `AESendMessage` is
/// thread-safe, so this works from any task; calls are still serialized
/// because Mail processes one scripting request at a time.
final class MailEventSender: @unchecked Sendable {
    static let bundleIdentifier = "com.apple.mail"
    private let lock = NSLock()
    let timeout: TimeInterval

    init(timeout: TimeInterval = 60) { self.timeout = timeout }

    private var target: NSAppleEventDescriptor { NSAppleEventDescriptor(bundleIdentifier: Self.bundleIdentifier) }

    /// Launches Mail in the background if needed (events to a non-running app fail with -600).
    func ensureMailRunning() throws {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).isEmpty { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier) else {
            throw AppleEventError(number: -600, message: "Mail.app not found")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
        let deadline = Date().addingTimeInterval(30)
        while NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).isEmpty {
            if Date() > deadline { throw AppleEventError(number: -600, message: "Mail did not launch") }
            Thread.sleep(forTimeInterval: 0.2)
        }
        Thread.sleep(forTimeInterval: 1.5)  // let Mail finish loading its scripting support
    }

    /// Whether this process may send Apple Events to Mail: 0 allowed, -1743 denied,
    /// -1744 consent needed, -600 Mail not running.
    func permissionStatus(askIfNeeded: Bool) -> Int {
        let target = self.target
        guard let desc = target.aeDesc else { return -1 }
        return Int(AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, askIfNeeded))
    }

    @discardableResult
    func send(
        _ eventClass: String, _ eventID: String, direct: NSAppleEventDescriptor? = nil,
        _ parameters: [String: NSAppleEventDescriptor] = [:]
    ) throws -> NSAppleEventDescriptor {
        lock.lock()
        defer { lock.unlock() }
        try ensureMailRunning()
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: fourCC(eventClass), eventID: fourCC(eventID), targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if let direct { event.setParam(direct, forKeyword: keyDirectObject) }
        for (key, value) in parameters { event.setParam(value, forKeyword: fourCC(key)) }
        let reply: NSAppleEventDescriptor
        do {
            reply = try event.sendEvent(options: [.waitForReply, .canInteract], timeout: timeout)
        } catch let error as NSError {
            throw AppleEventError(number: error.code, message: error.localizedDescription)
        }
        if let number = reply.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value, number != 0 {
            let message = reply.paramDescriptor(forKeyword: keyErrorString)?.stringValue ?? ""
            throw AppleEventError(number: Int(number), message: message)
        }
        return reply.paramDescriptor(forKeyword: keyDirectObject) ?? NSAppleEventDescriptor.null()
    }

    // Standard suite shorthands.
    func get(_ specifier: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        try send("core", "getd", direct: specifier)
    }

    func set(_ specifier: NSAppleEventDescriptor, to value: NSAppleEventDescriptor) throws {
        try send("core", "setd", direct: specifier, ["data": value])
    }

    func make(_ cls: String, at location: NSAppleEventDescriptor? = nil, properties: [String: NSAppleEventDescriptor]) throws
        -> NSAppleEventDescriptor
    {
        var parameters = ["kocl": NSAppleEventDescriptor(typeCode: fourCC(cls)), "prdt": MailSpec.properties(properties)]
        if let location { parameters["insh"] = location }
        return try send("core", "crel", parameters)
    }
}
