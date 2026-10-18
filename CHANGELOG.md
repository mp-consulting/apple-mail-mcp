# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- **"Ask me first" is the default send policy.** New installs, and anyone who never saved a send policy,
  confirm each email in the menu bar app; sending refuses while the app is not running. A saved choice is
  kept.

### Security

- **Approvals are signed.** The menu bar app signs each answer, together with everything it showed, with a
  key from the login Keychain ("Apple Mail MCP approval key"), and the server checks it against the request it
  wrote. An answer written to the approvals folder by another process, or for a request edited on disk,
  counts as declined.
- **Scheduled sends are signed** by the server that queued them. An entry added to or changed in
  `scheduled.json` by anything else is listed with the reason and never sent.
- Approval files are owner-only.

### Fixed

- A scheduled send whose Apple Event timed out after Mail had sent it is no longer sent again: before a
  retry, the menu bar app looks for it in Sent.

## [0.4.2] - 2026-10-18

### Security

- **Unsubscribing by email** now needs the sender's DKIM signature for its own domain, writes to exactly one
  address, and never sends the sender's body text (the subject is kept only when short). A forged newsletter
  can no longer make you email someone else in your name.
- **One-click unsubscribe** refuses this Mac, the local network and `.local` hosts, and never follows
  redirects. The approval request shows the full address, link and subject.
- **Attachments** can no longer come from your home folder's dotfiles (`~/.claude.json`, shell history,
  `~/.config`, tokens), the Claude app's config, or other apps' data (Notes, Contacts, Calendar, Photos).
- **Saving files** refuses Python `site-packages`, `.husky`, `.vscode`, `~/Library/Python` and Workflows,
  and `.pth`, `.dylib` and `.so` files. `export_messages` checks every file it writes.
- **Settings fail closed**: a mistyped key costs only that key, an unreadable send policy means "never",
  and a broken settings file keeps the last good settings instead of falling back to "send freely".
- Connecting Claude Code keeps `~/.claude.json` and its backup readable by you only.
- A message built to nest thousands of MIME parts, or full of unfinished encoded words, can no longer crash
  or stall the body index and message reads.

### Fixed

- **Connect** in the menu bar app works when the `claude` command cannot start (a Homebrew install can lose
  its execute permission): the server is then added to `~/.claude.json` directly.
- Negative or huge numbers in tool arguments no longer crash the server; they are clamped.
- Tools that take one message id refuse a list instead of acting on its first id.
- A scheduled send whose claim cannot be saved is no longer sent twice; scheduling reports a failed save.
- Saving into a folder that already holds 999 copies of a name now fails instead of overwriting.

### Performance

- The menu bar app does its mail and index checks off the main thread and polls less often.
- Tool calls no longer rescan all sent mail each time Mail changes something.
- The body index skips loading its vocabulary when there is nothing new to index.
- Reading a message no longer decodes every attachment to report its size; `get_message_source` cuts the
  headers before decoding.

## [0.4.1] - 2026-10-18

### Added

- The menu bar app notices when the Claude app runs Apple Mail twice (the extension and the config entry),
  which lists every tool twice and starts twice the server processes, and says how to remove the extension.

## [0.4.0] - 2026-10-18

### Added

- **`undo_change`**: moves, trashes and flag changes are journaled (Message-IDs and mailbox paths, no
  content) and can be put back; every change reply carries its `change_id`.
- **`check_authenticity`**: SPF, DKIM and DMARC results, alignment with the From domain, display names that
  show another address, look-alike and punycode domains of people you write with, Reply-To elsewhere, first
  contact, and links whose text shows another site than they open; verdict pass, caution or fail.
- **`find_contact`**: Contacts cards (when the app may read them) and correspondents from Mail's own
  address table, ranked by messages exchanged.
- **`extract_fields`**: tracking numbers (UPS, USPS, UPU S10 with its check digit, labelled numbers in six
  languages), verification codes, booking and order references, flights with the route, and calendar
  invitations from `.ics` parts.
- **`mail_setup`**: Mail's rules, VIPs, smart mailboxes and signatures (including those synced with iCloud).
- **`list_drafts`** and **`send_draft`** (replies are refused, so threads stay intact).
- **`wait_for_mail`**: waits for matching mail to arrive and returns it.
- **`snooze_messages`**, **`list_scheduled`**, **`cancel_scheduled`**, and **`send_at`** on `compose_email` and
  `reply_to_message`: snoozed mail comes back unread, scheduled mail is approved when scheduled and sent on
  time; the menu bar app runs both.
- **`unsubscribe`**: one-click (RFC 8058) for senders whose signature verified, unsubscribe emails, or the
  link; follows the send policy and asks in the menu bar app.
- **MCP prompts** for every skill, and **resources** `mail://inbox/unread` and `mail://needs-response` with
  change notifications.
- **Body search covers attachments**: the index adds the text of attached PDFs and text files (still as
  keyed hashes only); existing indexes re-read their messages with attachments.
- Menu bar app: what waits for a reply, snoozed and scheduled mail, an optional notification for new mail
  waiting on you, and a setting to approve moves and trashes above a size. The approval window now also asks
  about bulk changes and unsubscribes.

## [0.3.2] - 2026-10-18

### Fixed

- **"Can't read your mail" lingered after the fix**: the menu bar notice stayed for an hour after any Full Disk
  Access failure, even once the app could read mail again. It now shows only while that client's latest call
  failed, so it goes away with the next call that works.

## [0.3.1] - 2026-10-18

### Fixed

- **"Claude can't read your mail" after allowing Claude**: Claude starts MCP servers through a helper that
  hands macOS's permission check to another program, so Full Disk Access for Claude.app never applied. For
  Claude Code the check falls on Claude Code's own bundled `claude` app, and for the Claude Desktop extension
  on the server binary itself. The error and the menu bar notice now name the program macOS actually checks,
  with the exact path to add in System Settings › Privacy & Security › Full Disk Access.

## [0.3.0] - 2026-10-18

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

### Fixed

- Messages whose plain-text part is only a stub ("This is an HTML message.") now show, search and index the
  text of their HTML part. Telecom bills and other HTML-only senders were unreadable to `get_message`, body
  search and amount extraction.

### Security

- **The body search index no longer holds readable mail.** It used contentless FTS5, but the terms and their
  positions are enough to rebuild every message, and the file is not behind Full Disk Access. It now stores only
  keyed hashes of words and word pairs, without positions, with the key in the login Keychain. Existing indexes
  are deleted and rebuilt on first use. The file is owner-only and excluded from backups. Prefix search
  needs at least 3 characters; shorter words match whole.
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

[Unreleased]: https://github.com/mp-consulting/apple-mail-mcp/compare/v0.4.2...HEAD
[0.4.2]: https://github.com/mp-consulting/apple-mail-mcp/compare/v0.4.1...v0.4.2
[0.4.1]: https://github.com/mp-consulting/apple-mail-mcp/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/mp-consulting/apple-mail-mcp/compare/v0.3.2...v0.4.0
[0.3.2]: https://github.com/mp-consulting/apple-mail-mcp/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/mp-consulting/apple-mail-mcp/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/mp-consulting/apple-mail-mcp/compare/v0.2.2...v0.3.0
[0.2.2]: https://github.com/mp-consulting/apple-mail-mcp/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/mp-consulting/apple-mail-mcp/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/mp-consulting/apple-mail-mcp/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/mp-consulting/apple-mail-mcp/releases/tag/v0.1.0
