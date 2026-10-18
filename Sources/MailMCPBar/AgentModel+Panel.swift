import AppKit
import MailMCPKit
import SwiftUI

/// Where the Skills window adds skills.
enum SkillTarget: Hashable {
    case claudeCode
    case claudeApp

    var explanation: String {
        switch self {
        case .claudeCode: "Installs into ~/.claude/skills. New Claude Code sessions use them."
        case .claudeApp: "Saves one .zip per skill to upload in Claude › Settings › Capabilities › Skills."
        }
    }
}

/// Something the user has to fix, shown as a row only while it is wrong.
struct AttentionItem: Identifiable, Hashable {
    enum Fix: Hashable { case fullDiskAccess, automation }
    var id: String
    var icon: String
    var title: String
    var detail: String
    var action: String
    var fix: Fix
}

extension AgentModel {
    static let claudeAppBundleID = "com.anthropic.claudefordesktop"

    // MARK: Header

    var headline: String {
        if !pending.isEmpty {
            return pending.count == 1 ? "1 request waiting for your OK" : "\(pending.count) requests waiting for your OK"
        }
        if !attention.isEmpty {
            return attention.count == 1 ? "1 thing needs attention" : "\(attention.count) things need attention"
        }
        var parts = ["Ready"]
        if messageCount > 0 { parts.append("\(messageCount.formatted()) messages") }
        if let last = activity.first { parts.append("last call \(last.date.formatted(.relative(presentation: .named)))") }
        return parts.joined(separator: " · ")
    }

    var headlineColor: Color {
        if !pending.isEmpty || !attention.isEmpty { return .orange }
        return .green
    }

    /// The Mail tab's footer: size of the mailbox and the index state.
    var footerLine: String {
        let messages = messageCount > 0 ? "\(messageCount.formatted()) messages · " : ""
        guard indexStatus != nil else { return messages + "no search index yet" }
        return messages + (notIndexed > 0 ? "\(notIndexed.formatted()) to index" : "index up to date")
    }

    var updaterLine: String {
        switch updater.state {
        case .checking: " · checking…"
        case .upToDate: " · up to date"
        case .available(let release): " · \(release.version.description) available"
        case .installing: " · installing…"
        case .failed(let message): " · \(message)"
        case .idle: ""
        }
    }

    /// A dot on the Claude tab: a client to connect or restart, or skills not added yet.
    var claudeNeedsAction: Bool {
        let code = clientStatus[.claudeCode] ?? .notInstalled
        let app = clientStatus[.claudeDesktop] ?? .notInstalled
        let codeTodo = code == .notInstalled || { if case .otherCommand = code { true } else { false } }()
        let appTodo = app == .notInstalled || { if case .otherCommand = app { true } else { false } }() || claudeAppNeedsRestart
        return codeTodo || appTodo || (code == .installed && installedSkillCount == 0)
    }

    var indexLine: String {
        guard let status = indexStatus else { return "No search index yet" }
        return notIndexed > 0 ? "\(notIndexed.formatted()) to index" : "Index up to date · \(status.indexedMessages.formatted())"
    }

    // MARK: Needs attention

    var attention: [AttentionItem] {
        var items: [AttentionItem] = []
        if let data = checks.first(where: { $0.name == "Mail data" }), data.state == .failed {
            items.append(AttentionItem(
                id: "fda", icon: "lock.shield", title: "Full Disk Access for this app",
                detail: "Needed for the status, counts and the search index.", action: "Open Settings…", fix: .fullDiskAccess))
        }
        if let automation = checks.first(where: { $0.name == "Automation" }), automation.state == .failed {
            items.append(AttentionItem(
                id: "automation", icon: "hand.raised", title: "Mail automation is off",
                detail: "Allow it so Claude can move, flag, draft and send.", action: "Open Settings…", fix: .automation))
        }
        // A client that cannot read Mail reports it in the activity log (see LaunchContext.explain);
        // its next successful call clears the notice.
        for app in ActivityEntry.appsLackingFullDiskAccess(in: activity) {
            items.append(AttentionItem(
                id: "client-fda-\(app)", icon: "exclamationmark.lock", title: "\(app) can't read your mail",
                detail: "Turn on Full Disk Access for \(app), then restart it.", action: "Open Settings…", fix: .fullDiskAccess))
        }
        return items
    }

