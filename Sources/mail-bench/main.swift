import Foundation
import MCP
import MailFixtures
import MailMCPKit
import MailStore
import System

// Benchmarks for apple-mail-mcp. Prints timings and counts only, never message content.
//
//   mail-bench compare [--python "uvx mcp-apple-mail"] [--server PATH] [--account NAME] [--runs N] [--out FILE]
//       The same questions to this server and to the Python apple-mail-mcp, over real MCP stdio sessions.
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
            values[String(key.dropFirst(2))] = rest.first.map { String($0) } ?? ""
            rest = rest.dropFirst()
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

func runStoreBenchmarks(store: MailStore, index: BodyIndex?, runs: Int, title: String) throws -> String {
    let inbox = try store.mailboxes().filter { $0.role == .inbox }.map(\.id)
    var latest = MessageQuery()
    latest.limit = 200
    var threadID: Int64?
    for message in try store.search(latest).messages where try store.thread(of: message.id).count >= 3 {
        threadID = message.id
        break
    }
    var lines = ["### \(title)", "", "| Operation | Median | Min | Max |", "|---|---:|---:|---:|"]
    for scenario in storeScenarios(store: store, index: index, inbox: inbox, threadID: threadID) {
        _ = try? scenario.run()  // warm-up
        let samples = try measure(runs: runs, scenario.run)
        lines.append("| \(scenario.name) | \(format(median(samples))) | \(format(samples.min() ?? .nan)) | \(format(samples.max() ?? .nan)) |")
        FileHandle.standardError.write(Data("  \(scenario.name): \(format(median(samples)))\n".utf8))
    }
    return lines.joined(separator: "\n")
}

// MARK: MCP comparison

/// An MCP client talking to a server subprocess over stdio.
final class MCPProcess {
    let process = Process()
    let client: Client
    let label: String

    init(label: String, command: [String], environment: [String: String] = [:]) async throws {
        self.label = label
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = command
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle(forWritingAtPath: "/dev/null")
        var env = ProcessInfo.processInfo.environment
        env["APPLE_MAIL_MCP_NO_ACTIVITY"] = "1"  // keep benchmark calls out of the user's Activity
        for (key, value) in environment { env[key] = value }
        process.environment = env
        try process.run()
        let transport = StdioTransport(
            input: FileDescriptor(rawValue: output.fileHandleForReading.fileDescriptor),
            output: FileDescriptor(rawValue: input.fileHandleForWriting.fileDescriptor))
        client = Client(name: "mail-bench", version: "1.0")
        _ = try await client.connect(transport: transport)
    }

