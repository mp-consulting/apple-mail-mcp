import Foundation
import MailAutomation
import MailMCPKit
import MailStore

let usage = """
    apple-mail-mcp \(MailMCPVersion.current): an MCP server for Apple Mail.

    USAGE
      apple-mail-mcp [--read-only] [--write-dir DIR]... [--attach-dir DIR]...
          Serve MCP over stdio (what MCP clients run).
      apple-mail-mcp index [--rebuild] [--prune]
          Build or update the full-text body index.
      apple-mail-mcp doctor
          Check Full Disk Access, Mail data, automation permission and the index.
      apple-mail-mcp call <tool> ['{"json":"arguments"}']
          Run one tool and print its result (for scripts and debugging).

    OPTIONS
      --read-only      Only reading tools: no moving, flagging, trashing, composing or sending.
      --write-dir DIR  Saved attachments and exports may only go inside DIR (repeatable).
      --attach-dir DIR Outgoing attachments may only come from DIR (repeatable).

    Settings shared with the menu bar app live in \(SharedPaths.settings.path).
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// Exits when the parent (the MCP client) dies, so no orphan keeps talking to Mail.
func watchParent() {
    let parent = getppid()
    Thread.detachNewThread {
        while true {
            Thread.sleep(forTimeInterval: 5)
            if getppid() != parent { exit(0) }
        }
    }
}

var arguments = Array(CommandLine.arguments.dropFirst())
var readOnly = false
var writeDirs: [String] = []
var attachDirs: [String] = []
var command: String?
var rest: [String] = []
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "--read-only": readOnly = true
    case "--write-dir":
        guard !arguments.isEmpty else { fail("--write-dir needs a folder") }
        writeDirs.append(arguments.removeFirst())
    case "--attach-dir":
        guard !arguments.isEmpty else { fail("--attach-dir needs a folder") }
        attachDirs.append(arguments.removeFirst())
    case "-h", "--help", "help":
        print(usage)
        exit(0)
    case "--version":
        print(MailMCPVersion.current)
        exit(0)
    default:
        if command == nil, !argument.hasPrefix("-") { command = argument } else { rest.append(argument) }
    }
}

let environmentWriteDirs = ProcessInfo.processInfo.environment["APPLE_MAIL_MCP_WRITE_DIRS"]?.split(separator: ":").map(String.init) ?? []
let environmentAttachDirs = ProcessInfo.processInfo.environment["APPLE_MAIL_MCP_ATTACH_DIRS"]?.split(separator: ":").map(String.init) ?? []
let extraWrite = writeDirs + environmentWriteDirs
let extraAttach = attachDirs + environmentAttachDirs
let isReadOnly = readOnly
let settings = SettingsProvider { settings in
    if isReadOnly {
        settings.allowMailChanges = false
        settings.sendPolicy = .never
    }
    settings.writeDirectories += extraWrite
    settings.attachDirectories += extraAttach
}

func openStore() -> MailStore {
    do {
        return try MailStore.open()
    } catch {
        fail("apple-mail-mcp: \(error)")
    }
}

switch command {
case nil, "serve":
    watchParent()
    let toolbox = MailToolbox(store: openStore(), automation: MailAutomation(), settings: settings, readOnly: readOnly)
    try await MailMCPServer.runStdio(toolbox: toolbox)

case "index":
    let store = openStore()
    let index = try BodyIndex(url: SharedPaths.bodyIndex)
    if rest.contains("--rebuild") { try index.reset() }
    let started = Date()
    let result = try index.update(from: store) { done, total in
        FileHandle.standardError.write(Data("\rindexed \(done)/\(total)".utf8))
    }
    let pruned = rest.contains("--prune") ? try index.prune(against: store) : 0
    let status = try index.status()
    print(
        "\nindexed \(result.indexed) messages in \(String(format: "%.1f", Date().timeIntervalSince(started))) s; "
            + "\(status.indexedMessages) in index, \(status.pendingMessages) waiting for download, pruned \(pruned), "
            + "\(status.sizeBytes / 1_048_576) MB")

case "doctor":
    print(try await Doctor.report(settings: settings.current))

case "call":
    guard let tool = rest.first else { fail("usage: apple-mail-mcp call <tool> [json]") }
    var parsed: [String: MCPValue]?
    if rest.count > 1 {
        guard let data = rest[1].data(using: .utf8), let value = try? JSONDecoder().decode([String: MCPValue].self, from: data) else {
            fail("arguments must be a JSON object")
        }
        parsed = value
    }
    let toolbox = MailToolbox(store: openStore(), automation: MailAutomation(), settings: settings, readOnly: readOnly)
    let result = await toolbox.call(tool, arguments: parsed)
    for content in result.content {
        if case .text(let text, _, _) = content { print(text) }
    }
    exit(result.isError == true ? 1 : 0)

default:
    fail("unknown command \(command!)\n\n\(usage)")
}
