import Foundation
import MCP
import MailAutomation
import MailStore

public enum MailMCPVersion {
    /// The app bundle's version when running from "Apple Mail MCP.app" (stamped at release), else the source version.
    public static let current = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
        .flatMap { $0.hasPrefix("__") ? nil : $0 } ?? "0.3.2"
}

/// Binds a ``MailToolbox`` to an MCP `Server`.
public enum MailMCPServer {
    public static func make(toolbox: MailToolbox) async -> Server {
        let server = Server(
            name: "apple-mail",
            version: MailMCPVersion.current,
            title: "Apple Mail",
            instructions: MailToolbox.instructions,
            capabilities: .init(prompts: .init(listChanged: false), tools: .init(listChanged: false)))
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: toolbox.listedDefinitions.map(\.tool))
        }
        await server.withMethodHandler(CallTool.self) { params in
            await toolbox.call(params.name, arguments: params.arguments)
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
        try await server.start(transport: StdioTransport()) { clientInfo, _ in
            toolbox.clientName = clientInfo.title ?? clientInfo.name
        }
        await server.waitUntilCompleted()
    }
}
