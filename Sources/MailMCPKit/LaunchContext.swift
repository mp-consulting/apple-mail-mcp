#if canImport(Darwin)
import Darwin
#endif
import Foundation
import MailStore

/// Who macOS checks for Full Disk Access when this server reads Mail's data.
///
/// That is the *responsible* process, which is not always the nearest app: Claude starts servers through a
/// helper that disclaims responsibility, so for Claude Code it is Claude Code's own bundled `claude` app, and
/// for a Claude Desktop extension it is this server binary itself. Granting Claude.app does not help either.
public enum LaunchContext {
    /// What needs the grant: a display name and the path to add in System Settings.
    public struct Responsible: Equatable, Sendable {
        public var name: String
        public var path: String
        /// True when macOS checks this server's own binary (Claude Desktop extensions).
        public var isThisServer: Bool
    }

    public static func responsible(for pid: pid_t = getpid()) -> Responsible? {
        if let owner = responsiblePID(for: pid), let path = executablePath(owner) {
            if owner == pid {
                return Responsible(name: (path as NSString).lastPathComponent, path: path, isThisServer: true)
            }
            return describe(executable: path)
        }
        // Without the system call, fall back to the nearest app among the ancestors.
        return launchingAppPath(from: pid).map { describe(executable: $0) }
    }

    /// The outermost `.app` of an executable path ("…/claude.app/Contents/MacOS/claude" → "claude"), else the file.
    static func describe(executable path: String) -> Responsible {
        guard let range = path.range(of: ".app/") else {
            return Responsible(name: (path as NSString).lastPathComponent, path: path, isThisServer: false)
        }
        let bundle = String(path[..<range.lowerBound]) + ".app"
        return Responsible(name: ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension, path: bundle, isThisServer: false)
    }

    /// `responsibility_get_pid_responsible_for_pid`, a stable but unexported libsystem call, looked up at runtime.
    static func responsiblePID(for pid: pid_t) -> pid_t? {
        typealias Lookup = @convention(c) (pid_t) -> pid_t
        guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        let owner = unsafeBitCast(symbol, to: Lookup.self)(pid)
        return owner > 0 ? owner : nil
    }

    /// Path of the nearest `.app` executable among this process's ancestors.
    static func launchingAppPath(from pid: pid_t) -> String? {
        var current = parent(of: pid)
        for _ in 0..<12 {
            guard let process = current, process > 1 else { return nil }
            if let path = executablePath(process), path.contains(".app/") { return path }
            current = parent(of: process)
        }
        return nil
    }

    #if os(macOS)
    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func parent(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }
    #else
    // Full Disk Access is macOS's: elsewhere there is no responsible app to name.
    static func executablePath(_ pid: pid_t) -> String? { nil }

    static func parent(of pid: pid_t) -> pid_t? { nil }
    #endif

    /// A tool-facing explanation for a Mail store that cannot be opened.
    public static func explain(_ error: Error) -> ToolError {
        // Without the grant, macOS either hides the folder or fails the database open (EPERM / I/O error).
        var accessProblem = false
        if case MailLocation.LocationError.noAccess = error { accessProblem = true }
        if case SQLiteError.open = error { accessProblem = true }
        guard accessProblem else { return ToolError("Apple Mail's data isn't available: \(error)") }
        return ToolError(message(for: responsible()))
    }

    /// Keeps "Full Disk Access to <name>," first: the menu bar app reads the name from there.
    static func message(for owner: Responsible?) -> String {
        let settings = "System Settings › Privacy & Security › Full Disk Access"
        guard let owner else {
            return "Can't read Apple Mail's data: macOS hasn't given Full Disk Access to the app that runs this server. Turn it on in \(settings), then restart that app."
        }
        let addIt = "click +, press ⌘⇧G, paste \(owner.path) and turn it on"
        if owner.isThisServer {
            return """
                Can't read Apple Mail's data: macOS hasn't given Full Disk Access to \(owner.name), this server: \
                Claude runs it on its own behalf, so allowing Claude does not cover it. In \(settings), \(addIt), then \
                restart Claude.
                """
        }
        // Claude Code inside Claude runs from its own bundled app; allowing Claude.app does not cover it.
        let note = owner.path.contains("/claude-code/") ? " (Claude Code's own app, not Claude.app)" : ""
        return """
            Can't read Apple Mail's data: macOS hasn't given Full Disk Access to \(owner.name), the app that started \
            this server\(note). In \(settings), \(addIt), then quit and reopen Claude or \(owner.name).
            """
    }
}
