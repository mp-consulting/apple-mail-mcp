import Foundation

/// Opt-in timing of a tool call's stages (`APPLE_MAIL_MCP_TRACE=1`): one stderr line per call with microseconds
/// between named marks (`MailToolbox.call`), never any content. For finding where time goes on real mail, which the
/// fixtures cannot show.
enum Trace {
    public static let enabled = ProcessInfo.processInfo.environment["APPLE_MAIL_MCP_TRACE"] != nil
    private static let lock = NSLock()
    nonisolated(unsafe) private static var marks: [(name: String, time: UInt64)] = []

    public static func mark(_ name: String) {
        guard enabled else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        lock.withLock { marks.append((name, now)) }
    }

    /// Writes the marks since the last `flush` as one line and starts over.
    public static func flush(_ label: String) {
        guard enabled else { return }
        let taken = lock.withLock {
            defer { marks.removeAll() }
            return marks
        }
        guard let first = taken.first else { return }
        var line = "trace \(label):"
        for (previous, mark) in zip(taken, taken.dropFirst()) { line += " \(mark.name) \((mark.time - previous.time) / 1000)" }
        line += " total \((taken.last!.time - first.time) / 1000) µs\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
