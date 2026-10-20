import Foundation
import MCP
import MailAutomation
import MailStore

public enum MailMCPVersion {
    /// The app bundle's version when running from "Apple Mail MCP.app" (stamped at release), else the source version.
    public static let current = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
        .flatMap { $0.hasPrefix("__") ? nil : $0 } ?? "0.5.1"
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
        let transport = LineTransport(intercept: { line, transport in
            guard let call = ToolCallFastPath.call(in: line) else { return false }
            let respond: @Sendable () async -> Void = {
                let result = await toolbox.call(call.name, arguments: call.arguments)
                if let reply = try? ToolCallFastPath.reply(to: call, result: result) { try? transport.write(line: reply) }
            }
            if #available(macOS 15.0, *), toolbox.runsOnReaderThread(call.name, arguments: call.arguments) {
                // A quick read runs right here, on the thread that read the request: no other thread to wake on a
                // busy Mac. Should it await something, it carries on wherever that resumes.
                Task(executorPreference: InlineExecutor.shared, priority: .userInitiated) { await respond() }
            } else {
                Task(priority: .userInitiated) { await respond() }
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

/// Runs each job on the thread that enqueues it (see `runStdio`).
@available(macOS 15.0, *)
final class InlineExecutor: TaskExecutor {
    static let shared = InlineExecutor()

    func enqueue(_ job: consuming ExecutorJob) {
        job.runSynchronously(on: asUnownedTaskExecutor())
    }
}
