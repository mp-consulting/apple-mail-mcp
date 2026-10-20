import Foundation

/// Files shared by the MCP server processes and the menu bar app.
public enum SharedPaths {
    public static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["APPLE_MAIL_MCP_SUPPORT_DIR"], !override.isEmpty {
            return URL(filePath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/apple-mail-mcp")
    }

    public static var settings: URL { supportDirectory.appending(path: "settings.json") }
    public static var activityLog: URL { supportDirectory.appending(path: "activity.jsonl") }
    public static var approvals: URL { supportDirectory.appending(path: "approvals", directoryHint: .isDirectory) }
    public static var agentHeartbeat: URL { supportDirectory.appending(path: "agent.heartbeat") }
    public static var bodyIndex: URL { supportDirectory.appending(path: "body-index.sqlite") }
    public static var changeJournal: URL { supportDirectory.appending(path: "changes.json") }
    /// Mailboxes where a change went wrong, next to the change journal (see ``ChangeBreaker``).
    public static var changeBreaker: URL { supportDirectory.appending(path: ChangeBreaker.fileName) }
    public static var schedule: URL { supportDirectory.appending(path: "scheduled.json") }
    public static var scheduledFiles: URL { supportDirectory.appending(path: "scheduled-files", directoryHint: .isDirectory) }

    static func ensureDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

/// How outgoing mail is handled.
public enum SendPolicy: String, Codable, Sendable, CaseIterable {
    /// Send immediately when asked.
    case allow
    /// Ask in the menu bar app first; refuse if it is not running.
    case confirm
    /// Never send: only drafts and compose windows.
    case never
}

/// User settings, stored as JSON and editable from the menu bar app. The
/// server re-reads the file when it changes, so toggles apply immediately.
public struct Settings: Codable, Sendable, Equatable {
    /// Ask first by default: a prompt injected through an email can only send what the user approves.
    public var sendPolicy: SendPolicy = .confirm
    /// Allow moving, flagging, trashing and creating mailboxes.
    public var allowMailChanges = true
    /// Largest number of messages one move/update/trash call may touch.
    public var maxBatchSize = 50
    /// When non-empty, saved attachments and exports may only go inside these folders.
    public var writeDirectories: [String] = []
    /// When non-empty, outgoing attachments may only come from these folders.
    public var attachDirectories: [String] = []
    /// Extra addresses that count as "me" (aliases Mail does not report).
    public var ownAddresses: [String] = []
    /// Sender names that count as "me", e.g. your company as invoicing services show it
    /// ("MP Consulting" matches "MP Consulting (via Shine)"). Used by `exclude_from_self`.
    public var ownNames: [String] = []
    /// Keep the body index current from the menu bar app.
    public var autoUpdateBodyIndex = true
    /// Seconds to wait for a send approval.
    public var approvalTimeout: Double = 120
    /// Let the menu bar app look for a new release once a day.
    public var checkForUpdates = true
    /// Refresh installed Claude skills when the app ships newer versions of them.
    public var updateInstalledSkills = true
    /// Let the menu bar app post a notification when mail from a person starts waiting for a reply.
    public var notifyNeedsReply = false
    /// Moves and trashes of more messages than this wait for the user's OK in the menu bar app (0 = never ask).
    public var approveChangesAbove = 0
    /// Seconds a move or trash may run before it stops and returns the rest as `resume_ids`; below the ~2 minutes
    /// after which clients give up on a call (0 = no limit).
    public var callBudget: Double = 90
    /// Put back at once the messages Mail moved or trashed although nobody asked it to.
    public var restoreStrays = true

    public init() {}

    /// What applies when the settings file exists but cannot be read: nothing is sent or changed
    /// until the user fixes it, rather than falling back to the permissive defaults.
    public static var failClosed: Settings {
        var settings = Settings()
        settings.sendPolicy = .never
        settings.allowMailChanges = false
        return settings
    }

    public init(from decoder: Decoder) throws {
        // Every key is optional so older/newer files keep loading, and a key with the wrong type costs
        // only that key. The two safety switches fail closed instead of falling back to their defaults.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Settings()
        func field<T: Decodable>(_ key: CodingKeys, _ fallback: T, unreadable: T? = nil) -> T {
            guard container.contains(key) else { return fallback }
            do { return try container.decodeIfPresent(T.self, forKey: key) ?? fallback } catch { return unreadable ?? fallback }
        }
        sendPolicy = field(.sendPolicy, defaults.sendPolicy, unreadable: .never)
        allowMailChanges = field(.allowMailChanges, defaults.allowMailChanges, unreadable: false)
        maxBatchSize = field(.maxBatchSize, defaults.maxBatchSize)
        writeDirectories = field(.writeDirectories, [])
        attachDirectories = field(.attachDirectories, [])
        ownAddresses = field(.ownAddresses, [])
        ownNames = field(.ownNames, [])
        autoUpdateBodyIndex = field(.autoUpdateBodyIndex, defaults.autoUpdateBodyIndex)
        approvalTimeout = field(.approvalTimeout, defaults.approvalTimeout)
        checkForUpdates = field(.checkForUpdates, defaults.checkForUpdates)
        updateInstalledSkills = field(.updateInstalledSkills, defaults.updateInstalledSkills)
        notifyNeedsReply = field(.notifyNeedsReply, defaults.notifyNeedsReply)
        approveChangesAbove = field(.approveChangesAbove, defaults.approveChangesAbove)
        callBudget = field(.callBudget, defaults.callBudget)
        restoreStrays = field(.restoreStrays, defaults.restoreStrays)
    }

    /// The defaults when there is no file; `failClosed` when the file exists but is not valid settings JSON.
    public static func load(from url: URL = SharedPaths.settings) -> Settings {
        read(from: url) ?? failClosed
    }

    /// nil when the file exists but cannot be read or decoded.
    static func read(from url: URL) -> Settings? {
        guard FileManager.default.fileExists(atPath: url.path) else { return Settings() }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Settings.self, from: data)
    }

    public func save(to url: URL = SharedPaths.settings) throws {
        SharedPaths.ensureDirectory(url.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Settings file plus command-line overrides, reloaded when the file changes.
public final class SettingsProvider: @unchecked Sendable {
    private let url: URL
    private let overrides: (inout Settings) -> Void
    private let lock = NSLock()
    private var base = Settings()
    private var cached = Settings()
    private var cachedModification: timespec?
    private var loaded = false

    public init(url: URL = SharedPaths.settings, overrides: @escaping @Sendable (inout Settings) -> Void = { _ in }) {
        self.url = url
        self.overrides = overrides
    }

    public var current: Settings {
        lock.lock()
        defer { lock.unlock() }
        // One stat(2) per look (this runs several times per tool call); the file is read again only when it changed.
        var info = stat()
        let modified = stat(url.path, &info) == 0 ? info.st_mtimespec : nil
        if !loaded || modified?.tv_sec != cachedModification?.tv_sec || modified?.tv_nsec != cachedModification?.tv_nsec {
            // A file caught mid-write or broken by hand keeps the last good settings; with none yet, fail closed.
            var settings = Settings.read(from: url) ?? (loaded ? base : Settings.failClosed)
            base = settings
            overrides(&settings)
            cached = settings
            cachedModification = modified
            loaded = true
        }
        return cached
    }
}
