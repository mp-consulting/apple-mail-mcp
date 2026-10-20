# Apple Mail MCP

An MCP server for Apple Mail in Swift, plus a menu bar app. Reads come from Mail's own data on disk;
changes go through Mail with Apple Events.

## Layout

| Target | What it is |
|---|---|
| `MailStore` | Read side: SQLite wrapper, Envelope Index queries, `.emlx` files, MIME, HTML→text, folding, the FTS5 body index |
| `MailAutomation` | Write side: raw Apple Events to Mail (`AppleEvents.swift`), typed API (`MailAutomation.swift`), cross-process lock |
| `MailMCPKit` | MCP tools (`Tools+*.swift`), settings, approvals, activity log, path guard, skills, client installer, updates |
| `apple-mail-mcp` | The server and CLI (`serve`, `doctor`, `index`, `call`, `install`, `skills`) |
| `MailMCPBar` | The menu bar app (SwiftUI): status, approvals, Claude setup, skills, settings, updater |
| `MailFixtures` | Synthetic Mail stores for tests and benchmarks (same schema and file layout as Mail V10) |
| `mail-bench` | Benchmarks: `store`, `synthetic`, `compare` (vs the other Apple Mail MCP servers; `Scripts/bench-servers.sh`), `demo` (screenshot data) |
| `Skills/` | The Claude skills, one `SKILL.md` each; embedded into the binary |

## Commands

```sh
# Files under ~/Documents carry Finder metadata that codesign rejects: build outside the repo.
swift build --scratch-path ~/Library/Caches/apple-mail-mcp-build
swift test  --scratch-path ~/Library/Caches/apple-mail-mcp-build

Scripts/build-app.sh             # signed "Apple Mail MCP.app" in ~/Library/Caches/AppleMailMCP/dist
Scripts/build-app.sh --install   # also copies it to ~/Applications and relaunches it
Scripts/embed-skills.sh          # after editing Skills/*/SKILL.md (a test fails if you forget)
swift Scripts/make-icon.swift Resources

.build/release/mail-bench store | synthetic --messages 100000 | compare | demo --approval 3
```

## Rules

- **Never touch real mail in tests.** Tests run on `MailFixtures`; live checks are opt-in
  (`APPLE_MAIL_MCP_LIVE=1`). Benchmarks and logs print counts and timings, never message content.
  Screenshots use `mail-bench demo` data (`APPLE_MAIL_MCP_MAIL_ROOT`, `APPLE_MAIL_MCP_ACCOUNTS_DB`,
  `APPLE_MAIL_MCP_SUPPORT_DIR`).
- **Reads never talk to Mail.** Only `MailAutomation` sends Apple Events. No AppleScript source anywhere.
- Tool output is compact JSON (`JSON.obj`, keys in a deliberate order, false/empty fields omitted).
- The server must start even when Mail data is unreadable: the store opens lazily and errors explain
  which app needs Full Disk Access (`LaunchContext`).
- Skills may only mention tools and parameters that exist (`SkillTests.skillsOnlyReferenceRealTools`).
- **No Claude attribution in git.** Commit messages and pull request descriptions carry no `Co-Authored-By: Claude`
  trailer and no "Generated with Claude Code" line.
- **The body index stores no text.** It sits outside Full Disk Access, so `BodyIndex` keeps only SipHash tokens
  (words, bigrams, and a prefix → word `vocab`), keyed by `BodyIndexKey` from the Keychain. Contentless FTS5
  alone is not enough: `fts5vocab` reads every word and position back. Tests pass a fixed key and never touch
  the Keychain; `fileHoldsNoReadableText` checks the file.
- **Keychain secrets** (`KeychainSecret`: body index key, approval signing key) live in the data protection Keychain
  under the access group `4HWBUF2R8D.com.mpconsulting.AppleMailMCP`, which only a team Developer ID build claims,
  through `Resources/AppleMailMCP.provisionprofile` (renew it with the Developer ID certificate, which expires
  2027-02-01). macOS kills a binary that claims it outside a bundle with the profile, so the server is its own
  bundle in `Contents/Helpers/Apple Mail MCP Server.app`, and the `.mcpb` ships a standalone copy that claims
  nothing. Without the group (`errSecMissingEntitlement`: dev builds, the `.mcpb`) the login Keychain is used.

## Mail facts this code depends on (macOS 26–27, Mail V10)

- `messages.ROWID` is Mail's scripting `id`. A message gets a **new ROWID when it moves**; find it again
  by `Message-ID` (`message_global_data.message_id_header`).
