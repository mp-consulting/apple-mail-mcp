#if os(macOS)
import AppKit
#endif
import Foundation
import MCP
import MailAutomation
import MailStore

public typealias MCPValue = MCP.Value

/// Environment checks shared by `apple-mail-mcp doctor` and the menu bar app.
public enum Doctor {
    public struct Check: Sendable, Identifiable {
        public enum State: Sendable { case ok, warning, failed }
        public var id: String { name }
        public var name: String
        public var state: State
        public var detail: String
    }

    /// Blocking reads and the Automation permission call (which can stall while Mail is busy): always on the
    /// concurrent pool, whoever calls it.
    #if compiler(>=6.2)
    @concurrent
    #endif
    public static func checks(settings: Settings) async -> [Check] {
        var checks: [Check] = []
        var store: MailStore?
        do {
            let location = try MailLocation.discover()
            let opened = try MailStore(location: location)
            store = opened
            let count = try opened.messageCount()
            let path = location.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            checks.append(Check(name: "Mail data", state: .ok, detail: "\(count.formatted()) messages in \(path)"))
            let accounts = try opened.accounts()
            checks.append(Check(name: "Accounts", state: .ok, detail: accounts.map(\.name).joined(separator: ", ")))
        } catch let error as MailLocation.LocationError {
            let state: Check.State = .failed
            checks.append(Check(name: "Mail data", state: state, detail: error.description))
        } catch {
            checks.append(Check(name: "Mail data", state: .failed, detail: "\(error)"))
        }

        #if os(macOS)
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").isEmpty
        #else
        let running = false  // no Mail.app outside macOS
        #endif
        checks.append(Check(name: "Mail app", state: running ? .ok : .warning, detail: running ? "running" : "not running (reads still work; it is launched for changes)"))
        if running {
            let status = MailAutomation().permissionStatus(askIfNeeded: false)
            switch status {
            case 0: checks.append(Check(name: "Automation", state: .ok, detail: "allowed to control Mail"))
            case -1744: checks.append(Check(name: "Automation", state: .warning, detail: "macOS will ask for permission on the first change"))
            case -1743: checks.append(Check(name: "Automation", state: .failed, detail: "denied; allow it in System Settings → Privacy & Security → Automation"))
            default: checks.append(Check(name: "Automation", state: .warning, detail: "status \(status)"))
            }
        }

        if let index = BodyIndex.openIfPresent(url: SharedPaths.bodyIndex), let status = try? index.status() {
            let behind = (try? store?.countMessages(after: status.coveredThrough)) ?? 0
            // Only where the key is read without a prompt (see `keychainCheck`).
            let otherKey = KeychainSecret.claimsSharedGroup && index.builtWithCurrentKey() == false
            checks.append(Check(
                name: "Body index", state: behind > 500 || otherKey ? .warning : .ok,
                detail: "\(status.indexedMessages) messages, \(status.sizeBytes / 1_048_576) MB, \(behind) not yet indexed"
                    + (otherKey ? "; built with another key, so the next search rebuilds it" : "")))
        } else {
            checks.append(Check(name: "Body index", state: .warning, detail: "not built; body searches scan files (run `apple-mail-mcp index`)"))
        }

        checks.append(keychainCheck())

        // The last day only: a server that died long ago is history, not a problem to fix.
        let stuck = ActivityLog().stuck().filter { Date().timeIntervalSince($0.date) < 86_400 }
        if !stuck.isEmpty {
            let lines = stuck.prefix(5).map { entry in
                let alive = kill(entry.pid, 0) == 0 ? "still running" : "server gone"
                return "\(entry.tool) since \(Render.isoDate(entry.date)) (pid \(entry.pid), \(alive))"
            }
            checks.append(Check(
                name: "Unfinished calls", state: .warning,
                detail: "\(stuck.count) started over 2 minutes ago and never finished: " + lines.joined(separator: "; ")))
        }

        checks.append(contentsOf: clientChecks(ActivityLog().recent(limit: 400)))
        if let store, let copies = try? trashCopies(store), !copies.isEmpty {
            checks.append(Check(
                name: "Copies in Trash", state: .warning,
                detail: copies.map { "\($0.count) in \($0.account)" }.joined(separator: ", ") + """
                     have their Message-ID both in Trash and in another mailbox (left by Mail after messages were \
                    moved out of Trash). Emptying Trash is safe: the other copy stays. Trashing one of them again puts \
                    its Message-ID in Trash twice, and Trash then gives it back only one call per message.
                    """))
        }

        let agent = ApprovalCenter().isAgentRunning()
        checks.append(Check(
            name: "Menu bar app", state: agent || settings.sendPolicy != .confirm ? .ok : .failed,
            detail: agent ? "running" : (settings.sendPolicy == .confirm ? "not running, but send policy needs it for approvals" : "not running")))
        checks.append(Check(
            name: "Settings", state: .ok,
            detail: "send policy \(settings.sendPolicy.rawValue), mail changes \(settings.allowMailChanges ? "allowed" : "off"), batch limit \(settings.maxBatchSize)"))
        return checks
    }

