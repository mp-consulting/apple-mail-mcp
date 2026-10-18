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
      apple-mail-mcp install [claude-code | claude-desktop | all]
          Register this server with Claude Code and/or Claude Desktop (default: all found).
      apple-mail-mcp uninstall [claude-code | claude-desktop | all]
          Remove it again.
      apple-mail-mcp skills [list | install [NAME]... | uninstall [NAME]... | export DIR]
          Manage the Claude skills that ship with the server (~/.claude/skills).
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
// The Claude app extension passes its "Read-only" setting this way.
if let flag = ProcessInfo.processInfo.environment["APPLE_MAIL_MCP_READ_ONLY"]?.lowercased(), ["true", "1", "yes"].contains(flag) {
    readOnly = true
}
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
    // The store opens on first use: without Full Disk Access the server still starts, and each tool
    // explains which app needs the grant instead of the client showing a crashed server.
    let toolbox = MailToolbox(
        storeProvider: {
            do { return try MailStore.open() } catch { throw LaunchContext.explain(error) }
        },
        automation: MailAutomation(), settings: settings,
        // Benchmarks and scripted runs set this so they don't show up in the menu bar's Activity.
        activity: ProcessInfo.processInfo.environment["APPLE_MAIL_MCP_NO_ACTIVITY"] == nil ? ActivityLog() : nil,
        readOnly: readOnly)
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

case "install", "uninstall":
    let me = URL(filePath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath().path
    let installer = ClientInstaller(serverPath: me)
    let target = rest.first ?? "all"
    let clients = target == "all" ? ClientInstaller.Client.allCases : ClientInstaller.Client.allCases.filter { $0.rawValue == target }
    guard !clients.isEmpty else { fail("usage: apple-mail-mcp \(command!) [claude-code | claude-desktop | all]") }
    for client in clients {
        if installer.status(client) == .clientMissing, target == "all" {
            print("\(client.displayName): not found, skipped")
            continue
        }
        do {
            if command == "install" {
                print("\(client.displayName): \(try installer.install(client))")
            } else {
                try installer.uninstall(client)
                print("\(client.displayName): removed")
            }
        } catch {
            print("\(client.displayName): \(error)")
        }
    }

case "tools-json":
    // Tool names and one-line descriptions, for the .mcpb manifest (see Scripts/make-mcpb.sh).
    let toolbox = MailToolbox(storeProvider: { throw ToolError("not needed") }, automation: MailAutomation(), settings: settings, activity: nil)
    let tools: [[String: String]] = toolbox.definitions.map { definition in
        let text = definition.tool.description ?? ""
        let first = text.firstIndex(of: ".").map { String(text[...$0]) } ?? text
        return ["name": definition.tool.name, "description": first.replacingOccurrences(of: "\n", with: " ")]
    }
    let data = try JSONSerialization.data(withJSONObject: tools, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))

case "skills":
    let installer = SkillInstaller()
    let action = rest.first ?? "list"
    let names = Set(rest.dropFirst())
    let selected = names.isEmpty ? SkillCatalog.all : SkillCatalog.all.filter { names.contains($0.name) }
    if !names.isEmpty, selected.count != names.count {
        fail("unknown skill; available: \(SkillCatalog.all.map(\.name).joined(separator: ", "))")
    }
    switch action {
    case "list":
        for skill in SkillCatalog.all {
            print("\(skill.name.padding(toLength: 26, withPad: " ", startingAt: 0)) \(installer.state(of: skill).rawValue.padding(toLength: 16, withPad: " ", startingAt: 0)) \(skill.summary)")
        }
    case "install":
        let done = try installer.install(selected)
        print("installed \(done.map(\.name).joined(separator: ", ")) into \(installer.directory.path)")
        let skipped = selected.filter { installer.state(of: $0) == .foreign }
        if !skipped.isEmpty { print("skipped (a different skill with that name exists): \(skipped.map(\.name).joined(separator: ", "))") }
    case "uninstall":
        let removed = try installer.uninstall(selected)
        print("removed \(removed.isEmpty ? "nothing" : removed.map(\.name).joined(separator: ", "))")
    case "export":
        guard rest.count >= 2 else { fail("usage: apple-mail-mcp skills export DIR") }
        let zips = try SkillInstaller.exportZips(SkillCatalog.all, to: URL(filePath: (rest[1] as NSString).expandingTildeInPath))
        for zip in zips { print(zip.path) }
    default:
        fail("usage: apple-mail-mcp skills [list | install [NAME]... | uninstall [NAME]... | export DIR]")
    }

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
