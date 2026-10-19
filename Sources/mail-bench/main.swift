import Foundation
import MCP
import MailFixtures
import MailMCPKit
import MailStore
import System

// Benchmarks for apple-mail-mcp. Prints timings and counts only, never message content.
//
//   mail-bench compare [--servers imdinu,mgcrea,…] [--server PATH] [--account NAME] [--runs N] [--other-runs N] [--fresh-index] [--out FILE]
//       The same questions to this server and to the other Apple Mail MCP servers, over real MCP stdio sessions.
//       Run Scripts/bench-servers.sh first: it fetches the servers that ship as release files and builds their indexes.
//   mail-bench store [--runs N]
//       In-process timings of MailStore operations on your own Mail data.
//   mail-bench synthetic [--messages N] [--runs N]
//       Builds a generated mailbox of N messages and times the same operations (no personal data).
//   mail-bench demo [--dir DIR] [--messages N]
//       Writes a fake environment (mail, activity, a pending approval) for screenshots of the app.

struct Options {
    var values: [String: String] = [:]
    var command = "store"

    init(_ arguments: [String]) {
        var rest = arguments.dropFirst()
        if let first = rest.first, !first.hasPrefix("--") {
            command = first
            rest = rest.dropFirst()
        }
        while let key = rest.first, key.hasPrefix("--") {
            rest = rest.dropFirst()
            // A flag (`--fresh-index`) has no value: the next option is not its value.
            if let value = rest.first, !value.hasPrefix("--") {
                values[String(key.dropFirst(2))] = String(value)
                rest = rest.dropFirst()
            } else {
                values[String(key.dropFirst(2))] = ""
            }
        }
    }

    func int(_ key: String, _ fallback: Int) -> Int { values[key].flatMap(Int.init) ?? fallback }
    func string(_ key: String, _ fallback: String) -> String { values[key] ?? fallback }
}

func milliseconds(since start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
}

func measure(runs: Int, _ body: () throws -> Void) rethrows -> [Double] {
    var samples: [Double] = []
    for _ in 0..<runs {
        let start = DispatchTime.now().uptimeNanoseconds
        try body()
        samples.append(milliseconds(since: start))
    }
    return samples
}

func median(_ samples: [Double]) -> Double {
    let sorted = samples.sorted()
    guard !sorted.isEmpty else { return .nan }
    return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
}

func format(_ ms: Double) -> String {
    if ms.isNaN { return "–" }
    if ms >= 10_000 { return String(format: "%.1f s", ms / 1000) }
    if ms >= 1000 { return String(format: "%.2f s", ms / 1000) }
    if ms >= 10 { return String(format: "%.0f ms", ms) }
    return String(format: "%.1f ms", ms)
}

func machineDescription() -> String {
    var size = 0
    sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
    var buffer = [CChar](repeating: 0, count: max(size, 1))
    sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
    let cpu = String(cString: buffer)
    let memory = ProcessInfo.processInfo.physicalMemory / 1_073_741_824
    let os = ProcessInfo.processInfo.operatingSystemVersionString
    var load = [Double](repeating: 0, count: 3)
    getloadavg(&load, 3)
    return "\(cpu), \(memory) GB RAM, macOS \(os), load average \(String(format: "%.0f", load[0])) at start"
}

// MARK: In-process store benchmarks

struct StoreScenario {
    var name: String
    var run: () throws -> Void
}

func storeScenarios(store: MailStore, index: BodyIndex?, inbox: [Int64], threadID: Int64?) -> [StoreScenario] {
    var list: [StoreScenario] = []
    func add(_ name: String, _ body: @escaping () throws -> Void) { list.append(StoreScenario(name: name, run: body)) }
    add("Recent 20 in inbox") {
        var q = MessageQuery(); q.mailboxIDs = inbox; q.limit = 20
        _ = try store.search(q)
    }
    add("Unread in inbox (count + 50)") {
        var q = MessageQuery(); q.mailboxIDs = inbox; q.isRead = false; q.limit = 50
        _ = try store.search(q)
    }
    add("Subject search, all mailboxes") {
        var q = MessageQuery(); q.subjectTerms = ["invoice", "report"]; q.limit = 20
        _ = try store.search(q)
    }
    add("Sender search, all mailboxes") {
        var q = MessageQuery(); q.sender = "news"; q.limit = 20
        _ = try store.search(q)
    }
    add("Flagged, all mailboxes") {
        var q = MessageQuery(); q.isFlagged = true; q.limit = 20
        _ = try store.search(q)
    }
    add("Read 20 full messages") {
        var q = MessageQuery(); q.mailboxIDs = inbox; q.limit = 20
        for message in try store.search(q).messages { _ = try? store.detail(id: message.id) }
    }
    if let threadID { add("Conversation") { _ = try store.thread(of: threadID) } }
    add("Top senders, 30 days") { _ = try store.topSenders(days: 30) }
    add("Statistics, 30 days") { _ = try store.statistics(days: 30) }
    add("Awaiting reply, 14 days") { _ = try store.awaitingReply(days: 14) }
    add("Needs response, 7 days") { _ = try store.needsResponse(days: 7) }
    add("Body search, scan 2,000 newest") {
        var q = MessageQuery(); q.bodyText = "zzqx-not-present"; q.limit = 10; q.bodyScanBudget = 2000
        _ = try store.search(q)
    }
    if let index {
        add("Body search, full index") {
            var q = MessageQuery(); q.bodyText = "kubernetes"; q.limit = 20
            _ = try store.search(q, bodyIndex: index)
        }
    }
    return list
}