    /// Calls a tool with a client-side timeout. Returns elapsed ms and whether it succeeded.
    func call(_ tool: String, _ arguments: [String: Value], timeout: TimeInterval) async -> (ms: Double, ok: Bool, note: String?) {
        let start = DispatchTime.now().uptimeNanoseconds
        let client = self.client
        let result = await withTaskGroup(of: (Bool, String?)?.self) { group in
            group.addTask {
                do {
                    let (content, isError) = try await client.callTool(name: tool, arguments: arguments)
                    var text = ""
                    if case .text(let t, _, _) = content.first { text = t }
                    let looksLikeError = isError == true || text.hasPrefix("Error") || text.contains("timed out")
                    return (!looksLikeError, looksLikeError ? String(text.prefix(300)) : nil)
                } catch {
                    return (false, "\(error)".prefix(80).description)
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        let ms = milliseconds(since: start)
        guard let result else { return (ms, false, "timeout after \(Int(timeout)) s") }
        return (ms, result.0, result.1)
    }

    func stop() {
        process.terminate()
    }
}

struct Comparison {
    var name: String
    var swiftTool: String
    var swiftArguments: [String: Value]
    var pythonTool: String
    var pythonArguments: [String: Value]
}

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
    let timeout = Double(options.int("timeout", 240))

    let scenarios: [Comparison] = [
        Comparison(name: "List accounts", swiftTool: "list_accounts", swiftArguments: [:], pythonTool: "list_accounts", pythonArguments: [:]),
        Comparison(
            name: "Unread counts per mailbox", swiftTool: "list_mailboxes", swiftArguments: ["account": .string(account.name)],
            pythonTool: "get_mailbox_unread_counts", pythonArguments: ["account": .string(account.name)]),
        Comparison(
            name: "Latest 20 inbox messages", swiftTool: "search_messages",
            swiftArguments: ["account": .string(account.name), "mailbox": "inbox", "limit": 20],
            pythonTool: "list_inbox_emails", pythonArguments: ["account": .string(account.name), "max_emails": 20]),
        Comparison(
            name: "Subject search (inbox)", swiftTool: "search_messages",
            swiftArguments: ["account": .string(account.name), "mailbox": "inbox", "subject": "invoice", "limit": 20],
            pythonTool: "search_emails", pythonArguments: ["account": .string(account.name), "subject_keyword": "invoice", "max_results": 20]),
        Comparison(
            name: "Subject search (all mailboxes)", swiftTool: "search_messages",
            swiftArguments: ["account": .string(account.name), "subject": "invoice", "limit": 20],
            pythonTool: "search_emails",
            pythonArguments: ["account": .string(account.name), "subject_keyword": "invoice", "mailbox": "All", "max_results": 20]),
        Comparison(
            name: "Sender search (inbox)", swiftTool: "search_messages",
            swiftArguments: ["account": .string(account.name), "mailbox": "inbox", "sender": "github", "limit": 20],
            pythonTool: "search_emails", pythonArguments: ["account": .string(account.name), "sender": "github", "max_results": 20]),
        Comparison(
            name: "Body text search (inbox)", swiftTool: "search_messages",
            swiftArguments: ["account": .string(account.name), "mailbox": "inbox", "body": "kubernetes", "limit": 10],
            pythonTool: "search_emails", pythonArguments: ["account": .string(account.name), "body_text": "kubernetes", "max_results": 10]),
        Comparison(
            name: "Conversation thread", swiftTool: "get_thread", swiftArguments: ["id": .int(Int(thread?.id ?? 0))],
            pythonTool: "get_email_thread", pythonArguments: ["account": .string(account.name), "subject_keyword": .string(threadKeyword)]),
        Comparison(
            name: "Top senders, 30 days", swiftTool: "top_senders",
            swiftArguments: ["account": .string(account.name), "mailbox": "inbox", "days": 30],
            pythonTool: "get_top_senders", pythonArguments: ["account": .string(account.name), "days_back": 30]),
        Comparison(
            name: "Statistics, 30 days", swiftTool: "mail_statistics", swiftArguments: ["account": .string(account.name), "days": 30],
            pythonTool: "get_statistics", pythonArguments: ["account": .string(account.name), "days_back": 30]),
        Comparison(
            name: "Awaiting reply, 7 days", swiftTool: "awaiting_reply", swiftArguments: ["account": .string(account.name), "days": 7],
            pythonTool: "get_awaiting_reply", pythonArguments: ["account": .string(account.name), "days_back": 7]),
        Comparison(
            name: "Needs response, 7 days", swiftTool: "needs_response", swiftArguments: ["account": .string(account.name), "days": 7],
            pythonTool: "get_needs_response", pythonArguments: ["account": .string(account.name), "days_back": 7]),
        Comparison(name: "Inbox overview", swiftTool: "inbox_overview", swiftArguments: [:], pythonTool: "get_inbox_overview", pythonArguments: [:]),
    ]

    let serverPath = options.string("server", ".build/release/apple-mail-mcp")
    let pythonCommand = options.string("python", "uvx mcp-apple-mail --read-only").split(separator: " ").map(String.init)
    let emptySupport = FileManager.default.temporaryDirectory.appending(path: "bench-noindex-\(UUID().uuidString)").path

    struct Row { var swiftIndex: [Double] = []; var swiftScan: [Double] = []; var python: [Double] = []; var notes: [String] = [] }
    var rows = Array(repeating: Row(), count: scenarios.count)

    FileHandle.standardError.write(Data("Starting servers…\n".utf8))
    let swiftIndexed = try await MCPProcess(label: "swift", command: [serverPath, "--read-only"])
    let swiftScan = try await MCPProcess(
        label: "swift-noindex", command: [serverPath, "--read-only"], environment: ["APPLE_MAIL_MCP_SUPPORT_DIR": emptySupport])
    let python = options.values["python"] == "none" ? nil : try await MCPProcess(label: "python", command: pythonCommand)
    defer {
        swiftIndexed.stop()
        swiftScan.stop()
        python?.stop()
    }

    let only = options.values["only"].map { Set($0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }) }
    for (index, scenario) in scenarios.enumerated() {
        if let only, !only.contains(scenario.name) { continue }
        FileHandle.standardError.write(Data("\(scenario.name)\n".utf8))
        // Warm-up call per server, not timed (first-call caches, Mail wake-up).
        _ = await swiftIndexed.call(scenario.swiftTool, scenario.swiftArguments, timeout: timeout)
        _ = await swiftScan.call(scenario.swiftTool, scenario.swiftArguments, timeout: timeout)
        for _ in 0..<runs {
            let a = await swiftIndexed.call(scenario.swiftTool, scenario.swiftArguments, timeout: timeout)
            if a.ok { rows[index].swiftIndex.append(a.ms) } else if let note = a.note { rows[index].notes.append("swift: \(note)") }
            let b = await swiftScan.call(scenario.swiftTool, scenario.swiftArguments, timeout: timeout)
            if b.ok { rows[index].swiftScan.append(b.ms) }
        }
        if let python {
            let pythonRuns = max(1, min(runs, options.int("python-runs", 2)))
            for _ in 0..<pythonRuns {
                let c = await python.call(scenario.pythonTool, scenario.pythonArguments, timeout: timeout)
                if c.ok {
                    rows[index].python.append(c.ms)
                } else {
                    rows[index].notes.append("python: \(c.note ?? "error")")
                    if c.note?.hasPrefix("timeout") == true { break }
                }
            }
        }
        let r = rows[index]
        FileHandle.standardError.write(Data("  swift \(format(median(r.swiftIndex))) · no index \(format(median(r.swiftScan))) · python \(format(median(r.python)))\n".utf8))
    }

    var lines = [
        "## apple-mail-mcp (Swift) vs Python apple-mail-mcp",
        "",
        "Same questions over real MCP stdio sessions, account with \(accountMessages.formatted()) messages (\(inboxMessages.formatted()) in its inbox).",
        "Median of \(runs) warm runs for Swift, \(max(1, min(runs, options.int("python-runs", 2)))) for Python (\(Int(timeout)) s timeout). \(machineDescription()).",
        "",
        "| Operation | Swift | Swift, no body index | Python (AppleScript) | Speed-up |",
        "|---|---:|---:|---:|---:|",
    ]
    for (index, scenario) in scenarios.enumerated() {
        let r = rows[index]
        let s = median(r.swiftIndex), p = median(r.python)
        let speedup = (s.isNaN || p.isNaN) ? (r.python.isEmpty && !r.notes.filter { $0.hasPrefix("python") }.isEmpty ? "Python failed" : "–") : String(format: "%.0f×", p / s)
        let pythonCell = r.python.isEmpty ? (r.notes.first { $0.hasPrefix("python") }.map { $0.contains("timeout") ? "timeout" : "error" } ?? "–") : format(p)
        lines.append("| \(scenario.name) | \(format(s)) | \(format(median(r.swiftScan))) | \(pythonCell) | \(speedup) |")
    }
    let notes = rows.enumerated().flatMap { index, row in row.notes.map { "- \(scenarios[index].name): \($0)" } }
    if !notes.isEmpty { lines += ["", "Notes:"] + Array(Set(notes)).sorted() }
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


        """ + (try runStoreBenchmarks(store: store, index: index, runs: options.int("runs", 9), title: "MailStore"))

case "compare":
    report = try await runComparison(options: options)

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
