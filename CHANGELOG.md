# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-10-18

First release.

### Added

- **MCP server in Swift** (`apple-mail-mcp`) with 24 tools: accounts and mailboxes, an inbox overview,
  search, messages, threads, attachments, raw source, statistics, top senders, awaiting reply,
  needs response, export, move, mark and flag, trash, create mailbox, check for new mail, compose,
  reply, forward and open in Mail.
- **Direct reads**: search, threads, statistics and message bodies come from Mail's own SQLite
  index and `.emlx` files, so they never wait on Mail. Includes MIME and HTML-to-text parsing,
  charset and encoded-word decoding, and Gmail-style label mailboxes.
- **Full-text body index** (SQLite FTS5), built in about a minute for 80,000 messages and kept
  current by the menu bar app; body searches fall back to a parallel file scan for anything not
  indexed yet.
- **Writes through Apple Events**: raw events built from Mail's scripting dictionary, without
  AppleScript, with a cross-process lock so concurrent clients queue instead of overloading Mail.
- **Menu bar app**: status, a send-approval queue ("Ask me first" policy), recent activity, the body
  index, settings, one-click setup for Claude Code and the Claude app, and daily update checks.
- **Eight Claude skills** (triage, inbox zero, follow-up, reply writer, newsletter cleanup, research,
  attachments, weekly report), installable from the app or `apple-mail-mcp skills install`, and
  refreshed automatically when the app updates.
- **Safety**: drafts by default, send policies (allow, confirm, never), per-call batch limits, dry
  runs, no permanent deletion, and a path guard for saved files and outgoing attachments.
- **Command line**: `doctor`, `index`, `call`, `install`/`uninstall` for Claude clients and `skills`.
- **Benchmarks** (`mail-bench`): in-process timings, a synthetic mailbox of any size, and a
  side-by-side comparison with the Python apple-mail-mcp over MCP.

[Unreleased]: https://github.com/mp-consulting/apple-mail-mcp/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/mp-consulting/apple-mail-mcp/releases/tag/v0.1.0
