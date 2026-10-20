import AppKit
import Foundation
import MailAutomation
import MailMCPKit
import MailStore
import Observation
import ServiceManagement
import UserNotifications

/// State and background work of the menu bar agent.
@MainActor
@Observable
final class AgentModel {
    var settings = Settings.load()
    var checks: [Doctor.Check] = []
    var activity: [ActivityEntry] = []
    var pending: [ApprovalRequest] = []
    var indexStatus: BodyIndex.Status?
    var notIndexed = 0
    var messageCount = 0
    /// Mail from people in the last 3 days still waiting for a reply.
    var needsReply: [MessageSummary] = []
    private var seenNeedsReply: Set<Int64>?
    /// Snoozes and scheduled sends waiting, shown in the Mail tab.
    var snoozedCount = 0
    var scheduledSends: [ScheduledSend] = []
    let schedule = ScheduleStore()
    /// Carries out snoozes and scheduled sends; made on first use, Mail's store opens when needed.
    @ObservationIgnored private var _scheduler: MailToolbox?
    private var scheduler: MailToolbox {
        if let existing = _scheduler { return existing }
        let toolbox = MailToolbox(storeProvider: { try MailStore.open() }, automation: MailAutomation(), schedule: schedule)
        toolbox.clientName = "Apple Mail MCP"
        _scheduler = toolbox
        return toolbox
    }
    private var isRunningSchedule = false
    var isIndexing = false
    var indexProgress: (done: Int, total: Int)?
    var lastError: String?
    var launchAtLogin = SMAppService.mainApp.status == .enabled
    var skillStates: [String: SkillInstaller.State] = [:]
    var selectedSkills = Set<String>()
    var skillsMessage: String?
    let skillInstaller = SkillInstaller()
    var clientStatus: [ClientInstaller.Client: ClientInstaller.Status] = [:]
    var clientMessage: String?
    let updater = Updater()
    var skillTarget: SkillTarget = .claudeCode
    var panelTab: PanelTab = .mail
    /// Which waiting email the panel shows in full when several wait.
    var focusedApproval: UUID?

    let approvals = ApprovalCenter()
    let log = ActivityLog()
    private var store: MailStore?
    /// Read by the status checks off the main thread; kept open between runs.
    @ObservationIgnored private var statusIndex: BodyIndex?
    @ObservationIgnored private var activityStamp: ActivityLog.Stamp?
    @ObservationIgnored private var approvalsWatcher: DispatchSourceFileSystemObject?
    private var lastDataVersion: Int64 = -1
    private var lastIndexRun = Date.distantPast
    private var tasks: [Task<Void, Never>] = []
    private var notifiedApprovals = Set<UUID>()
    var openApprovalWindow: (() -> Void)?
    var closeApprovalWindow: (() -> Void)?

    /// Path of the MCP server binary that ships in this app (its own bundle in Contents/Helpers).
    var serverPath: String {
        let helper = Bundle.main.bundleURL
            .appending(path: "Contents/Helpers/\(ClientInstaller.helperName)/Contents/MacOS/apple-mail-mcp").path
        if FileManager.default.isExecutableFile(atPath: helper) { return helper }
        let besideExecutable = (CommandLine.arguments[0] as NSString).deletingLastPathComponent + "/apple-mail-mcp"
        return FileManager.default.isExecutableFile(atPath: besideExecutable) ? besideExecutable : "apple-mail-mcp"
    }

    var claudeCodeCommand: String { "claude mcp add apple-mail -- \"\(serverPath)\"" }

    var desktopConfig: String {
        """
        {
          "mcpServers": {
            "apple-mail": { "command": "\(serverPath)" }
          }
        }
        """
    }

    var hasProblem: Bool { checks.contains { $0.state == .failed } }

    var clientInstaller: ClientInstaller { ClientInstaller(serverPath: serverPath) }

