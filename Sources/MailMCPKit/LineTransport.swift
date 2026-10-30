import Foundation
import Logging
import MCP
#if canImport(Glibc)
import Glibc
#endif

/// MCP over stdio without polling. The SDK's `StdioTransport` makes stdin non-blocking and sleeps 10 ms whenever
/// nothing is waiting, so every request sat up to 10 ms before the server read it. Here a thread blocks in
/// `read(2)` and hands each line over the moment it arrives; writes block until the client has the reply.
public actor LineTransport: Transport {
    public nonisolated let logger: Logger
    private let input: Int32
    private let output: Int32
    private let messages: AsyncThrowingStream<Data, Swift.Error>
    private let continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    private var started = false
    private nonisolated let writeLock = NSLock()
    /// Sees each line before the SDK does; returning true means it took the line (see `ToolCallFastPath`).
    private let intercept: (@Sendable (Data, LineTransport) -> Bool)?

    public init(
        input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO, logger: Logger? = nil,
        intercept: (@Sendable (Data, LineTransport) -> Bool)? = nil
    ) {
        self.input = input
        self.output = output
        self.intercept = intercept
        self.logger = logger ?? Logger(label: "apple-mail-mcp.stdio", factory: { _ in SwiftLogNoOpLogHandler() })
        (messages, continuation) = AsyncThrowingStream.makeStream()
    }

    public func connect() async throws {
        guard !started else { return }
        started = true
        let input = self.input
        let continuation = self.continuation
        let intercept = self.intercept
        let reader = Thread { [self] in
            var buffer = [UInt8](repeating: 0, count: 65_536)
            var pending: [UInt8] = []
            var scanned = 0  // bytes of `pending` already known to hold no newline
            while true {
                let count = buffer.withUnsafeMutableBytes { read(input, $0.baseAddress, $0.count) }
                if count < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN { Self.wait(for: input, events: Int16(POLLIN)); continue }
                    continuation.finish(throwing: MCPError.transportError(POSIXError.current))
                    return
                }
                if count == 0 { break }
                pending.append(contentsOf: buffer[..<count])
                var lineStart = 0
                while let newline = pending[scanned...].firstIndex(of: UInt8(ascii: "\n")) {
                    if newline > lineStart {
                        let line = Data(pending[lineStart..<newline])
                        if intercept?(line, self) != true { continuation.yield(line) }
                    }
                    lineStart = newline + 1
                    scanned = lineStart
                }
                pending.removeFirst(lineStart)
                scanned = pending.count
            }
            continuation.finish()
        }
        reader.name = "apple-mail-mcp stdin"
        // A client waits on every line: on a busy Mac, default-priority threads queue behind everything else.
        reader.qualityOfService = .userInitiated
        reader.start()
    }

    public func disconnect() async {
        continuation.finish()
    }

    public func send(_ data: Data) async throws {
        try write(line: data)
    }

    /// `send` from any thread, without hopping onto the actor: the tool call fast path answers from the thread
    /// that ran the tool. Lines never interleave.
    public nonisolated func write(line data: Data) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        var message = data
        message.append(UInt8(ascii: "\n"))
        let output = self.output
        try message.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < bytes.count {
                let written = systemWrite(output, bytes.baseAddress! + offset, bytes.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN { Self.wait(for: output, events: Int16(POLLOUT)); continue }
                    throw MCPError.transportError(POSIXError.current)
                }
                offset += written
            }
        }
    }

    public nonisolated func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        messages
    }

    /// For a descriptor someone else made non-blocking: sleep until it is ready instead of spinning.
    private static func wait(for descriptor: Int32, events: Int16) {
        var target = pollfd(fd: descriptor, events: events, revents: 0)
        _ = poll(&target, 1, -1)
    }
}

#if canImport(Glibc)
private let systemWrite = Glibc.write
#else
private let systemWrite = Darwin.write
#endif

extension POSIXError {
    /// The error `errno` holds now.
    static var current: POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
