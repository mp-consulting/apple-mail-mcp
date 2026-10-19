// swift-tools-version:6.1

import PackageDescription

let package = Package(
    name: "apple-mail-mcp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "apple-mail-mcp", targets: ["apple-mail-mcp"]),
        .executable(name: "mail-bench", targets: ["mail-bench"]),
        .executable(name: "MailMCPBar", targets: ["MailMCPBar"]),
        .library(name: "MailStore", targets: ["MailStore"]),
        .library(name: "MailMCPKit", targets: ["MailMCPKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.16.1"),  // the SDK's own; for `Transport`
    ],
    targets: [
        // Read side: Mail's SQLite index, .emlx files, MIME parsing, full-text index.
        .target(
            name: "MailStore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // Write side: raw Apple Events to Mail.app, built from Mail's scripting dictionary (no AppleScript).
        .target(
            name: "MailAutomation",
            dependencies: ["MailStore"]
        ),
        // MCP tool surface, configuration, approvals and activity journal.
        .target(
            name: "MailMCPKit",
            dependencies: [
                "MailStore",
                "MailAutomation",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        // Synthetic Mail stores for tests and the scale benchmark.
        .target(
            name: "MailFixtures",
            dependencies: ["MailStore"]
        ),
        .executableTarget(
            name: "apple-mail-mcp",
            dependencies: ["MailMCPKit"]
        ),
        .executableTarget(
            name: "mail-bench",
            dependencies: [
                "MailStore",
                "MailFixtures",
                "MailMCPKit",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .executableTarget(
            name: "MailMCPBar",
            dependencies: ["MailStore", "MailAutomation", "MailMCPKit"]
        ),
        .testTarget(
            name: "MailStoreTests",
            dependencies: ["MailStore", "MailFixtures"]
        ),
        .testTarget(
            name: "MailAutomationTests",
            dependencies: ["MailAutomation", "MailStore"]
        ),
        .testTarget(
            name: "MailMCPKitTests",
            dependencies: [
                "MailMCPKit",
                "MailFixtures",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
    ]
)