    func start() {
        guard tasks.isEmpty else { return }
        requestNotificationPermission()
        // Clients set up before 0.6 start the server where it no longer is.
        let repointed = clientInstaller.repointFormerServerPath()
        if !repointed.isEmpty {
            clientMessage = "Updated the server's location for \(repointed.map(\.displayName).joined(separator: " and ")). "
                + "Restart it to use the new version."
        }
        refreshClients()
        updater.automaticChecks = { [weak self] in self?.settings.checkForUpdates ?? true }
        updater.start()
        refreshInstalledSkills()
        // New approval requests show up at once through the folder watcher; the loop keeps the heartbeat
        // (servers treat it as stale after 20 s) and catches anything the watcher missed.
        watchApprovals()
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                self?.approvals.beat()
                self?.refreshApprovals()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        })
        // Activity log, status checks and the index: slower loop.
        tasks.append(Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                self.refreshActivity()
                if tick % 15 == 0 { await self.refreshChecks() }
                if tick % 5 == 0 { await self.maybeUpdateIndex() }
                if tick % 15 == 0 { await self.runSchedule() }
                tick += 1
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        })
    }

    // MARK: Approvals

    func refreshApprovals() {
        let current = approvals.pending()
        if current.map(\.id) != pending.map(\.id) { pending = current }
        let fresh = current.filter { !notifiedApprovals.contains($0.id) }
        guard !fresh.isEmpty else { return }
        for request in fresh {
            notifiedApprovals.insert(request.id)
            notify(request)
        }
        panelTab = .mail
        NSApp.activate()
        openApprovalWindow?()
    }

    /// Calls `refreshApprovals` whenever a request file is added, replaced or removed.
    private func watchApprovals() {
        try? FileManager.default.createDirectory(at: approvals.directory, withIntermediateDirectories: true)
        let fd = open(approvals.directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            MainActor.assumeIsolated {
                guard let self, let source else { return }
                // The folder itself was moved or deleted: watch the new one.
                if source.data.contains(.delete) || source.data.contains(.rename) {
                    source.cancel()
                    self.approvalsWatcher = nil
                    self.watchApprovals()
                }
                self.refreshApprovals()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        approvalsWatcher = source
    }

    func decide(_ request: ApprovalRequest, approve: Bool) {
        do {
            try approvals.decide(request.id, approve: approve)
        } catch {
            // Without the approval key nothing can be signed, and the server treats the request as declined.
            lastError = "Could not record your answer: \(error)"
        }
        pending.removeAll { $0.id == request.id }
        if focusedApproval == request.id { focusedApproval = pending.first?.id }
        if pending.isEmpty { closeApprovalWindow?() }
    }

    private func requestNotificationPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(_ request: ApprovalRequest) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        switch request.action {
        case .send: content.title = request.sendAt == nil ? "Send this email?" : "Schedule this email?"
        case .change: content.title = "Change these messages?"
        case .unsubscribe: content.title = "Unsubscribe?"
        case .rule: content.title = "Allow this Mail rule?"
        }
        content.subtitle = request.subject.isEmpty ? "(no subject)" : request.subject
        let target = request.to.isEmpty ? "" : "To " + request.to.joined(separator: ", ")
        content.body = target + (request.client.map { (target.isEmpty ? "" : " · ") + "from \($0)" } ?? "")
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: request.id.uuidString, content: content, trigger: nil))
    }

    // MARK: Snoozes and scheduled sends

    func runSchedule() async {
        guard !isRunningSchedule else { return }
        isRunningSchedule = true
        defer { isRunningSchedule = false }
        let report = await scheduler.runDueSchedules()
        if !report.failed.isEmpty { lastError = "Could not send \(report.failed.joined(separator: ", ")) yet; retrying." }
        snoozedCount = schedule.snoozes.reduce(0) { $0 + $1.messageIDs.count }
        scheduledSends = schedule.sends
    }

    // MARK: Needs a reply

    func applyNeedsReply(_ current: [MessageSummary]) {
        if current != needsReply { needsReply = current }
        // The first look only learns what is already waiting; later ones notify about what is new.
        if let seen = seenNeedsReply, settings.notifyNeedsReply {
            for message in current.filter({ !seen.contains($0.id) }).prefix(3) { notifyNeedsReply(message) }
        }
        seenNeedsReply = (seenNeedsReply ?? []).union(current.map(\.id))
    }

    private func notifyNeedsReply(_ message: MessageSummary) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "Waiting for your reply"
        content.subtitle = message.sender.name ?? message.sender.address
        content.body = message.subject
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "needs-reply-\(message.id)", content: content, trigger: nil))
    }

    func openMail() {
        NSWorkspace.shared.open(URL(filePath: "/System/Applications/Mail.app"))
    }

    // MARK: Status

    /// Reads the log only when its size or date changed, and publishes only a different list.
    func refreshActivity() {
        let stamp = log.stamp()
        guard stamp != activityStamp else { return }
        activityStamp = stamp
        let entries = log.recent(limit: 40)
        if entries != activity { activity = entries }
    }

    private struct StoreReadings: Sendable {
        var messageCount = 0
        var needsReply: [MessageSummary]?
        var indexStatus: BodyIndex.Status?
        var notIndexed = 0
    }

    func refreshChecks() async {
        // Counts and the index first: they are local reads and never wait on Mail. They run off the main thread.
        if store == nil { store = try? MailStore.open() }
        if let store {
            // Opening is cheap and happens once the index exists; the reads are what take time.
            if statusIndex == nil { statusIndex = BodyIndex.openIfPresent(url: SharedPaths.bodyIndex) }
            let index = statusIndex
            let readings = await Task.detached(priority: .utility) {
                var readings = StoreReadings()
                readings.messageCount = (try? store.messageCount()) ?? 0
                readings.needsReply = try? store.needsResponse(days: 3, limit: 50)
                if let status = try? index?.status() {
                    readings.indexStatus = status
                    readings.notIndexed = (try? store.countMessages(after: status.coveredThrough)) ?? 0
                }
                return readings
            }.value
            if readings.messageCount != messageCount { messageCount = readings.messageCount }
            if let current = readings.needsReply { applyNeedsReply(current) }
            if let status = readings.indexStatus {
                if status != indexStatus { indexStatus = status }
                if readings.notIndexed != notIndexed { notIndexed = readings.notIndexed }
            }
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        refreshClients()
        // The automation check asks macOS about Mail and can stall while Mail is busy: cap it.
        let settings = self.settings
        let checks = await withTaskGroup(of: [Doctor.Check]?.self) { group in
            group.addTask { await Doctor.checks(settings: settings) }
            group.addTask {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        if let checks {
            self.checks = checks.filter { $0.name != "Menu bar app" && $0.name != "Settings" }
        }
    }

    // MARK: Body index

    /// Keeps the index current: runs when Mail's database changed, at most every 2 minutes.
    func maybeUpdateIndex(force: Bool = false) async {
        guard settings.autoUpdateBodyIndex || force, !isIndexing else { return }
        if store == nil { store = try? MailStore.open() }
        guard let store else { return }
        let version = (try? store.dataVersion()) ?? 0
        let hasIndex = FileManager.default.fileExists(atPath: SharedPaths.bodyIndex.path)
        guard force || !hasIndex || (version != lastDataVersion && Date().timeIntervalSince(lastIndexRun) > 120) else { return }
        lastDataVersion = version
        lastIndexRun = Date()
        isIndexing = true
        defer { isIndexing = false }
        let report: @Sendable (Int, Int) -> Void = { [weak self] done, total in
            Task { @MainActor in self?.indexProgress = (done, total) }
        }
        let result: Result<BodyIndex.UpdateResult, Error> = await Task.detached(priority: .utility) {
            Result {
                let index = try BodyIndex(url: SharedPaths.bodyIndex)
                return try index.update(from: store, timeBudget: force ? .infinity : 60, progress: report)
            }
        }.value
        indexProgress = nil
        switch result {
        case .success(let update):
            if update.remaining > 0 { lastIndexRun = .distantPast }  // keep going next tick
            lastError = nil
        case .failure(let error):
            lastError = "Index: \(error)"
        }
        await refreshChecks()
    }

    func rebuildIndex() async {
        do {
            try BodyIndex(url: SharedPaths.bodyIndex).reset()
        } catch {
            lastError = "Index: \(error)"
            return
        }
        await maybeUpdateIndex(force: true)
    }

    // MARK: Claude clients

    func refreshClients() {
        let installer = clientInstaller
        clientStatus = Dictionary(uniqueKeysWithValues: ClientInstaller.Client.allCases.map { ($0, installer.status($0)) })
    }

    func install(in client: ClientInstaller.Client) {
        do {
            clientMessage = try clientInstaller.install(client)
        } catch {
            clientMessage = "Could not add to \(client.displayName): \(error)"
        }
        refreshClients()
    }

    func uninstall(from client: ClientInstaller.Client) {
        do {
            try clientInstaller.uninstall(client)
            clientMessage = "Removed from \(client.displayName)."
        } catch {
            clientMessage = "Could not remove from \(client.displayName): \(error)"
        }
        refreshClients()
    }

    // MARK: Skills

    func refreshSkills() {
        skillStates = Dictionary(uniqueKeysWithValues: SkillCatalog.all.map { ($0.name, skillInstaller.state(of: $0)) })
        if selectedSkills.isEmpty {
            // Preselect what is not installed yet or has an update.
            selectedSkills = Set(SkillCatalog.all.filter { [.notInstalled, .updateAvailable].contains(skillStates[$0.name]) }.map(\.name))
        }
    }

    /// Runs at launch, so an app update also updates the skills it installed earlier.
    func refreshInstalledSkills() {
        guard settings.updateInstalledSkills else { return }
        if let updated = try? skillInstaller.refreshInstalled(), !updated.isEmpty {
            skillsMessage = "Updated \(updated.count) Claude skill\(updated.count == 1 ? "" : "s") to this version."
            lastError = nil
        }
        refreshSkills()
    }

    private var chosenSkills: [MailSkill] { SkillCatalog.all.filter { selectedSkills.contains($0.name) } }

    func installSelectedSkills() {
        do {
            let done = try skillInstaller.install(chosenSkills)
            skillsMessage = "Added \(done.count) skill\(done.count == 1 ? "" : "s") to Claude Code (~/.claude/skills). New Claude Code sessions pick them up."
        } catch {
            skillsMessage = "Could not install: \(error.localizedDescription)"
        }
        selectedSkills = []
        refreshSkills()
    }

    func uninstallSelectedSkills() {
        do {
            let removed = try skillInstaller.uninstall(chosenSkills)
            skillsMessage = "Removed \(removed.count) skill\(removed.count == 1 ? "" : "s")."
        } catch {
            skillsMessage = "Could not remove: \(error.localizedDescription)"
        }
        selectedSkills = []
        refreshSkills()
    }

    func exportSelectedSkillsToChosenFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a folder for the skill .zip files (upload them in Claude → Settings → Capabilities → Skills)."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            let zips = try SkillInstaller.exportZips(chosenSkills, to: folder)
            NSWorkspace.shared.activateFileViewerSelecting(zips)
            skillsMessage = "Exported \(zips.count) skill\(zips.count == 1 ? "" : "s") to \(folder.lastPathComponent)."
        } catch {
            skillsMessage = "Could not export: \(error.localizedDescription)"
        }
    }

    // MARK: Settings

    func save() {
        do {
            try settings.save()
            lastError = nil
        } catch {
            lastError = "Could not save settings: \(error.localizedDescription)"
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            lastError = "Launch at login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    func openAutomationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }
}
