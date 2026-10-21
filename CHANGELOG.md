# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.6.5] - 2026-10-21

### Fixed

- **Updates work when another account installed the app.** On a Mac with several accounts, the app in Applications
  belongs to whoever installed or last updated it, and the other accounts could not replace it: the update was
  offered, then failed at the last step. The updater now checks every folder in the app, and when this account
  cannot replace it, asks for an administrator's password and swaps it in as root, after checking the signature
  again on a copy only root can change. Every install also leaves the app writable by the `admin` group, so the
  next update needs no password from any administrator account.

  This version is installed by the previous updater, so an account that cannot write the app still has to install
  0.6.5 once from the release page (or run the update from the account that owns it).

## [0.6.4] - 2026-10-21

### Fixed

- **Gmail trashes by moving to its Trash too.** 0.6.2 kept Mail's `delete` on Gmail (and Google Workspace) accounts,
  which can take the neighbouring message like it did on iCloud. A live check showed that moving to `[Gmail]/Trash`
  does exactly what `delete` did: every label dropped, nothing left in All Mail. No `delete` is sent for a message
  on any account now.

### Changed

- The live trash probes keep their `MCP Probe …` mailboxes and empty them into Trash, since Mail cannot delete a
  mailbox through scripting (-10000), and they wait for a new mailbox and retry set-up steps while Mail is busy (a
  copy only when it did not land).

## [0.6.3] - 2026-10-21

### Changed

- Builds record the SDK they were made with. A local build with Xcode 27 recorded the deployment target instead
  (macOS 14), so macOS gave the menu bar app its pre-26 look: a less rounded menu window without Liquid Glass.
  `Scripts/build-app.sh` now stamps the real SDK version before signing. Release builds already looked right; this
  release changes nothing else.

## [0.6.2] - 2026-10-20

### Fixed

- **Trash is a move to Trash.** After 0.6.1, `trash_messages` still took the date-neighbour of some messages on a
  busy iCloud mailbox: Mail's `delete` removes what it resolves by index, even when the message is named by its
  Message-ID. Trashing now moves each message to its account's Trash mailbox, by Message-ID, one at a time, and
  counts it only once it shows up there (more arriving in Trash than asked stops the call, as for a move). No
  `delete` is sent for a message, except on Gmail, which keeps Mail's `delete` until a move to `[Gmail]/Trash` is
  checked live. An account with several Trash mailboxes uses the only one holding messages; with none, or several
  in use, the call is refused instead of guessing (use `move_messages`). `send_draft` removes the sent draft the
  same way.
- Menu bar app: an answer that could not be recorded (no approval key) removed the request as if it had been sent.
  It now stays on screen, and errors the app ran into, which it never showed, appear under Needs attention.
- Menu bar app: the 15 s cap on status checks did not hold (a task group waits for every child), so a check stuck
  on Mail held up the activity list and the index; scheduled sends now also run on their own loop.
- Menu bar app: the Claude tab's restart dot asked the system and the disk on every redraw, and did not update when
  Claude was restarted; it is now refreshed with the other client checks.

### Added

- **Which server a client runs.** `initialize` reports the version with its build (`0.6.2+<commit>`, `.mcpb` for the
  Claude extension, `+dev` for a plain `swift build`), and so do replies that change mail (`server_version`) and
  every activity log line. `doctor` lists the build each client used last and warns when one ran an older server
  in the last hour; the menu bar app shows that under Needs attention.
- `doctor` counts messages whose Message-ID sits both in Trash and in another mailbox of the same account (Mail
  can leave such copies after messages are moved out of Trash).
- `TrashProbeTests`: variant E (move by Message-ID to Trash, paced, while another task keeps sync busy),
  `APPLE_MAIL_MCP_PROBE_ROUNDS`, and `copiesLeftAfterRestore` (`APPLE_MAIL_MCP_PROBE_GHOSTS=1`), which counts copies
  left in Trash at +0, +1, +5 and +15 minutes after a restore. `GmailTrashProbeTests` compares `move` to Trash
  with `delete` on Gmail, on drafts it makes itself.

### Changed

- Menu bar app: the tab highlight slides between tabs, rows that come and go on the Mail tab move into place, and
  tabs and queued requests dim as soon as they are pressed. Reduce Motion turns the movement off; the approval block
  never animates, so its Send button never lingers. Increase Contrast gives the approval block a firmer edge.