func runStoreBenchmarks(
    store: MailStore, index: BodyIndex?, runs: Int, title: String, extra: [StoreScenario] = []
) throws -> String {
    let inbox = try store.mailboxes().filter { $0.role == .inbox }.map(\.id)
    var latest = MessageQuery()
    latest.limit = 200
    var threadID: Int64?
    for message in try store.search(latest).messages where try store.thread(of: message.id).count >= 3 {
        threadID = message.id
        break
    }
    var lines = ["### \(title)", "", "| Operation | Median | Min | Max |", "|---|---:|---:|---:|"]
    for scenario in storeScenarios(store: store, index: index, inbox: inbox, threadID: threadID) + extra {
        _ = try? scenario.run()  // warm-up
        let samples = try measure(runs: runs, scenario.run)
        lines.append("| \(scenario.name) | \(format(median(samples))) | \(format(samples.min() ?? .nan)) | \(format(samples.max() ?? .nan)) |")
        FileHandle.standardError.write(Data("  \(scenario.name): \(format(median(samples)))\n".utf8))
    }
    return lines.joined(separator: "\n")
}

/// What a tool call costs right after Mail commits (synthetic stores only: it writes to the database).
/// With Mail running, `PRAGMA data_version` moves on nearly every call.
func mailWriteScenario(store: MailStore) throws -> StoreScenario {
    let writer = try SQLiteConnection(path: store.location.envelopeIndex.path, readOnly: false)
    return StoreScenario(name: "Mailboxes after a Mail write") {
        try writer.execute("UPDATE messages SET read = 1 - read WHERE ROWID = (SELECT MAX(ROWID) FROM messages)")
        _ = try store.mailboxes()
        _ = try store.accounts()
    }
}

// MARK: MCP comparison

/// An MCP client talking to a server subprocess over stdio.
final class MCPProcess {
    let process = Process()
    let client: Client
    let label: String

    init(label: String, command: [String], environment: [String: String] = [:], startTimeout: TimeInterval = 120) async throws {
        self.label = label
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = command
        process.standardInput = input
        process.standardOutput = output
        // With APPLE_MAIL_MCP_TRACE set, our server's stage timings (numbers only) go to this run's stderr.
        process.standardError = ProcessInfo.processInfo.environment["APPLE_MAIL_MCP_TRACE"] != nil && label.hasPrefix("ours")
            ? FileHandle.standardError : FileHandle(forWritingAtPath: "/dev/null")
        var env = ProcessInfo.processInfo.environment
        env["APPLE_MAIL_MCP_NO_ACTIVITY"] = "1"  // keep benchmark calls out of the user's Activity
        for (key, value) in environment { env[key] = value }
        process.environment = env
        try process.run()
        // Blocking reads, not the SDK's 10 ms polling, so the client adds no latency of its own to any server.
        let transport = LineTransport(
            input: output.fileHandleForReading.fileDescriptor, output: input.fileHandleForWriting.fileDescriptor)
        let client = Client(name: "mail-bench", version: "1.0")
        self.client = client
        // A server that never answers `initialize` would hang the whole run: give up on it.
        let process = self.process
        let watchdog = Task {
            try await Task.sleep(nanoseconds: UInt64(startTimeout * 1e9))
            await client.disconnect()
            process.terminate()
        }
        defer { watchdog.cancel() }
        _ = try await client.connect(transport: transport)
    }

