import Foundation
import MCP
import Testing

@testable import MailMCPKit

@Suite("Path guard")
struct PathGuardTests {
    let home: String
    let guardian: PathGuard

    init() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "home-\(UUID().uuidString)").path
        for sub in ["Downloads", ".ssh", "Library/LaunchAgents", "Library/Mail/V10", "code/.git/hooks", "Documents"] {
            try FileManager.default.createDirectory(atPath: home + "/" + sub, withIntermediateDirectories: true)
        }
        FileManager.default.createFile(atPath: home + "/.ssh/id_ed25519", contents: Data("key".utf8))
        FileManager.default.createFile(atPath: home + "/Documents/report.pdf", contents: Data("pdf".utf8))
        FileManager.default.createFile(atPath: home + "/Documents/.env", contents: Data("SECRET=1".utf8))
        guardian = PathGuard(home: home)
    }

    @Test func writesAllowedInOrdinaryFolders() throws {
        #expect(try guardian.checkWrite(home + "/Downloads").hasSuffix("/Downloads"))
        #expect(try guardian.checkWrite(home + "/Downloads/new/folder/file.txt").hasSuffix("/new/folder/file.txt"))
    }

    @Test func writesRefusedInDangerousPlaces() {
        for path in [
            "/.zshrc", "/.ssh/authorized_keys", "/Library/LaunchAgents/x.plist", "/code/.git/hooks/pre-commit",
            "/Downloads/../.zprofile", "/Library/Mail/V10/x", "/project/.envrc",
            "/Library/Python/3.9/lib/python/site-packages/evil.pth", "/Downloads/hook.pth", "/code/.husky/pre-commit",
            "/code/.vscode/tasks.json", "/Downloads/libx.dylib",
        ] {
            #expect(throws: PathGuard.Denied.self, "\(path)") { try guardian.checkWrite(home + path) }
        }
        #expect(throws: PathGuard.Denied.self) { try guardian.checkWrite("/etc/hosts") }
        #expect(throws: PathGuard.Denied.self) { try guardian.checkWrite("/usr/local/bin/tool") }
    }

    @Test func symlinksCannotEscape() throws {
        let link = home + "/Downloads/sneaky"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: home + "/Library/LaunchAgents")
        #expect(throws: PathGuard.Denied.self) { try guardian.checkWrite(link + "/evil.plist") }
    }

    @Test func caseInsensitiveMatching() {
        #expect(throws: PathGuard.Denied.self) { try guardian.checkWrite(home + "/library/launchagents/x.plist") }
    }

    @Test func writeAllowlist() throws {
        let restricted = PathGuard(writeAllowlist: [home + "/Downloads"], home: home)
        #expect(throws: Never.self) { try restricted.checkWrite(home + "/Downloads/a.txt") }
        #expect(throws: PathGuard.Denied.self) { try restricted.checkWrite(home + "/Documents/a.txt") }
    }

    @Test func attachments() throws {
        #expect(try guardian.checkAttachment(home + "/Documents/report.pdf").hasSuffix("report.pdf"))
        for name in [".claude.json", ".zsh_history", ".config/tool/token"] {
            try FileManager.default.createDirectory(atPath: home + "/" + (name as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: home + "/" + name, contents: Data("secret".utf8))
        }
        for path in [
            "/.ssh/id_ed25519", "/Documents/.env", "/Library/Mail/V10", "/Documents/missing.pdf", "/Documents",
            "/.claude.json", "/.zsh_history", "/.config/tool/token", "/Library/Application Support/Claude/claude_desktop_config.json",
        ] {
            #expect(throws: PathGuard.Denied.self, "\(path)") { try guardian.checkAttachment(home + path) }
        }
        let restricted = PathGuard(attachAllowlist: [home + "/Downloads"], home: home)
        #expect(throws: PathGuard.Denied.self) { try restricted.checkAttachment(home + "/Documents/report.pdf") }
    }

    @Test func envVariantsAreSecrets() throws {
        for name in [".env.local", ".ENV.production"] {
            FileManager.default.createFile(atPath: home + "/Documents/" + name, contents: Data("SECRET=1".utf8))
            #expect(throws: PathGuard.Denied.self, "\(name)") { try guardian.checkAttachment(home + "/Documents/" + name) }
        }
        FileManager.default.createFile(atPath: home + "/Documents/.env.example", contents: Data("SECRET=".utf8))
        #expect(throws: Never.self) { try guardian.checkAttachment(home + "/Documents/.env.example") }
        #expect(!PathGuard.isEnvSecrets(".environment"))
    }
}