- Flag colour lives in bits 39–41 of `messages.flags` (red 0 … gray 6), not in `flag_color`.
- `unsubscribe_type` is 0 (not NULL) for normal mail; `list_id_hash` is 0 when there is no List-Id.
- `message_global_data.model_category`: 0 primary, 1 transactions, 2 updates, 3 promotions.
- Gmail labels: a mailbox with `source` set holds no rows; its messages are linked through `labels`.
- `.emlx` path: `<account>/<a>.mbox/<b>.mbox/<store-uuid>/Data/<reversed digits of rowid/1000>/Messages/<rowid>[.partial].emlx`;
  stripped attachments sit in `…/Attachments/<rowid>/<IMAP part>/<file>` with `X-Apple-Content-Length`.
- Account names come from `~/Library/Accounts/Accounts4.sqlite` (description, else the parent's).
- **Do not** delete messages that are already in Trash: Mail aborts (`deleteMessages` transfer crash).
- **Do not** reply to or forward an unsent draft: Mail hangs.
- **Do not** address messages by `id` for delete or move during bulk changes on IMAP: scripting resolves the id to an
  index (`_scriptingRemoveObjectsAtIndexes:fromValueForKey:`) and, with removals in flight, can remove the neighbour.
  Use `whose message id` (`MailSpec.message(header:in:)`, property `meid`), one message at a time, waiting for each
  to leave the database. Probe: `TrashProbeTests` (`APPLE_MAIL_MCP_LIVE_TRASH=1`).
- **Do not** delete a rule condition with Apple Events: `-[MFMessageRule(Applescript) removeFromCriteriaAtIndex:]`
  calls itself until Mail crashes (stack overflow). Rewrite conditions in place, or make the rule again.
- `reply`/`forward` always open a window. `save` is asynchronous: closing or deleting the compose object
  right after it discards the draft, so the server waits for the draft row (ROWID above the
  pre-compose maximum) before closing it.
- Insert all attachments, then wait until `count of attachments of content` matches before saving or
  sending; saving earlier drops the late ones.
- Mail keeps compose objects in memory until it quits; `delete`/`close` do not free invisible ones.
- HTML email: set `content` to an **RTF** descriptor (HTML → `NSAttributedString` → RTF, on the main thread). Mail
  then saves and sends multipart HTML. The scripting `html content` property does nothing.
- Rules (read in Mail's code and checked live): Mail saves its whole rule list when a rule changes through its
  setters (`handleDidChangeIfNeeded` → `ruleDidChange:`), which a scripted `make` and every scripted `set` do,
  except `enabled` (`setIsActive:` only marks the rule changed) and `delete` (`-[MailApp removeFromRulesAtIndex:]`
  → `removeRuleAtIndex:`). Those stay in memory until the next save, and quitting never saves. The save copies the
  list as it is, usually 1.5 s later but once 56 s (log: `MFMessageRouter` "Rules written to disk"). So
  `MailAutomation` ends every change by renaming the rule to a temporary name and back, and deletes by renaming
  first. Setting a property to the value it has saves only when a change is already pending. `make` ignores
  `enabled` and cannot take object references (set `move message`/`copy message` after it). With Mail › Settings ›
  Rules open, that tab saves changes itself (`RulesPreferences saveChanges`) until Mail quits, so test with it
  closed. `UnsyncedRules.plist` and `RulesActiveState.plist` (on/off, by `RuleId`) are written at once;
  `SyncedRules.plist` (definitions) once Mail holds its iCloud Drive copy (`SyncedFileActivity`): usually at once,
  once 27 minutes after launch. Saved keys are those of `-[MFMessageRule dictionaryRepresentation]`; the account
  in a rule's `MailboxURL` is its user name or id. Rules are addressed by name; "sender is VIP" shares code `tsig`
  with "sender is not member of group". Mail gives other apps no way to run Apply Rules (`-[MessageViewer
  reapplySortingRules:]`; no scripting command or Shortcuts action), hence `apply_rules`. Probe: `RuleProbeTests`
  (`APPLE_MAIL_MCP_LIVE_RULES=1`, `APPLE_MAIL_MCP_RULE_SOAK=<runs>`).

## Releases

Publishing a GitHub release `vX.Y.Z` runs `.github/workflows/release.yml`: tests, builds (universal), signs with the
Developer ID certificate, makes and notarizes `AppleMailMCP-X.Y.Z.dmg` and `AppleMailMCP-X.Y.Z.mcpb` (the Claude
extension, also signed with `mcpb sign`), attaches both, and publishes `server.json` to the MCP registry via GitHub
OIDC. The Homebrew cask in `mp-consulting/homebrew-tap` updates itself from the latest release every 6 hours. The menu bar app's
updater only installs that asset, notarized and signed by team 4HWBUF2R8D. Bump `MailMCPVersion.current`
and `CHANGELOG.md` first. Secrets: `DEVELOPER_ID_CERTIFICATE`, `DEVELOPER_ID_CERTIFICATE_PASSWORD`,
`APPLE_API_KEY`, `APPLE_API_KEY_ID`, `APPLE_API_ISSUER`.
