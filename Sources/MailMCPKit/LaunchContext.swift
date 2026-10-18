import Darwin
import Foundation
import MailStore

/// Who started this server: macOS grants Full Disk Access per app, and for a server it is the app
/// that launched it (Claude, Visual Studio Code, Terminal…) that needs the grant.
public enum LaunchContext {
    /// Name of the nearest `.app` among this process's ancestors, e.g. "Claude" or "Visual Studio Code".
    public static func launchingAppName(from pid: pid_t = getpid()) -> String? {
        var current = parent(of: pid)
        for _ in 0..<12 {
            guard let process = current, process > 1 else { return nil }
            if let path = executablePath(process), let range = path.range(of: ".app/", options: .backwards) {
                // The outermost .app wins (helpers live inside the main app's bundle).
                let bundle = String(path[..<range.lowerBound])
                let outer = bundle.components(separatedBy: ".app/").first ?? bundle
                return (outer as NSString).lastPathComponent
            }
            current = parent(of: process)
        }
        return nil
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : nil
    }

    static func parent(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    /// A tool-facing explanation for a Mail store that cannot be opened.
    public static func explain(_ error: Error) -> ToolError {
        let app = launchingAppName() ?? "the app that runs this server"
        // Without the grant, macOS either hides the folder or fails the database open (EPERM / I/O error).
        var accessProblem = false
        if case MailLocation.LocationError.noAccess = error { accessProblem = true }
        if case SQLiteError.open = error { accessProblem = true }
        if accessProblem {
            return ToolError("""
                Can't read Apple Mail's data: macOS hasn't given Full Disk Access to \(app), the app that started \
                this server. Open System Settings › Privacy & Security › Full Disk Access, turn on \(app) (add it \
                with + if it isn't listed), then quit and reopen \(app).
                """)
        }
        return ToolError("Apple Mail's data isn't available: \(error)")
    }
}