@Suite("Saved attachments")
struct SavedAttachmentTests {
    @Test func filenamesLoseSeparatorsControlAndBidiCharacters() {
        #expect(MailToolbox.safeFilename("../../.zshrc", fallback: "x") == "-..-.zshrc")
        #expect(MailToolbox.safeFilename("invoice\u{202E}fdp.app", fallback: "x") == "invoicefdp.app")
        #expect(MailToolbox.safeFilename("a\u{0}b\u{7F}c\u{200B}.pdf", fallback: "x") == "abc.pdf")
        #expect(MailToolbox.safeFilename("\u{202E}", fallback: "attachment-2") == "attachment-2")
        #expect(MailToolbox.safeFilename(".hidden", fallback: "x") == "hidden")
    }

    @Test func savedFilesAreQuarantined() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "quarantine-\(UUID().uuidString).command")
        try Data("echo hi".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        MailToolbox.quarantine(file.path)
        let size = getxattr(file.path, "com.apple.quarantine", nil, 0, 0, 0)
        #expect(size > 0)
    }
}

@Suite("Arguments and JSON")
struct ArgumentTests {
    @Test func tolerantParsing() throws {
        let args = Arguments([
            "ids": .array([1, "2", 2, 3.0]), "csv": "a@x, b@y;c@z", "flag": "yes", "n": "12", "list": .array(["x", " "]),
            "day": "2026-03-04", "iso": "2026-03-04T10:00:00Z", "blank": "  ",
        ])
        #expect(try args.ids("ids") == [1, 2, 3])
        #expect(try args.strings("csv") == ["a@x", "b@y", "c@z"])
        #expect(try args.strings("list") == ["x"])
        #expect(try args.bool("flag") == true)
        #expect(try args.int("n") == 12)
        #expect(try args.string("blank") == nil)
        #expect(try args.string("missing") == nil)
        #expect(try args.date("iso") == ISO8601DateFormatter().date(from: "2026-03-04T10:00:00Z"))
        let start = try #require(try args.date("day"))
        let end = try #require(try args.date("day", endOfDay: true))
        #expect(end.timeIntervalSince(start) == 86_399)
        #expect(throws: ToolError.self) { try Arguments(["n": "x"]).int("n") }
        #expect(throws: ToolError.self) { try Arguments(["ids": .array(["abc"])]).ids("ids") }
        #expect(throws: ToolError.self) { try args.requiredString("missing") }
    }

    @Test func jsonKeepsOrderAndEscapes() {
        let json = JSON.obj([("id", .int(1)), ("skip", nil), ("text", .string("a\"b\\c\nd\u{1}é")), ("list", .array([.bool(true), .null]))])
        #expect(json.serialized() == #"{"id":1,"text":"a\"b\\c\nd\u0001é","list":[true,null]}"#)
        #expect(JSON.object([]).serialized() == "{}")
    }
}