- Approval: To, Cc, Bcc and Files show their count and the first three, with the rest one click away, instead of
  two lines cut short (an email to 23 people showed three). The subject shows in full and the whole preview
  scrolls. At most five other requests are listed, so the panel and the window fit any screen.
- Activity: a failed call shows its reason on two lines and in full on hover; states have a shape as well as a
  colour; tool names read as words; calls from another day show the day.

## [0.6.1] - 2026-10-20

### Fixed

- **Bulk trash could take the wrong message.** On busy IMAP mailboxes, `trash_messages` sometimes trashed the
  next-older message instead of the one asked for: Mail's scripting turns a message `id` into a position in the
  mailbox, and positions shift while earlier removals are still in flight. Messages are now addressed by their
  Message-ID (`whose message id`). A message without one of its own in its mailbox is changed by id only when it
  is alone in its call, after Mail confirms its subject and date; in a batch it comes back in `retry_one_by_one`.
  Applies to move, trash, copy, mark, flag and colour.
- **One message at a time.** Moves and trashes wait for each message to leave the database before sending the
  next, and stop at the first one that does not: the rest come back in `not_attempted` instead of piling up in
  Mail.
- **Strays are named, put back and journalled.** When Mail moves messages nobody asked for,
  `collateral_suspected.strays` lists each one (old id, Message-ID, where it went, its new id), they are moved
  back at once (setting `restoreStrays`, on by default; `strays_restored`), and `stray_change_id` undoes them with
  `undo_change`. A second look 5 s later catches strays that land late.
- **A mailbox where a change went wrong is paused.** Further moves, trashes and `apply_rules` there are refused
  until Mail settles (the unconfirmed messages leave or stay put, and nothing else goes missing), two minutes at
  most, across server processes.
- **Calls stay within the client's timeout.** A move or trash stops before 90 s (setting `callBudget`) and returns
  the rest as `resume_ids`. Message events time out after 20 s instead of 60 s, and no Apple Event waits on a Mail
  alert any more (it fails at once with a message saying so), except for compose windows left open for the user.
- **Cancelled calls stop.** A `notifications/cancelled` from the client cancels the tool call, which stops between
  messages and releases Mail and the automation lock.

### Added

- The activity log writes a line when a call starts, replaced by its result, so a call that hangs still shows
  (grey in the menu bar app). Calls that reach Mail log where the time went: lock wait, Apple Events (count, total,
  longest) and database checks. `doctor` lists calls of the last day that started over 2 minutes ago and never
  finished.
- `TrashProbeTests`: an opt-in live probe (`APPLE_MAIL_MCP_LIVE_TRASH=1`) that compares trashing by id, paced,
  by moving to Trash and by Message-ID on throwaway copies.

## [0.6.0] - 2026-10-20

### Changed

- **The server moved into its own bundle**, `Apple Mail MCP.app/Contents/Helpers/Apple Mail MCP Server.app`.
  The menu bar app moves Claude Code's and the Claude app's settings to the new path (keeping arguments such as
  `--read-only`); other MCP clients set up with `…/Contents/MacOS/apple-mail-mcp` need the new path.
- **Keys in the data protection Keychain.** The body index key and the approval signing key now live under the
  team's Keychain access group, shared by the app and its server through a provisioning profile, instead of the
  login Keychain with an access list built by deprecated APIs. Existing keys are copied over on first use, so
  the index and pending approvals carry on. The Claude extension and development builds keep using the login
  Keychain.
- The update install shows a progress bar: the download, then each check and step.

### Fixed

- Build warnings: `concurrentMap` takes a `@Sendable` transform; `mail-bench` reads the CPU name without the
  deprecated `String(cString:)` on an array.

## [0.5.1] - 2026-10-20

### Changed

- **Tool calls from Swift clients take the fast path too.** Foundation's `JSONEncoder` writes the method as
  `tools\/call`, which the fast path did not recognise, so those calls went through the SDK's decoding.
- A tool's text reply is written straight into the JSON-RPC line instead of through `JSONEncoder`, which took
  longer than the tool for a 10 KB reply.
- The activity log is written in the background, after the reply.
- The mailbox list is rebuilt only when a row of Mail's mailbox table changed, not on every database write.

## [0.5.0] - 2026-10-19

### Added