    /// Calls a tool with a client-side timeout. Returns elapsed ms, whether it succeeded, and the result text
    /// (used only to find a message ref and to measure the response size, never printed).
    func call(_ tool: String, _ arguments: [String: Value], timeout: TimeInterval) async -> (ms: Double, ok: Bool, note: String?, text: String) {
        let start = DispatchTime.now().uptimeNanoseconds
        let client = self.client
        let result = await withTaskGroup(of: (Bool, String?, String)?.self) { group in
            group.addTask {
                do {
                    let (content, isError) = try await client.callTool(name: tool, arguments: arguments)
                    var text = ""
                    for item in content { if case .text(let t, _, _) = item { text += t } }
                    let looksLikeError = isError == true || text.hasPrefix("Error") || text.contains("timed out")
                    return (!looksLikeError, looksLikeError ? String(text.prefix(300)) : nil, text)
                } catch {
                    return (false, "\(error)".prefix(80).description, "")
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
                // Disconnecting fails the pending request, so the call above returns too; the caller then
                // starts a fresh server. Cancelling alone would leave the group waiting on that request.
                if !Task.isCancelled { await client.disconnect() }
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        let ms = milliseconds(since: start)
        guard let result else { return (ms, false, "timeout after \(Int(timeout)) s", "") }
        return (ms, result.0, result.1, result.2)
    }

    /// Disconnects first: once the server is gone, the SDK's receive loop spins on the closed stream
    /// (a full core per stopped server) until the client is disconnected.
    func stop() async {
        await client.disconnect()
        process.terminate()
    }
}

/// One timed tool call. `prepare` makes untimed calls first to find an argument the server only accepts
/// in its own format (an opaque message ref, a thread id).
struct Call {
    var tool: String
    var arguments: [String: Value]
    var prepare: ((MCPProcess) async -> [String: Value]?)? = nil
}

/// A server under test: how to start it, and which of its tools answers each question.
struct BenchServer {
    var key: String
    var title: String
    var command: [String]
    var environment: [String: String] = [:]
    var runs: Int
    var calls: [String: Call]
    /// Run once before the server starts, untimed: building its index.
    var prepare: [String]? = nil
}

/// Runs a preparation command (an index build) to completion; false when it failed.
func runPreparation(_ command: [String], environment: [String: String]) -> Bool {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/env")
    process.arguments = command
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
    process.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
    process.standardError = FileHandle(forWritingAtPath: "/dev/null")
    guard (try? process.run()) != nil else { return false }
    process.waitUntilExit()
    return process.terminationStatus == 0
}

/// First capture group of `pattern` in a tool result, e.g. a message ref.
func firstMatch(_ pattern: String, in text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
        let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
        let range = Range(match.range(at: 1), in: text)
    else { return nil }
    return String(text[range])
}

let scenarioNames = [
    "List accounts", "Unread counts per mailbox", "Latest 20 inbox messages", "Subject search (inbox)",
    "Subject search (all mailboxes)", "Sender search (inbox)", "Body text search (inbox)", "Conversation thread",
    "Top senders, 30 days", "Statistics, 30 days", "Awaiting reply, 7 days", "Needs response, 7 days", "Inbox overview",
]

/// Where `Scripts/bench-servers.sh` puts the servers that ship as release files rather than packages.
let benchServersDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: "Library/Caches/AppleMailMCP/bench-servers").path

func runComparison(options: Options) async throws -> String {
    let store = try MailStore.open()
    let accountName = options.string("account", try store.accounts().max {
        ($0.emailAddresses.count, try! store.mailboxes(accountID: $0.id).count)
            < ($1.emailAddresses.count, try! store.mailboxes(accountID: $1.id).count)
    }?.name ?? "iCloud")
    let account = try store.resolveAccount(accountName)
    let inbox = try store.resolveMailboxes("inbox", accountID: account.id)
    let inboxMessages = inbox.reduce(0) { $0 + $1.totalCount }
    let accountMessages = try store.mailboxes(accountID: account.id).reduce(0) { $0 + $1.totalCount }
    // A conversation to fetch: newest inbox message whose thread has 3+ messages.
    var recent = MessageQuery()
    recent.mailboxIDs = inbox.map(\.id)
    recent.limit = 300
    var thread: MessageSummary?
    for minimum in [3, 2] where thread == nil {
        for message in try store.search(recent).messages where try store.thread(of: message.id).count >= minimum {
            thread = message
            break
        }
    }
    let threadKeyword = thread.map { MessageContent.normalizeSubject($0.subject) } ?? "update"
    let runs = options.int("runs", 3)
    let otherRuns = max(1, options.int("other-runs", 1))
    let timeout = Double(options.int("timeout", 180))
    let dir = options.string("servers-dir", benchServersDirectory)

    // The same questions in every server's own words. Account, inbox and search terms are identical.
    let name = Value.string(account.name)
    let uuid = Value.string(account.id)
    let box = Value.string(inbox.first?.name ?? "INBOX")
    let since30 = Value.string(ISO8601DateFormatter.string(
        from: Date().addingTimeInterval(-30 * 86_400), timeZone: .current, formatOptions: [.withFullDate]))
    func jxa(_ action: String, _ args: [String: Value] = [:]) -> Call {
        Call(tool: "read", arguments: ["action": .string(action), "args": .object(args)])
    }
    let ours: [String: Call] = [
        "List accounts": Call(tool: "list_accounts", arguments: [:]),
        "Unread counts per mailbox": Call(tool: "list_mailboxes", arguments: ["account": name]),
        "Latest 20 inbox messages": Call(tool: "search_messages", arguments: ["account": name, "mailbox": "inbox", "limit": 20]),
        "Subject search (inbox)": Call(tool: "search_messages", arguments: ["account": name, "mailbox": "inbox", "subject": "invoice", "limit": 20]),
        "Subject search (all mailboxes)": Call(tool: "search_messages", arguments: ["account": name, "subject": "invoice", "limit": 20]),
        "Sender search (inbox)": Call(tool: "search_messages", arguments: ["account": name, "mailbox": "inbox", "sender": "github", "limit": 20]),
        "Body text search (inbox)": Call(tool: "search_messages", arguments: ["account": name, "mailbox": "inbox", "body": "kubernetes", "limit": 10]),
        "Conversation thread": Call(tool: "get_thread", arguments: ["id": .int(Int(thread?.id ?? 0))]),
        "Top senders, 30 days": Call(tool: "top_senders", arguments: ["account": name, "mailbox": "inbox", "days": 30]),
        "Statistics, 30 days": Call(tool: "mail_statistics", arguments: ["account": name, "days": 30]),
        "Awaiting reply, 7 days": Call(tool: "awaiting_reply", arguments: ["account": name, "days": 7]),
        "Needs response, 7 days": Call(tool: "needs_response", arguments: ["account": name, "days": 7]),
        "Inbox overview": Call(tool: "inbox_overview", arguments: [:]),
    ]
    let serverPath = options.string("server", ".build/release/apple-mail-mcp")
    let emptySupport = FileManager.default.temporaryDirectory.appending(path: "bench-noindex-\(UUID().uuidString)").path
    // Generated mail instead of the user's: `APPLE_MAIL_MCP_MAIL_ROOT` set, as `mail-bench demo` prints.
    let testMailRoot = ProcessInfo.processInfo.environment["APPLE_MAIL_MCP_MAIL_ROOT"]
    var allServers: [BenchServer] = [
        BenchServer(key: "ours", title: "**Apple Mail MCP**", command: [serverPath, "--read-only"], runs: runs, calls: ours),
        BenchServer(
            key: "ours-noindex", title: "Apple Mail MCP, no body index", command: [serverPath, "--read-only"],
            environment: ["APPLE_MAIL_MCP_SUPPORT_DIR": emptySupport], runs: runs, calls: ours),
        // imdinu/apple-mail-mcp: FTS5 index of the .emlx files (`apple-mail-mcp index` first), JXA for the rest.
        BenchServer(
            key: "imdinu", title: "imdinu 0.5.0", command: ["uvx", "apple-mail-mcp@0.5.0", "serve", "--read-only"], runs: otherRuns,
            calls: [
                "List accounts": Call(tool: "list_accounts", arguments: [:]),
                "Unread counts per mailbox": Call(tool: "list_mailboxes", arguments: ["account": name]),
                "Latest 20 inbox messages": Call(tool: "get_emails", arguments: ["account": name, "mailbox": box, "limit": 20]),
                "Subject search (inbox)": Call(tool: "search", arguments: ["query": "invoice", "scope": "subject", "account": name, "mailbox": box, "limit": 20]),
                "Subject search (all mailboxes)": Call(tool: "search", arguments: ["query": "invoice", "scope": "subject", "account": name, "limit": 20]),
                "Sender search (inbox)": Call(tool: "search", arguments: ["query": "github", "scope": "sender", "account": name, "mailbox": box, "limit": 20]),
                "Body text search (inbox)": Call(tool: "search", arguments: ["query": "kubernetes", "scope": "body", "account": name, "mailbox": box, "limit": 10]),
            ]),
        // ipsupport-llc/apple-mail-mcp: JavaScript for Automation through osascript, one `read` tool with actions.
        BenchServer(
            key: "ipsupport", title: "ipsupport-llc 1.6.1",
            command: ["/usr/bin/osascript", "-l", "JavaScript", "\(dir)/ipsupport-llc/server/apple-mail-mcp.js"],
            environment: ["APPLE_MAIL_READ_ONLY": "true"], runs: otherRuns,
            calls: [
                "List accounts": jxa("list_accounts"),
                "Unread counts per mailbox": jxa("list_mailboxes", ["account": name]),
                "Latest 20 inbox messages": jxa("list_messages", ["account": name, "mailbox": box, "limit": 20]),
                "Subject search (inbox)": jxa("search_messages", ["query": "invoice", "in": "subject", "account": name, "mailbox": box, "limit": 20]),
                "Subject search (all mailboxes)": jxa("search_messages", ["query": "invoice", "in": "subject", "account": name, "all_mailboxes": true, "limit": 20]),
                "Sender search (inbox)": jxa("search_messages", ["query": "github", "in": "sender", "account": name, "mailbox": box, "limit": 20]),
                "Body text search (inbox)": jxa("search_messages", ["query": "kubernetes", "in": "body", "account": name, "mailbox": box, "limit": 10]),
                "Conversation thread": jxa("get_thread", ["id": .int(Int(thread?.id ?? 0)), "account": name, "mailbox": box]),
                "Awaiting reply, 7 days": jxa("awaiting_reply", ["days": 7, "account": name]),
                "Needs response, 7 days": jxa("needs_response", ["days": 7, "account": name]),
            ]),
        // jakobfigur/apple-mail-mcp: AppleScript; search looks at the newest 300 messages of one mailbox.
        BenchServer(
            key: "jakobfigur", title: "jakobfigur 0.6.2", command: ["npx", "-y", "@jakobf1/apple-mail-mcp@0.6.2"], runs: otherRuns,
            calls: [
                "List accounts": Call(tool: "list_accounts", arguments: [:]),
                "Latest 20 inbox messages": Call(tool: "list_messages", arguments: ["account": name, "mailbox": box, "limit": 20]),
                "Subject search (inbox)": Call(tool: "search_messages", arguments: ["account": name, "mailbox": box, "query": "invoice", "limit": 20]),
                "Sender search (inbox)": Call(tool: "search_messages", arguments: ["account": name, "mailbox": box, "query": "github", "limit": 20]),
                "Inbox overview": Call(tool: "get_daily_briefing", arguments: ["account": name, "mailbox": box]),
            ]),
        // jayvee6/apple-mail-mcp: AppleScript.
        BenchServer(
            key: "jayvee6", title: "jayvee6 0.1.0", command: ["npx", "-y", "@jdot6/apple-mail-mcp@0.1.0"], runs: otherRuns,
            calls: [
                "List accounts": Call(tool: "list_folders", arguments: [:]),
                "Latest 20 inbox messages": Call(tool: "list_emails", arguments: ["account": name, "mailbox": box, "limit": 20]),
                "Subject search (inbox)": Call(tool: "search_emails", arguments: ["account": name, "mailbox": box, "subject_filter": "invoice", "limit": 20]),
                "Subject search (all mailboxes)": Call(tool: "search_emails", arguments: ["account": name, "mailbox": "ALL", "subject_filter": "invoice", "limit": 20]),
                "Sender search (inbox)": Call(tool: "search_emails", arguments: ["account": name, "mailbox": box, "from_filter": "github", "limit": 20]),
            ]),
        // kiki830621/che-apple-mail-mcp: Swift; Envelope Index SQLite for search, AppleScript for the rest.
        BenchServer(
            key: "kiki830621", title: "kiki830621 2.0.1", command: ["\(dir)/CheAppleMailMCP"], runs: otherRuns,
            calls: [
                "List accounts": Call(tool: "list_accounts", arguments: [:]),
                "Unread counts per mailbox": Call(tool: "list_mailboxes", arguments: ["account_name": name]),
                "Latest 20 inbox messages": Call(tool: "list_emails", arguments: ["account_name": name, "mailbox": box, "limit": 20]),
                "Subject search (inbox)": Call(tool: "search_emails", arguments: ["query": "invoice", "field": "subject", "account_name": name, "mailbox": box, "limit": 20]),
                "Subject search (all mailboxes)": Call(tool: "search_emails", arguments: ["query": "invoice", "field": "subject", "account_name": name, "limit": 20]),
                "Sender search (inbox)": Call(tool: "search_emails", arguments: ["query": "github", "field": "sender", "account_name": name, "mailbox": box, "limit": 20]),
            ]),
        // mgcrea/mcp-apple-mail: TypeScript; Mail's Envelope Index for search, Apple Events for the rest. Writes off by default.
        BenchServer(
            key: "mgcrea", title: "mgcrea 1.28.0", command: ["npx", "-y", "@mgcrea/mcp-apple-mail@1.28.0"], runs: otherRuns,
            calls: [
                "List accounts": Call(tool: "apple_mail_list_accounts", arguments: [:]),
                "Unread counts per mailbox": Call(tool: "apple_mail_list_mailboxes", arguments: ["account": name, "withCounts": true]),
                "Latest 20 inbox messages": Call(tool: "apple_mail_list_messages", arguments: ["account": name, "mailbox": box, "limit": 20]),
                "Subject search (inbox)": Call(tool: "apple_mail_search_messages", arguments: ["subject": "invoice", "account": name, "mailbox": box, "limit": 20]),
                "Subject search (all mailboxes)": Call(tool: "apple_mail_search_messages", arguments: ["subject": "invoice", "account": name, "limit": 20]),
                "Sender search (inbox)": Call(tool: "apple_mail_search_messages", arguments: ["sender": "github", "account": name, "mailbox": box, "limit": 20]),
                "Body text search (inbox)": Call(tool: "apple_mail_search_messages", arguments: ["body": "kubernetes", "account": name, "mailbox": box, "limit": 10]),
                "Conversation thread": Call(tool: "apple_mail_get_thread", arguments: [:]) { server in
                    let found = await server.call(
                        "apple_mail_search_messages", ["subject": .string(threadKeyword), "account": name, "mailbox": box, "limit": 1], timeout: timeout)
                    return firstMatch(#""ref"\s*:\s*"([^"]+)""#, in: found.text).map { ["ref": .string($0)] }
                },
                "Top senders, 30 days": Call(
                    tool: "apple_mail_query", arguments: ["account": name, "mailbox": box, "dateFrom": since30, "groupBy": "sender", "limit": 20]),
            ]),
        // parasxos/apple-mail-mcp: Python; Envelope Index plus its own FTS index of bodies (`fts --build` first).
        BenchServer(
            key: "parasxos", title: "parasxos 1.8.0", command: ["uvx", "--from", "apple-mailbox-mcp@1.8.0", "apple-mailbox-mcp"], runs: otherRuns,
            calls: [
                "Unread counts per mailbox": Call(tool: "list_mailboxes", arguments: [:]),
                "Latest 20 inbox messages": Call(tool: "list_recent", arguments: ["account": uuid, "mailbox": box, "limit": 20]),
                "Subject search (inbox)": Call(tool: "search_emails", arguments: ["query": "invoice", "account": uuid, "mailbox": box, "limit": 20]),
                "Subject search (all mailboxes)": Call(tool: "search_emails", arguments: ["query": "invoice", "account": uuid, "limit": 20]),
                "Sender search (inbox)": Call(tool: "search_emails", arguments: ["from_addr": "github", "account": uuid, "mailbox": box, "limit": 20]),
                "Body text search (inbox)": Call(tool: "search_emails", arguments: ["query": "kubernetes", "account": uuid, "mailbox": box, "limit": 10]),
                "Conversation thread": Call(tool: "get_thread", arguments: [:]) { server in
                    let found = await server.call(
                        "search_emails", ["query": .string(threadKeyword), "account": uuid, "mailbox": box, "limit": 1], timeout: timeout)
                    return firstMatch(#""thread_id"\s*:\s*"([^"]+)""#, in: found.text).map { ["thread_id": .string($0)] }
                },
            ]),
        // The Python apple-mail-mcp on PyPI (mcp-apple-mail): AppleScript.
        BenchServer(
            key: "python", title: "mcp-apple-mail (Python)",
            command: options.string("python", "uvx mcp-apple-mail --read-only").split(separator: " ").map(String.init), runs: otherRuns,
            calls: [
                "List accounts": Call(tool: "list_accounts", arguments: [:]),
                "Unread counts per mailbox": Call(tool: "get_mailbox_unread_counts", arguments: ["account": name]),
                "Latest 20 inbox messages": Call(tool: "list_inbox_emails", arguments: ["account": name, "max_emails": 20]),
                "Subject search (inbox)": Call(tool: "search_emails", arguments: ["account": name, "subject_keyword": "invoice", "max_results": 20]),
                "Subject search (all mailboxes)": Call(
                    tool: "search_emails", arguments: ["account": name, "subject_keyword": "invoice", "mailbox": "All", "max_results": 20]),
                "Sender search (inbox)": Call(tool: "search_emails", arguments: ["account": name, "sender": "github", "max_results": 20]),
                "Body text search (inbox)": Call(tool: "search_emails", arguments: ["account": name, "body_text": "kubernetes", "max_results": 10]),
                "Conversation thread": Call(tool: "get_email_thread", arguments: ["account": name, "subject_keyword": .string(threadKeyword)]),
                "Top senders, 30 days": Call(tool: "get_top_senders", arguments: ["account": name, "days_back": 30]),
                "Statistics, 30 days": Call(tool: "get_statistics", arguments: ["account": name, "days_back": 30]),
                "Awaiting reply, 7 days": Call(tool: "get_awaiting_reply", arguments: ["account": name, "days_back": 7]),
                "Needs response, 7 days": Call(tool: "get_needs_response", arguments: ["account": name, "days_back": 7]),
                "Inbox overview": Call(tool: "get_inbox_overview", arguments: [:]),
            ]),
    ]
    // On generated mail, or with --fresh-index, our server gets a body index of its own in a temporary folder, built
    // before the run under a throwaway key (keyed hashes only, like the real one) and deleted afterwards: no Keychain
    // prompt can hold up an unattended run. Its settings there are the defaults. On generated mail, only the servers
    // that can be pointed at another Mail folder take part; the others read ~/Library/Mail or ask the Mail app (imdinu
    // resolves accounts through JXA even with its folder moved).
    let benchState = FileManager.default.temporaryDirectory.appending(path: "bench-\(UUID().uuidString)")
    let ownIndex = testMailRoot != nil || options.values["fresh-index"] != nil
    if ownIndex, let index = allServers.firstIndex(where: { $0.key == "ours" }) {
        let support = benchState.appending(path: "support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        allServers[index].environment["APPLE_MAIL_MCP_SUPPORT_DIR"] = support.path
        allServers[index].environment["APPLE_MAIL_MCP_TEST_INDEX_KEY"] = BodyIndexKey.random().hex
        allServers[index].prepare = [serverPath, "index"]
    }
    defer { try? FileManager.default.removeItem(at: benchState) }
    if let testMailRoot, let index = allServers.firstIndex(where: { $0.key == "parasxos" }) {
        allServers[index].environment = ["EMAIL_MCP_MAIL_DIR": testMailRoot, "EMAIL_MCP_STATE_DIR": benchState.appending(path: "parasxos").path]
        allServers[index].prepare = ["uvx", "--from", "apple-mailbox-mcp@1.8.0", "apple-mailbox-mcp", "fts", "--build"]
        allServers.removeAll { !["ours", "ours-noindex", "parasxos"].contains($0.key) }
    }
    let selected = options.values["servers"].map { Set($0.split(separator: ",").map(String.init)) }
    let servers = allServers.filter { selected == nil || selected!.contains($0.key) || $0.key.hasPrefix("ours") }
    let only = options.values["only"].map { Set($0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }) }

    struct Cell { var samples: [Double] = []; var bytes: [Int] = []; var failure: String?; var note: String? }
    var cells: [String: [String: Cell]] = [:]  // server key → scenario → cell
    var notes: [String] = []

    // Servers that read Mail's files are measured together, in turns: for each question every one of them is
    // called once per round, so a change in the machine's load hits them all alike instead of whichever one was
    // running then. Those that drive Mail with AppleScript go last, one at a time: when one leaves Mail stuck, it
    // can no longer spoil the numbers of the others.
    let appleScriptHeavy = ["kiki830621", "ipsupport", "jakobfigur", "jayvee6", "python"]
    let groups = [servers.filter { !appleScriptHeavy.contains($0.key) }] + servers.filter { appleScriptHeavy.contains($0.key) }.map { [$0] }

    final class Runner {
        let server: BenchServer
        var process: MCPProcess
        var timeoutsInARow = 0
        init(server: BenchServer, process: MCPProcess) {
            self.server = server
            self.process = process
        }
    }

    for group in groups where !group.isEmpty {
        var runners: [Runner] = []
        for server in group {
            FileHandle.standardError.write(Data("starting \(server.title)\n".utf8))
            if let prepare = server.prepare, !runPreparation(prepare, environment: server.environment) {
                notes.append("\(server.title): preparing (\(prepare.joined(separator: " "))) failed")
            }
            do {
                runners.append(Runner(
                    server: server,
                    process: try await MCPProcess(label: server.key, command: server.command, environment: server.environment)))
            } catch {
                notes.append("\(server.title): did not start (\(String("\(error)".prefix(120))))")
            }
        }
        for scenario in scenarioNames where only?.contains(scenario) ?? true {
            // Per server: its arguments and a warm-up call (first-call caches, index catch-up, Mail waking up).
            var active: [(runner: Runner, call: Call, arguments: [String: Value])] = []
            for runner in runners {
                let server = runner.server
                guard let call = server.calls[scenario] else { continue }
                var cell = Cell()
                if runner.timeoutsInARow >= 2 {
                    cell.failure = "skipped"
                    cell.note = "skipped after two timeouts in a row"
                    cells[server.key, default: [:]][scenario] = cell
                    continue
                }
                var arguments = call.arguments
                if let prepare = call.prepare {
                    guard let found = await prepare(runner.process) else {
                        cell.failure = "error"
                        cell.note = "found no message ref to ask for"
                        cells[server.key, default: [:]][scenario] = cell
                        continue
                    }
                    arguments.merge(found) { $1 }
                }
                let warm = await runner.process.call(call.tool, arguments, timeout: timeout)
                if !warm.ok, warm.note?.hasPrefix("timeout") == true {
                    cell.failure = "timeout"
                    cell.note = warm.note
                }
                cells[server.key, default: [:]][scenario] = cell
                if cell.failure == nil { active.append((runner, call, arguments)) }
            }
            // Timed rounds, every server once per round.
            for round in 0..<(active.map(\.runner.server.runs).max() ?? 0) {
                for (runner, call, arguments) in active where round < runner.server.runs {
                    let key = runner.server.key
                    guard cells[key]?[scenario]?.failure == nil else { continue }
                    let r = await runner.process.call(call.tool, arguments, timeout: timeout)
                    if r.ok {
                        cells[key]?[scenario]?.samples.append(r.ms)
                        cells[key]?[scenario]?.bytes.append(r.text.utf8.count)
                    } else {
                        cells[key]?[scenario]?.failure = r.note?.hasPrefix("timeout") == true ? "timeout" : "error"
                        cells[key]?[scenario]?.note = r.note ?? "error"
                    }
                }
            }
            for runner in runners {
                let server = runner.server
                guard let cell = cells[server.key]?[scenario] else { continue }
                if let note = cell.note { notes.append("\(scenario), \(server.title): \(note)") }
                if cell.failure != "skipped" { runner.timeoutsInARow = cell.failure == "timeout" ? runner.timeoutsInARow + 1 : 0 }
                if cell.failure == "timeout" {
                    // The server may still be busy with the abandoned call: start a fresh one.
                    await runner.process.stop()
                    if let fresh = try? await MCPProcess(label: server.key, command: server.command, environment: server.environment) {
                        runner.process = fresh
                    } else {
                        runner.timeoutsInARow = 2  // it did not come back: skip the rest of its questions
                    }
                }
                let size = cell.bytes.isEmpty ? "" : " · \(cell.bytes.max()! / 1024) KB"
                // The server's error message (a timeout, an Apple Event error), never a result.
                let why = cell.note.map { " (\($0.prefix(120)))" } ?? ""
                let shown = cell.samples.isEmpty ? cell.failure ?? "–" : format(median(cell.samples))
                FileHandle.standardError.write(Data("  \(scenario), \(server.title): \(shown)\(size)\(why)\n".utf8))
            }
        }
        for runner in runners { await runner.process.stop() }
    }

    func cellText(_ server: BenchServer, _ scenario: String, _ value: (Cell) -> String) -> String {
        guard server.calls[scenario] != nil, let cell = cells[server.key]?[scenario] else { return "–" }
        return cell.samples.isEmpty ? (cell.failure ?? "–") : value(cell)
    }
    let header = "| Operation | " + servers.map(\.title).joined(separator: " | ") + " |"
    let rule = "|---|" + String(repeating: "---:|", count: servers.count)
    var lines = [
        "## Apple Mail MCP vs other Apple Mail MCP servers",
        "",
        "Same questions over real MCP stdio sessions, account with \(accountMessages.formatted()) messages "
            + "(\(inboxMessages.formatted()) in its inbox). Median of \(runs) warm runs for Apple Mail MCP, \(otherRuns) for the others "
            + "(\(Int(timeout)) s timeout). Servers that read Mail's files are called in turns, one call each per round, "
            + "so they share the same conditions; those that use AppleScript run afterwards, one at a time. \(machineDescription()).",
        "",
        "– means the server has no tool for that question.",
        "",
        header, rule,
    ]
    for scenario in scenarioNames {
        lines.append("| \(scenario) | " + servers.map { cellText($0, scenario) { format(median($0.samples)) } }.joined(separator: " | ") + " |")
    }
    lines += ["", "### Response size", "", "What the client has to read (and the model to take in), in KB.", "", header, rule]
    for scenario in scenarioNames {
        lines.append("| \(scenario) | " + servers.map {
            cellText($0, scenario) { String(format: "%.1f", Double($0.bytes.max() ?? 0) / 1024) }
        }.joined(separator: " | ") + " |")
    }
    if !notes.isEmpty { lines += ["", "Notes:"] + Array(Set(notes)).sorted().map { "- \($0)" } }
    return lines.joined(separator: "\n")
}

// MARK: Main

let options = Options(CommandLine.arguments)
var report: String
switch options.command {
case "store":
    let store = try MailStore.open()
    let index = BodyIndex.openIfPresent(url: SharedPaths.bodyIndex)
    let count = try store.messageCount()
    report = "## In-process timings on a real mailbox (\(count.formatted()) messages)\n\n\(machineDescription())\n\n"
        + (try runStoreBenchmarks(store: store, index: index, runs: options.int("runs", 9), title: "MailStore"))

case "synthetic":
    let size = options.int("messages", 100_000)
    FileHandle.standardError.write(Data("Generating \(size) messages…\n".utf8))
    var start = DispatchTime.now().uptimeNanoseconds
    let fixture = try SyntheticCorpus.make(messages: size)
    defer { fixture.remove() }
    let generated = milliseconds(since: start)
    let store = try MailStore(location: fixture.location)
    // Generated mail, thrown away afterwards: a throwaway key, not the Keychain's.
    let key = BodyIndexKey.random()
    let index = try BodyIndex(url: fixture.directory.appending(path: "body-index.sqlite"), key: { key })
    start = DispatchTime.now().uptimeNanoseconds
    let built = try index.update(from: store)
    let indexTime = milliseconds(since: start)
    let size_mb = Double(try index.status().sizeBytes) / 1_048_576
    report = """
        ## Synthetic mailbox: \(size.formatted()) messages

        \(machineDescription())

        Generated in \(format(generated)); body index of \(built.indexed.formatted()) messages built in \(format(indexTime)) \
        (\(String(format: "%.0f", size_mb)) MB, \(String(format: "%.0f", Double(built.indexed) / max(indexTime / 1000, 0.001))) messages/s).


        """ + (try runStoreBenchmarks(
            store: store, index: index, runs: options.int("runs", 9), title: "MailStore",
            extra: [mailWriteScenario(store: store)]))

case "compare":
    do {
        report = try await runComparison(options: options)
    } catch {
        // Most often no Full Disk Access: say so instead of crashing.
        FileHandle.standardError.write(Data("mail-bench: \(error)\n".utf8))
        exit(1)
    }

case "demo":
    // A fictional mailbox, activity log and pending approval for screenshots:
    //   mail-bench demo DIR, then run the app with the printed environment.
    let folder = URL(filePath: options.string("dir", FileManager.default.temporaryDirectory.appending(path: "apple-mail-mcp-demo").path))
    try? FileManager.default.removeItem(at: folder)
    let fixture = try SyntheticCorpus.make(messages: options.int("messages", 4_200), directory: folder.appending(path: "data"))
    let support = folder.appending(path: "support")
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    var settings = Settings()
    settings.sendPolicy = .confirm
    try settings.save(to: support.appending(path: "settings.json"))
    let store = try MailStore(location: fixture.location)
    try BodyIndex(url: support.appending(path: "body-index.sqlite")).update(from: store)
    let log = ActivityLog(url: support.appending(path: "activity.jsonl"))
    let entries: [(String, String, Int, Bool, Bool, Double)] = [
        ("inbox_overview", "38 unread", 41, true, false, 1500),
        ("needs_response", "6 need a response", 22, true, false, 1380),
        ("get_thread", "4 in thread", 35, true, false, 1200),
        ("search_messages", "12 results", 18, true, false, 1100),
        ("get_message", "message 3141", 9, true, false, 960),
        ("reply_to_message", "reply draft: Re: Q3 roadmap review", 2400, true, true, 900),
        ("search_messages", "57 results", 61, true, false, 600),
        ("move_messages", "moved 25 to Archive", 3100, true, true, 540),
        ("top_senders", "15 senders", 12, true, false, 300),
        ("save_attachment", "saved 1 attachment(s)", 14, true, true, 180),
        ("awaiting_reply", "4 awaiting reply", 47, true, false, 90),
        ("search_messages", "3 results", 44, true, false, 20),
    ]
    let messageTools: Set<String> = ["get_thread", "get_message", "reply_to_message", "move_messages", "save_attachment"]
    for (tool, summary, ms, ok, write, ago) in entries {
        log.append(ActivityEntry(
            date: Date().addingTimeInterval(-ago), pid: 4242, client: "claude-code", tool: tool, ok: ok,
            milliseconds: ms, summary: summary, isWrite: write,
            link: messageTools.contains(tool) ? "message://%3Cdemo-\(Int(ago))@northwind.test%3E" : nil))
    }
    let approvals = ApprovalCenter(directory: support.appending(path: "approvals"), heartbeat: support.appending(path: "agent.heartbeat"))
    if options.values["approval"] != nil {
        for (subject, to) in [("Follow-up: contract signature", "dan@acme.test"), ("Fwd: Invoice 42", "accounting@studio.test")]
        where options.int("approval", 1) > 1 {
            try approvals.submit(ApprovalRequest(
                id: UUID(), created: Date().addingTimeInterval(1), tool: "forward_message", client: "claude-code", from: nil,
                to: [to], cc: [], bcc: [], subject: subject, bodyPreview: "FYI, see below.", attachments: [],
                status: .pending, decided: nil))
        }
        try approvals.submit(ApprovalRequest(
            id: UUID(), created: Date().addingTimeInterval(-5), tool: "reply_to_message", client: "claude-code", from: nil,
            to: ["anna.keller@northwind.test"], cc: ["tom@northwind.test"], bcc: [], subject: "Re: Q3 roadmap review",
            bodyPreview: "Hi Anna,\n\nThanks for the deck. The timeline works for us; I'd move the API migration to week 34 so it lands after the security review. I'll send the updated estimates by Friday.\n\nBest,\nSam",
            attachments: ["estimates-q3.xlsx"], status: .pending, decided: nil,
            originalLink: "message://%3Croadmap@northwind.test%3E"))
    }
    report = """
        Demo data in \(folder.path). Run the app with:
        APPLE_MAIL_MCP_MAIL_ROOT='\(fixture.root.path)' APPLE_MAIL_MCP_ACCOUNTS_DB='\(fixture.accountsDatabase.path)' APPLE_MAIL_MCP_SUPPORT_DIR='\(support.path)'
        """

default:
    FileHandle.standardError.write(Data("usage: mail-bench [store|synthetic|compare] [options]\n".utf8))
    exit(2)
}

print(report)
if let out = options.values["out"] {
    try Data((report + "\n").utf8).write(to: URL(filePath: out))
}