@Suite("Settings, approvals and activity")
struct SharedStateTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "shared-\(UUID().uuidString)")

    @Test func settingsDecodeWithDefaults() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "settings.json")
        try Data(#"{"sendPolicy":"confirm","unknownKey":1}"#.utf8).write(to: url)
        let settings = Settings.load(from: url)
        #expect(settings.sendPolicy == .confirm)
        #expect(settings.allowMailChanges)
        #expect(settings.maxBatchSize == 50)
        #expect(Settings.load(from: directory.appending(path: "missing.json")) == Settings())
        #expect(Settings().sendPolicy == .confirm)
    }

    @Test func badSettingsFailClosed() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "settings.json")
        // One mistyped key costs only that key.
        try Data(#"{"sendPolicy":"confirm","maxBatchSize":"50"}"#.utf8).write(to: url)
        #expect(Settings.load(from: url).sendPolicy == .confirm)
        #expect(Settings.load(from: url).maxBatchSize == 50)
        // An unreadable safety switch blocks instead of allowing.
        try Data(#"{"sendPolicy":"sometimes","allowMailChanges":"yes"}"#.utf8).write(to: url)
        #expect(Settings.load(from: url).sendPolicy == .never)
        #expect(!Settings.load(from: url).allowMailChanges)
        // A broken file: nothing is sent or changed.
        try Data("{not json".utf8).write(to: url)
        #expect(Settings.load(from: url) == .failClosed)
    }

    @Test func settingsProviderKeepsLastGoodSettings() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "settings.json")
        var settings = Settings()
        settings.sendPolicy = .confirm
        try settings.save(to: url)
        let provider = SettingsProvider(url: url)
        #expect(provider.current.sendPolicy == .confirm)
        try Data("{trunc".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        #expect(provider.current.sendPolicy == .confirm)
    }

    @Test func settingsProviderAppliesOverridesAndReloads() throws {
        let url = directory.appending(path: "settings.json")
        var settings = Settings()
        settings.maxBatchSize = 5
        try settings.save(to: url)
        let provider = SettingsProvider(url: url) { $0.sendPolicy = .never }
        #expect(provider.current.maxBatchSize == 5)
        #expect(provider.current.sendPolicy == .never)
        settings.maxBatchSize = 9
        try settings.save(to: url)
        // Modification dates have one-second resolution on some file systems.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        #expect(provider.current.maxBatchSize == 9)
    }

    @Test func approvalTimesOut() async throws {
        let center = ApprovalCenter(directory: directory.appending(path: "approvals"), heartbeat: directory.appending(path: "hb"))
        #expect(!center.isAgentRunning())
        center.beat()
        #expect(center.isAgentRunning())
        let request = ApprovalRequest(
            id: UUID(), created: Date(), tool: "t", client: nil, from: nil, to: ["a@x"], cc: [], bcc: [], subject: "s",
            bodyPreview: "b", attachments: [], status: .pending, decided: nil)
        #expect(try await center.requestApproval(request, timeout: 0.3) == .pending)
        #expect(center.pending().isEmpty)  // cleaned up
    }

    @Test func activityLogRotatesAndReadsNewestFirst() throws {
        let log = ActivityLog(url: directory.appending(path: "activity.jsonl"), maxBytes: 600)
        for n in 0..<10 {
            log.append(ActivityEntry(date: Date(), pid: 1, client: "c", tool: "tool\(n)", ok: true, milliseconds: n, summary: "s", isWrite: false))
        }
        let recent = log.recent(limit: 3)
        #expect(recent.map(\.tool) == ["tool9", "tool8", "tool7"])
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "activity.jsonl.1").path))
    }

    @Test func activityLogReadsOnlyTheTailAndStampsChanges() throws {
        let log = ActivityLog(url: directory.appending(path: "activity.jsonl"), maxBytes: 10_000_000)
        let empty = log.stamp()
        // Enough lines that the first 32 KB window is too small for the limit.
        for n in 0..<600 {
            log.append(ActivityEntry(
                date: Date(), pid: 1, client: "c", tool: "tool\(n)", ok: true, milliseconds: n,
                summary: String(repeating: "s", count: 200), isWrite: false))
        }
        let stamp = log.stamp()
        #expect(stamp != empty)
        #expect(log.stamp() == stamp)
        #expect(log.recent(limit: 3).map(\.tool) == ["tool599", "tool598", "tool597"])
        let many = log.recent(limit: 500)
        #expect(many.count == 500)
        #expect(many.last?.tool == "tool100")
        #expect(log.recent(limit: 1000).count == 600)
        log.append(ActivityEntry(date: Date(), pid: 1, client: "c", tool: "last", ok: true, milliseconds: 0, summary: "", isWrite: false))
        #expect(log.stamp() != stamp)
    }

    @Test func heartbeatTouchesTheFile() throws {
        let center = ApprovalCenter(directory: directory.appending(path: "approvals"), heartbeat: directory.appending(path: "hb"))
        center.beat()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: center.heartbeat.path)
        #expect(!center.isAgentRunning())
        center.beat()
        #expect(center.isAgentRunning())
    }
}

