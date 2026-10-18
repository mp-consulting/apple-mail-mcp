# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **`export_search`**: writes every message matching a search to one CSV, JSON or XLSX file and returns
  only the path and row count, so thousands of results never come back inline. Choose the columns with
  `fields`; `include: ["amount", "invoice_number"]` adds vendor, total, currency and invoice number;
  `dedupe` (on by default) writes a message stored in several mailboxes once.
- **Search filters** (also on `export_search`): several comma-separated `query` terms match any of them;
  `exclude_subject`, `exclude_sender`, `exclude_replies`, `exclude_from_self`, `direction`
  (`received`/`sent`), several `category` values. `group_by: "sender" | "domain" | "month"` returns counts.
- **`get_messages`**: up to 200 messages in one call, quotes stripped, with a size budget and `remaining_ids`.
- **`extract_invoice_fields`**: totals, currencies and invoice numbers from invoice and receipt bodies
  (English, French, German, Spanish, Portuguese, Italian), falling back to the text of attached PDFs.
- Search results carry the `message://` `link`; `compact: true` leaves out previews, and previews lose the
  invisible padding some senders add.
- Setting **"Names I send as"** (`ownNames`), e.g. your company as invoicing services show it, used by
  `exclude_from_self`.

### Changed

- Search, conversations, awaiting-reply and needs-response queries use the right SQLite index for their
  scope: 5 to 300 times faster on a 100,000-message mailbox. Result totals for sender, subject and other
  unscoped searches count through the filter's own index or a table scan (sender search 41 → 9 ms).

### Security

- Exported cells never run as formulas: CSV text starting with `=`, `+`, `-` or `@` gets a leading `'`,
  and XLSX cells are plain strings and numbers. Exports keep their format's extension.
- Saved attachments are quarantined like Mail's own, so Gatekeeper checks emailed apps and scripts.
- Attachment file names lose bidirectional-override and other invisible characters.
- `.env.local`, `.env.production` and similar files cannot be attached.
- Mailbox folders and attachment part ids from Mail's database cannot point outside Mail's folder.

## [0.2.2] - 2026-10-18

### Fixed

- **Claude extension would not open**: double-clicking `AppleMailMCP-0.2.1.mcpb` failed with "Invalid comment
  length. Expected: 4203. Found: 0." `mcpb sign` appends the signature after the zip without updating the zip's
  comment length, and Claude's zip reader rejects that. Releases now set the comment length to cover the
  signature before signing (`Scripts/sign-mcpb.sh`), and `Scripts/verify-mcpb.sh` fails if it does not match.

## [0.2.1] - 2026-10-18

### Fixed

- **Verified moves and trashes**: `move_messages` and `trash_messages` no longer trust Mail's Apple Event
  replies. They check Mail's database and count only messages that really left their mailbox (and, for a
  move, reached the destination); the rest come back as `unverified`. If a mailbox loses or gains more
  messages than requested, the call stops before the next mailbox and reports `collateral_suspected`.
  The automation lock is now held across the change and its check, so two clients cannot interleave bulk
  changes. The inbox-zero and newsletter-cleanup skills run batches one at a time and stop on either field.
- **Claude extension in releases**: the 0.2.0 release stopped after signing the extension, so it shipped
  without `AppleMailMCP-0.2.0.mcpb` and was not listed in the MCP registry. `mcpb verify` reports every file
  as unsigned (node-forge cannot verify PKCS#7); releases now check the signature with OpenSSL instead.

## [0.2.0] - 2026-10-18

### Added

- **Formatted email**: `compose_email`, `reply_to_message` and `forward_message` take an `html` body. Mail sends a
  real HTML email (bold, links, lists, tables); replies and forwards quote the original with its formatting.
- **Claude app extension**: `AppleMailMCP-<version>.mcpb`, notarized and signed, installs the server in the Claude
  app with a double-click; it has a "Read-only" setting.
- **Homebrew**: `brew install --cask mp-consulting/tap/apple-mail-mcp`; the cask follows each release.
- **MCP registry**: each release is listed as `io.github.mp-consulting/apple-mail-mcp`.
- **Intel Macs**: the app and the server are universal (Apple silicon and Intel).
- README screenshots in light and dark, matching the reader's setting.

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
- **Menu bar app** with Mail, Claude and Settings tabs: a send-approval queue ("Ask me first" policy),
  recent activity, the body index, one-click setup for Claude Code and the Claude app (with restart),
  the skills, settings, and daily update checks of signed releases.
- **Eight Claude skills** (triage, inbox zero, follow-up, reply writer, newsletter cleanup, research,
  attachments, weekly report), installable from the app or `apple-mail-mcp skills install`, and
  refreshed automatically when the app updates.
- **Safety**: drafts by default, send policies (allow, confirm, never), per-call batch limits, dry
  runs, no permanent deletion, and a path guard for saved files and outgoing attachments.
- **Command line**: `doctor`, `index`, `call`, `install`/`uninstall` for Claude clients and `skills`.
- **Benchmarks** (`mail-bench`): in-process timings, a synthetic mailbox of any size, and a
  side-by-side comparison with the Python apple-mail-mcp over MCP.
- **Show in Mail**: activity rows about a message (read, replied, moved, flagged, drafted…) open it in Mail,
  and a reply or forward waiting for approval links to the original.
- Skills in the Claude tab are listed by their Claude Code slash command (`/mail-triage`…); click to copy.

[Unreleased]: https://github.com/mp-consulting/apple-mail-mcp/compare/v0.2.2...HEAD
[0.2.2]: https://github.com/mp-consulting/apple-mail-mcp/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/mp-consulting/apple-mail-mcp/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/mp-consulting/apple-mail-mcp/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/mp-consulting/apple-mail-mcp/releases/tag/v0.1.0
