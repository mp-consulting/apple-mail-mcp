# The server on Linux with a made-up mailbox, for directories that start a server to read its tools (Glama).
# Mail.app, the Keychain and Full Disk Access are macOS only: real mail needs the Mac app (see the README).
FROM swift:6.2-noble AS build
RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-dev && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY Package.swift Package.resolved ./
RUN swift package resolve
COPY Sources Sources
COPY Tests Tests
RUN swift build -c release --product apple-mail-mcp --static-swift-stdlib \
    && swift build -c release --product mail-bench --static-swift-stdlib \
    && cp "$(swift build -c release --show-bin-path)/apple-mail-mcp" "$(swift build -c release --show-bin-path)/mail-bench" /usr/local/bin/
# A fixed key for the demo index only (there is no Keychain here; the real index never takes it).
ENV APPLE_MAIL_MCP_TEST_INDEX_KEY=00112233445566778899aabbccddeeff
RUN mail-bench demo --dir /demo

FROM ubuntu:24.04
# FoundationNetworking (linked by the MCP SDK) loads libcurl; MailStore reads SQLite.
RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-0 libcurl4 libxml2 ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /usr/local/bin/apple-mail-mcp /usr/local/bin/apple-mail-mcp
COPY --from=build /demo /demo
ENV APPLE_MAIL_MCP_TEST_INDEX_KEY=00112233445566778899aabbccddeeff \
    APPLE_MAIL_MCP_MAIL_ROOT=/demo/data/Mail/V10 \
    APPLE_MAIL_MCP_ACCOUNTS_DB=/demo/data/Accounts/Accounts4.sqlite \
    APPLE_MAIL_MCP_SUPPORT_DIR=/demo/support
ENTRYPOINT ["apple-mail-mcp"]