@Suite("MCP protocol")
struct ProtocolTests {
    @Test func endToEndOverInMemoryTransport() async throws {
        let h = try Harness()
        defer { h.remove() }
        let server = await MailMCPServer.make(toolbox: h.toolbox)
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let toolbox = h.toolbox
        try await server.start(transport: serverTransport) { info, _ in toolbox.clientName = info.name }
        let client = Client(name: "test-client", version: "1.0")
        let initialized = try await client.connect(transport: clientTransport)
        #expect(initialized.serverInfo.name == "apple-mail")
        #expect(initialized.instructions?.contains("search_messages") == true)
        let (tools, _) = try await client.listTools()
        #expect(tools.count == h.toolbox.listedDefinitions.count)
        let (content, isError) = try await client.callTool(name: "search_messages", arguments: ["subject": "Invoice"])
        #expect(isError != true)
        guard case .text(let text, _, _) = content.first else {
            Issue.record("no text content")
            return
        }
        #expect(text.contains("\"subject\":\"Invoice 42\""))
        let (errorContent, errorFlag) = try await client.callTool(name: "get_message", arguments: ["id": 123_456])
        #expect(errorFlag == true)
        if case .text(let message, _, _) = errorContent.first { #expect(message.contains("No message with id 123456")) }
        #expect(h.toolbox.clientName == "test-client")
        let (prompts, _) = try await client.listPrompts()
        #expect(prompts.map(\.name) == SkillCatalog.all.map(\.name))
        let triage = try await client.getPrompt(name: "mail-triage", arguments: ["request": "only work mail"])
        guard case .text(let instructions) = triage.messages.first?.content else {
            Issue.record("no prompt text")
            return
        }
        #expect(instructions.hasPrefix("# Mail triage") && instructions.hasSuffix("only work mail"))
        #expect(!instructions.contains("name: mail-triage") && !instructions.contains(SkillCatalog.marker))
        await #expect(throws: (any Error).self) { _ = try await client.getPrompt(name: "nope") }
        await client.disconnect()
        await server.stop()
    }
}

@Suite("Full Disk Access guidance")
struct LaunchContextTests {
    @Test func namesTheBundleThatNeedsTheGrant() {
        let code = LaunchContext.describe(
            executable: "/Users/me/Library/Application Support/Claude/claude-code/2.1.299/4fa9/claude.app/Contents/MacOS/claude")
        #expect(code.name == "claude" && code.path.hasSuffix("/4fa9/claude.app") && !code.isThisServer)
        let helper = LaunchContext.describe(executable: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper")
        #expect(helper.name == "Visual Studio Code" && helper.path == "/Applications/Visual Studio Code.app")
        #expect(LaunchContext.describe(executable: "/usr/local/bin/node").name == "node")
    }

    @Test func messagesPointAtTheRightThing() {
        let code = LaunchContext.message(for: .init(name: "claude", path: "/x/claude-code/2.1/claude.app", isThisServer: false))
        #expect(code.hasPrefix("Can't read Apple Mail's data: macOS hasn't given Full Disk Access to claude,"))
        #expect(code.contains("not Claude.app") && code.contains("paste /x/claude-code/2.1/claude.app"))
        let server = LaunchContext.message(for: .init(name: "apple-mail-mcp", path: "/x/server/apple-mail-mcp", isThisServer: true))
        #expect(server.contains("Full Disk Access to apple-mail-mcp, this server") && server.contains("restart Claude"))
        let vscode = LaunchContext.message(for: .init(name: "Visual Studio Code", path: "/Applications/Visual Studio Code.app", isThisServer: false))
        #expect(!vscode.contains("Claude Code"))
    }

    @Test func findsTheResponsibleProcessForThisOne() {
        #expect(LaunchContext.responsible() != nil)
    }
}

@Suite("Full Disk Access notice")
struct FullDiskAccessNoticeTests {
    let now = Date()
    func entry(_ client: String?, minutesAgo: Double, ok: Bool, app: String = "claude") -> ActivityEntry {
        ActivityEntry(
            date: now.addingTimeInterval(-minutesAgo * 60), pid: 1, client: client, tool: "list_accounts", ok: ok,
            milliseconds: 3,
            summary: ok ? "2 accounts" : "Can't read Apple Mail's data: macOS hasn't given Full Disk Access to \(app), the app that started this server.",
            isWrite: false)
    }

    @Test func aLaterSuccessClearsTheNotice() {
        // The sequence seen on a real machine: failures, the grant, then a working call.
        let entries = [entry("Claude Code", minutesAgo: 15, ok: false), entry("Claude Code", minutesAgo: 7, ok: true)]
        #expect(ActivityEntry.appsLackingFullDiskAccess(in: entries, now: now).isEmpty)
    }

    @Test func aLatestFailureKeepsItPerClient() {
        let entries = [
            entry("Claude Code", minutesAgo: 20, ok: true), entry("Claude Code", minutesAgo: 2, ok: false),
            entry("local-agent-mode-Apple Mail", minutesAgo: 5, ok: false, app: "Claude"),
            entry("local-agent-mode-Apple Mail", minutesAgo: 1, ok: true, app: "Claude"),
        ]
        #expect(ActivityEntry.appsLackingFullDiskAccess(in: entries, now: now) == ["claude"])
    }

    @Test func oldFailuresAndOtherErrorsDoNotCount() {
        var other = entry("Claude Code", minutesAgo: 1, ok: false)
        other.summary = "No message with id 4."
        #expect(ActivityEntry.appsLackingFullDiskAccess(in: [entry(nil, minutesAgo: 90, ok: false), other], now: now).isEmpty)
        #expect(ActivityEntry.appName(inFullDiskAccessMessage: "macOS hasn't given Full Disk Access to apple-mail-mcp, this server") == "apple-mail-mcp")
    }
}

@Suite("Tool call fast path")
struct ToolCallFastPathTests {
    func line(_ json: String) -> Data { Data(json.utf8) }

