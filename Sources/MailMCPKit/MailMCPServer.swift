import Foundation
import MCP
import MailAutomation
import MailStore

public enum MailMCPVersion {
    /// The app bundle's version when running from "Apple Mail MCP.app" (stamped at release), else the source version.
    public static let current = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
        .flatMap { $0.hasPrefix("__") ? nil : $0 } ?? "0.6.0"
}

/// Binds a ``MailToolbox`` to an MCP `Server`.
public enum MailMCPServer {
    public static func make(toolbox: MailToolbox, watchInterval: TimeInterval = 5) async -> Server {
        let server = Server(
            name: "apple-mail",
            version: MailMCPVersion.current,
            title: "Apple Mail",
            instructions: MailToolbox.instructions,
            capabilities: .init(
                prompts: .init(listChanged: false), resources: .init(subscribe: true, listChanged: false),
                tools: .init(listChanged: false)))
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: toolbox.listedDefinitions.map(\.tool))
        }
        await server.withMethodHandler(CallTool.self) { params in
            await toolbox.call(params.name, arguments: params.arguments)
        }
        let resources = MailResources(toolbox: toolbox)
        await server.withMethodHandler(ListResources.self) { _ in ListResources.Result(resources: resources.resources) }
        await server.withMethodHandler(ReadResource.self) { params in try resources.read(params.uri) }
        await server.withMethodHandler(ResourceSubscribe.self) { params in
            try resources.subscribe(params.uri)
            _ = resources.changedSubscriptions()  // remember the current state; changes from here on are news
            return Empty()
        }
        await server.withMethodHandler(ResourceUnsubscribe.self) { params in
            resources.unsubscribe(params.uri)
            return Empty()
        }
        // Mail's database version is one cheap PRAGMA; nothing is read unless someone subscribed.
        Task { [weak server] in
            while let server, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(watchInterval * 1_000_000_000))
                for uri in resources.changedSubscriptions() {
                    try? await server.notify(ResourceUpdatedNotification.message(.init(uri: uri)))
                }
            }
        }
        await server.withMethodHandler(ListPrompts.self) { _ in ListPrompts.Result(prompts: toolbox.prompts) }
        await server.withMethodHandler(GetPrompt.self) { params in
            try toolbox.prompt(named: params.name, arguments: params.arguments)
        }
        return server
    }

    /// Runs over stdio until the client disconnects.
    public static func runStdio(toolbox: MailToolbox) async throws {
        let server = await make(toolbox: toolbox)
        // Tool calls skip the SDK's request decoding (see `ToolCallFastPath`); everything else goes through it.
        let running = RunningCalls()
        let transport = LineTransport(intercept: { line, transport in
            guard let call = ToolCallFastPath.call(in: line) else {
                // A call the client gave up on stops between messages and lets go of Mail and the lock.
                if let id = ToolCallFastPath.cancelledRequest(in: line) { running.cancel(id) }
                return false
            }
            let respond: @Sendable () async -> Void = {
                defer { running.remove(call.id) }
                let result = await toolbox.call(call.name, arguments: call.arguments)
                if let reply = try? ToolCallFastPath.reply(to: call, result: result) { try? transport.write(line: reply) }
            }
            if #available(macOS 15.0, *), toolbox.runsOnReaderThread(call.name, arguments: call.arguments) {
                // A quick read runs right here, on the thread that read the request: no other thread to wake on a
                // busy Mac. Should it await something, it carries on wherever that resumes.
                Task(executorPreference: InlineExecutor.shared, priority: .userInitiated) { await respond() }
            } else {
                running.start(call.id) { Task(priority: .userInitiated) { await respond() } }
            }
            return true
        })
        try await server.start(transport: transport) { clientInfo, _ in
            toolbox.clientName = clientInfo.title ?? clientInfo.name
        }
        await server.waitUntilCompleted()
        toolbox.activity?.flush()
    }
}

/// Tool calls in progress by request id (as JSON), so a `notifications/cancelled` can cancel their task.
final class RunningCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Data: Task<Void, Never>] = [:]
    private var cancelled: Set<Data> = []

    /// Starts the call's task under the lock, so its `remove` cannot come first.
    func start(_ id: Data, _ make: () -> Task<Void, Never>) {
        lock.withLock {
            let task = make()
            if cancelled.remove(id) != nil { task.cancel() }
            tasks[id] = task
        }
    }

    func remove(_ id: Data) { _ = lock.withLock { tasks.removeValue(forKey: id) } }

    func cancel(_ id: Data) {
        lock.withLock {
            if let task = tasks.removeValue(forKey: id) {
                task.cancel()
            } else {
                // Not started yet, or a quick read (not tracked); keep only a few.
                if cancelled.count > 100 { cancelled.removeAll() }
                cancelled.insert(id)
            }
        }
    }
}

/// Runs each job on the thread that enqueues it (see `runStdio`).
@available(macOS 15.0, *)
final class InlineExecutor: TaskExecutor {
    static let shared = InlineExecutor()

    func enqueue(_ job: consuming ExecutorJob) {
        job.runSynchronously(on: asUnownedTaskExecutor())
    }
}