- **Mail rules: `create_rule`, `update_rule`, `set_rule_enabled` and `delete_rule`.** Make a rule (conditions on
  sender, recipients, subject, body, headers, account, contacts or junk; move, copy, mark read, flag, colour, stop),
  change its name, conditions or actions, turn it on or off, or delete it. Rules that forward, redirect, auto-reply
  or delete, or match every message, ask in the menu bar app first, and so does every delete. Mail saves a change
  made by another app only when a rule's properties change through its setters, which turning a rule on or off and
  deleting it do not do, so each change ends with one that does. Then it reads Mail's rule files back and compares
  the whole rule with what was asked (`differences` when Mail saved something else), says when Mail has not saved
  it yet, and `mail_setup` lists those under `pending_rules` (or as lost if Mail quit first), across sessions.
  `undo_change` undoes rule changes too: a created rule is deleted, a deleted or changed one comes back as it was,
  a rule turned on or off is switched back.
- **`apply_rules`** runs rules on mail already in a mailbox, as Message › Apply Rules does (Mail offers other apps
  no way to run that): every enabled rule in Mail's order, or the ones named, matched the way Mail matches them.
  Dry run by default; above the user's threshold it asks once for the whole run. Moves, flags and trashes go
  through the usual tools, so they are checked and undoable; rules that send mail or run AppleScripts, and
  conditions it cannot reproduce exactly, are skipped and listed.

### Changed

- **Every call answers up to 10 ms sooner.** The server reads stdin with a blocking read instead of the MCP SDK's
  stdio transport, which polled every 10 ms. Simple calls (accounts, mailboxes, a thread) now take under 1–4 ms.
- **Mailbox listings count from Mail's indexes.** The total of a page limited to whole mailboxes and dates no
  longer reads every row to skip deleted ones: the newest 20 of a 5,000-message inbox went from 13 ms to 2 ms.
- **Subject, sender and recipient filters search in memory.** Mail's subjects and addresses are kept in memory
  (a few MB, caught up as Mail adds rows) instead of scanned with `LIKE` in SQLite, once for the page and again
  for its total: a subject search over 80,000 messages went from 31 ms to 3 ms. Matching is unchanged.
- **Tool calls skip the SDK's request decoding.** `tools/call` requests are parsed and answered directly (anything
  unusual still goes through the SDK), and quick reads run on the thread that read the request (macOS 15 and later).
  Replies are written as UTF-8 bytes; dates and previews render in one pass.
- **Repeated searches reuse their work.** A search's matches and total are kept until Mail's database changes, and
  a filtered search in a mailbox of up to 20,000 messages finds its page and total in one walk; a sender or subject
  search kept for a mailbox is checked against that mailbox only, so new mail elsewhere does not redo it. Parsed
  messages and scanned bodies are cached (32 MB at most); `get_thread` reads recipients in one query and its
  messages in parallel.
- The body index's test key (`APPLE_MAIL_MCP_TEST_INDEX_KEY`) is honoured only for an index outside the default
  location, so the real index always uses the Keychain key.
- `mail-bench compare` runs the same questions against the other Apple Mail MCP servers in the MCP registry
  (`Scripts/bench-servers.sh` fetches and prepares them), in turns so load hits every server alike, with
  `--fresh-index` for a throwaway body index. We answer every question fastest or tied ([Benchmarks](README.md#benchmarks)).

## [0.4.3] - 2026-10-18

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

[Unreleased]: https://github.com/mp-consulting/apple-mail-mcp/compare/v0.6.5...HEAD
[0.6.5]: https://github.com/mp-consulting/apple-mail-mcp/compare/v0.6.4...v0.6.5
[0.6.4]: https://github.com/mp-consulting/apple-mail-mcp/compare/v0.6.3...v0.6.4
[0.6.3]: https://github.com/mp-consulting/apple-mail-mcp/compare/v0.6.2...v0.6.3
[0.6.2]: https://github.com/mp-consulting/apple-mail-mcp/compare/v0.6.1...v0.6.2
[0.6.1]: https://github.com/mp-consulting/apple-mail-mcp/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/mp-consulting/apple-mail-mcp/compare/v0.5.1...v0.6.0
[0.5.1]: https://github.com/mp-consulting/apple-mail-mcp/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/mp-consulting/apple-mail-mcp/compare/v0.4.3...v0.5.0
[0.4.3]: https://github.com/mp-consulting/apple-mail-mcp/compare/v0.4.2...v0.4.3
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