    func perform(_ item: AttentionItem) {
        switch item.fix {
        case .fullDiskAccess: openFullDiskAccessSettings()
        case .automation: openAutomationSettings()
        }
    }

    // MARK: Claude

    var installedSkillCount: Int {
        skillStates.values.filter { $0 == .installed || $0 == .updateAvailable }.count
    }

    var claudeCodeDetail: String {
        switch clientStatus[.claudeCode] ?? .notInstalled {
        case .installed:
            let skills = installedSkillCount
            return skills == 0 ? "Server connected · no skills yet" : "Server connected · \(skills) skill\(skills == 1 ? "" : "s")"
        case .otherCommand: return "Uses another mail server; connect to switch"
        case .notInstalled: return "Adds the server and the skills"
        case .clientMissing: return "Claude Code isn't installed"
        }
    }

    var claudeAppDetail: String {
        switch clientStatus[.claudeDesktop] ?? .notInstalled {
        case .installed:
            return claudeAppNeedsRestart ? "Added. Restart Claude to load it." : "Server connected · skills: switch below to Claude app"
        case .otherCommand: return "Uses another mail server; connect to switch"
        case .notInstalled: return "Adds the server; Claude needs a restart"
        case .clientMissing: return "The Claude app isn't installed"
        }
    }

    /// The config changed after the running Claude app read it: it only loads servers at launch.
    var claudeAppNeedsRestart: Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.claudeAppBundleID).first,
              let launched = app.launchDate,
              let modified = (try? FileManager.default.attributesOfItem(atPath: clientInstaller.desktopConfigPath))?[.modificationDate] as? Date
        else { return false }
        return modified > launched
    }

    /// Server and every skill in one click.
    func connectClaudeCode() {
        install(in: .claudeCode)
        if clientStatus[.claudeCode] == .installed { installAllSkills() }
    }

    func installAllSkills() {
        selectedSkills = Set(SkillCatalog.all.map(\.name))
        installSelectedSkills()
        clientMessage = skillsMessage
    }

    /// Quits the Claude app and opens it again once it has exited, so it loads the new server.
    func restartClaudeApp() {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.claudeAppBundleID).first else {
            return
        }
        let pid = app.processIdentifier
        let url = app.bundleURL ?? URL(filePath: "/Applications/Claude.app")
        app.terminate()
        clientMessage = "Restarting Claude…"
        Task { @MainActor [weak self] in
            for _ in 0..<100 where NSRunningApplication(processIdentifier: pid) != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            let configuration = NSWorkspace.OpenConfiguration()
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            self?.clientMessage = "Claude restarted with Apple Mail. Its skills are added from Skills… › Claude app."
            self?.refreshClients()
        }
    }

    /// Zips the selected skills into ~/Downloads/Apple Mail MCP Skills and shows them in Finder.
    func exportSkillsForClaudeApp() {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads/Apple Mail MCP Skills")
        do {
            let zips = try SkillInstaller.exportZips(SkillCatalog.all.filter { selectedSkills.contains($0.name) }, to: folder)
            NSWorkspace.shared.activateFileViewerSelecting(zips)
            skillsMessage = "Saved \(zips.count) skill\(zips.count == 1 ? "" : "s") to Downloads › Apple Mail MCP Skills. In Claude, open Settings › Capabilities › Skills and upload each .zip."
        } catch {
            skillsMessage = "Could not export: \(error.localizedDescription)"
        }
    }
}
