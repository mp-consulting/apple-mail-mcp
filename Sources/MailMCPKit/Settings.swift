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
    public var sendPolicy: SendPolicy = .allow
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

    public init() {}

    public init(from decoder: Decoder) throws {
        // Every key is optional so older/newer files keep loading.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Settings()
        sendPolicy = try container.decodeIfPresent(SendPolicy.self, forKey: .sendPolicy) ?? defaults.sendPolicy
        allowMailChanges = try container.decodeIfPresent(Bool.self, forKey: .allowMailChanges) ?? defaults.allowMailChanges
        maxBatchSize = try container.decodeIfPresent(Int.self, forKey: .maxBatchSize) ?? defaults.maxBatchSize
        writeDirectories = try container.decodeIfPresent([String].self, forKey: .writeDirectories) ?? []
        attachDirectories = try container.decodeIfPresent([String].self, forKey: .attachDirectories) ?? []
        ownAddresses = try container.decodeIfPresent([String].self, forKey: .ownAddresses) ?? []
        ownNames = try container.decodeIfPresent([String].self, forKey: .ownNames) ?? []
        autoUpdateBodyIndex = try container.decodeIfPresent(Bool.self, forKey: .autoUpdateBodyIndex) ?? defaults.autoUpdateBodyIndex
        approvalTimeout = try container.decodeIfPresent(Double.self, forKey: .approvalTimeout) ?? defaults.approvalTimeout
        checkForUpdates = try container.decodeIfPresent(Bool.self, forKey: .checkForUpdates) ?? defaults.checkForUpdates
        updateInstalledSkills = try container.decodeIfPresent(Bool.self, forKey: .updateInstalledSkills) ?? defaults.updateInstalledSkills
        notifyNeedsReply = try container.decodeIfPresent(Bool.self, forKey: .notifyNeedsReply) ?? defaults.notifyNeedsReply
        approveChangesAbove = try container.decodeIfPresent(Int.self, forKey: .approveChangesAbove) ?? defaults.approveChangesAbove
    }

    public static func load(from url: URL = SharedPaths.settings) -> Settings {
        guard let data = try? Data(contentsOf: url), let settings = try? JSONDecoder().decode(Settings.self, from: data) else {
            return Settings()
        }
        return settings
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
    private var cached = Settings()
    private var cachedModification: Date?

    public init(url: URL = SharedPaths.settings, overrides: @escaping @Sendable (inout Settings) -> Void = { _ in }) {
        self.url = url
        self.overrides = overrides
    }

    public var current: Settings {
        lock.lock()
        defer { lock.unlock() }
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if modified != cachedModification || cachedModification == nil {
            var settings = Settings.load(from: url)
            overrides(&settings)
            cached = settings
            cachedModification = modified ?? Date.distantPast
        }
        return cached
    }
}