    @Test func readsArgumentsAsTheSDKDoes() throws {
        let call = try #require(ToolCallFastPath.call(in: line(
            #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"search_messages","arguments":{"#
                + #""subject":"invoice","limit":20,"days":1.5,"unread":true,"ids":[1,2],"opts":{"a":null}}}}"#)))
        #expect(call.name == "search_messages")
        #expect(String(decoding: call.id, as: UTF8.self) == "7")
        // The SDK's own decoding of the same arguments.
        let viaSDK = try JSONDecoder().decode(
            [String: Value].self, from: line(#"{"subject":"invoice","limit":20,"days":1.5,"unread":true,"ids":[1,2],"opts":{"a":null}}"#))
        #expect(call.arguments == viaSDK)
        let noArguments = try #require(ToolCallFastPath.call(in: line(
            #"{"jsonrpc":"2.0","id":"abc","method":"tools/call","params":{"name":"list_accounts"}}"#)))
        #expect(noArguments.arguments == nil && String(decoding: noArguments.id, as: UTF8.self) == #""abc""#)
    }

    @Test func leavesEverythingElseToTheSDK() {
        for json in [
            #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":3,"reason":"tools/call"}}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"x","arguments":{"file":"data:text/plain;base64,aGk="}}}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"x","arguments":[1]}}"#,
            #"{"jsonrpc":"2.0","method":"tools/call","params":{"name":"x"}}"#,
            "not json tools/call",
        ] {
            #expect(ToolCallFastPath.call(in: line(json)) == nil, "\(json)")
        }
    }

    @Test func replyIsWhatTheSDKSends() throws {
        let call = try #require(ToolCallFastPath.call(in: line(
            #"{"jsonrpc":"2.0","id":42,"method":"tools/call","params":{"name":"list_accounts"}}"#)))
        let result = CallTool.Result(content: [.text(text: #"{"accounts":["Work"]}"#, annotations: nil, _meta: nil)], isError: true)
        let reply = try ToolCallFastPath.reply(to: call, result: result)
        let decoded = try JSONDecoder().decode(Response<CallTool>.self, from: reply)
        #expect(decoded.id == .number(42))
        let value = try decoded.result.get()
        #expect(value.isError == true)
        guard case .text(let text, _, _) = value.content.first else { Issue.record("no text"); return }
        #expect(text == #"{"accounts":["Work"]}"#)
    }

    @Test func transportPassesOtherLinesOn() async throws {
        let input = Pipe()
        let output = Pipe()
        let transport = LineTransport(
            input: input.fileHandleForReading.fileDescriptor, output: output.fileHandleForWriting.fileDescriptor,
            intercept: { line, _ in ToolCallFastPath.call(in: line) != nil })
        try await transport.connect()
        input.fileHandleForWriting.write(Data(
            (#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_accounts"}}"# + "\n"
                + #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"# + "\n").utf8))
        try input.fileHandleForWriting.close()
        var received: [String] = []
        for try await message in transport.receive() { received.append(String(decoding: message, as: UTF8.self)) }
        #expect(received == [#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#])
    }
}

@Suite("Fast rendering")
struct FastRenderingTests {
    @Test func compactJSONMatchesTheReferenceWriter() {
        let strings = [
            "", "plain", "quote \" and backslash \\", "new\nline\r\ttab", "\u{0}\u{1}\u{1F}control", "é 👨‍👩‍👧 中文",
            "\u{2028}\u{2029}", String(repeating: "x\"", count: 300),
        ]
        let value = JSON.obj([
            ("strings", .array(strings.map { .string($0) })),
            ("numbers", .array([.int(0), .int(-42), .int(Int64.max), .double(1.5), .double(.infinity)])),
            ("flags", .array([.bool(true), .bool(false), .null])),
            ("empty", .array([])), ("nothing", .object([])),
            ("nested", .obj([("a \"key\"", .obj([("b", .string("c"))]))])),
        ])
        #expect(value.serialized() == value.reference(pretty: false))
        #expect(value.serialized(pretty: true) == value.reference(pretty: true))
    }

    @Test func datesMatchTheFormatter() {
        var date = Date(timeIntervalSince1970: -86_400 * 400)
        for _ in 0..<2_000 {
            #expect(Render.isoDate(date) == Render.dateFormatter.string(from: date))
            // Weeks apart, all times of day, across summer-time changes; whole seconds, as Mail stores them.
            date.addTimeInterval(86_400 * 7 + 3_217)
        }
    }
}