    /// The server build each client used last (from the activity log), and a warning when one used an older server
    /// than this one in the last hour.
    static func clientChecks(_ entries: [ActivityEntry], current: String = MailMCPVersion.current, now: Date = Date()) -> [Check] {
        let week = entries.filter { now.timeIntervalSince($0.date) < 7 * 86_400 }
        let versions = ActivityEntry.serverVersions(in: week)
        guard !versions.isEmpty else { return [] }
        var checks = [Check(
            name: "Clients", state: .ok,
            detail: versions.map { "\($0.client): \($0.version ?? "before 0.6.2") (\(Render.isoDate($0.date)))" }.joined(separator: "; "))]
        let older = ActivityEntry.clientsOnOlderServer(in: week, current: current, now: now)
        if !older.isEmpty {
            checks.append(Check(
                name: "Older server", state: .warning,
                detail: older.map { "\($0.client) ran \($0.version ?? "a version before 0.6.2")" }.joined(separator: ", ")
                    + " in the last hour, older than \(current). Restart it, and check which server it starts."))
        }
        return checks
    }

    /// Per account (by name), how many Message-IDs sit both in its Trash and in another of its mailboxes. Gmail is left
    /// out: its labels put one message in several mailboxes.
    static func trashCopies(_ store: MailStore) throws -> [(account: String, count: Int)] {
        let accounts = try store.accounts()
        var found: [(String, Int)] = []
        for account in accounts {
            let boxes = try store.mailboxes(accountID: account.id)
            guard !boxes.contains(where: { $0.sourceMailboxID != nil }) else { continue }
            let trash = boxes.filter { $0.role == .trash }.map(\.id)
            let count = try store.sharedHeaderCount(trash: trash, others: boxes.map(\.id).filter { !trash.contains($0) })
            if count > 0 { found.append((account.name, count)) }
        }
        return found
    }

    /// Where the index and approval keys are. A release build loads them (copying keys of an earlier version into
    /// the shared group); other builds only look, so a check never brings up a Keychain prompt.
    static func keychainCheck() -> Check {
        guard KeychainSecret.claimsSharedGroup else {
            let present = [("index key", BodyIndexKey.service, BodyIndexKey.account), ("approval key", SigningKey.service, SigningKey.account)]
                .filter { KeychainSecret.inLoginKeychain(service: $0.1, account: $0.2) }.map(\.0)
            return Check(
                name: "Keychain", state: .ok,
                detail: "login Keychain (this build is not the app's), " + (present.isEmpty ? "no keys yet" : present.joined(separator: " and ") + " present"))
        }
        do {
            _ = try BodyIndexKey.fromKeychain()
            _ = try SigningKey.fromKeychain()
            return Check(name: "Keychain", state: .ok, detail: "index and approval keys in the app's shared Keychain group")
        } catch {
            return Check(name: "Keychain", state: .failed, detail: "\(error)")
        }
    }

    public static func report(settings: Settings) async throws -> String {
        await checks(settings: settings).map { check -> String in
            let mark = switch check.state {
            case .ok: "✓"
            case .warning: "!"
            case .failed: "✗"
            }
            return "\(mark) \(check.name): \(check.detail)"
        }.joined(separator: "\n")
    }
}
