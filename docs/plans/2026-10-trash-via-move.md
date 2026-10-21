# Plan: trash by moving to Trash, not by `delete`

Status: released in 0.6.2 and 0.6.4 (Gmail by `move`); the incident-sized iCloud run is pending · 2026-10-20 · follows `2026-10-trash-targets-wrong-message.md`

iCloud, 2026-10-21, quick pass (`Archive/2020`, 40 copies per variant, one round, no load): A 20/20 left, 0 strays
(12 ms per event); C 20/20, 0 strays (150 ms); D 21/21, 0 strays (23 ms); E not measured (Mail blocked 501 s while
its load mailboxes were made). A was clean, so at this size the probe does not reproduce the incident and C and D
prove nothing yet. Still to do: an incident-sized run (A and E, 200 copies, 2 rounds; or the plan's 200 × 5 for
A, C, D and E), recording D's result here, and `copiesLeftAfterRestore`. Released as 0.6.4 on the Gmail evidence
with this question open.

Gmail, settled on 2026-10-21 (`GmailTrashProbeTests`, a Gmail account holding 2,675 other messages, 20 drafts each
labelled INBOX and a probe label, from the All Mail row, by Message-ID, paced): `move` to `[Gmail]/Bin` and `delete`
gave the same result, at once and a minute later. All 10 + 10 in Bin, 0 left in All Mail, 0 still labelled INBOX
or probe; the draft rows stayed in `[Gmail]/Drafts` either way (a Gmail draft quirk). No other message left any
mailbox. Event time: move 556 ms average (max 1,282), delete 480 ms (max 555). So Gmail now trashes by `move` too,
and no `delete` is sent for a message anywhere.

Departures from the plan: an account with several Trash mailboxes uses the only one holding messages (the
probe had already seen a second, empty Trash) and is refused only when none or several hold messages; the extension
reports its build as `<commit>.mcpb`.

## What happened after 0.6.1

The same live cleanup continued at about 15:10 UTC, using `trash_messages` on the same iCloud IMAP account.

| Mailbox | Requested | Left | Unverified | Strays |
|---|---|---|---|---|
| `Archive/2007` (5, then 15) | 20 | 20 | 0 | 0 |
| `Archive/2006` | 14 | 12 | 2 | 0 |
| `Archive/2005` | 17 | 12 | 5 | **5** |

As in the first incident, each stray is the date-neighbour of an unverified message (the next older one, or
the one at about the same time). The 5 unverified targets: 3 had a Message-ID, and 2 had none (`id` fallback,
checked against subject and date). The strays were put back by hand with `move_messages`.

Every `move_messages` call today landed exactly on the requested messages: 24, 3, 23, 43, 44, 2 and 5 messages,
all moved out of Trash into `Archive/<year>`, with no stray and no unverified message.

## Finding 1: the client was probably not running 0.6.1

The replies don't match what 0.6.1's `applyVerified` would produce:

- After an unconfirmed message, 0.6.1 stops the call and the rest come back as `not_attempted`. Here both calls
  carried on: in 2006 the requested messages *after* the unverified ones (8th and 12th of 14) still left, and in
  2005 the call sent all 17.
- `collateral_suspected` had no `strays` list and no `stray_change_id`. Nothing was restored, although
  `restoreStrays` defaults to on.
- No `resume`, no `breaker` refusal on the next call to the same mailbox.

**Step 0:** before trusting any live result, make sure the Claude client launches the build you think it does.
The desktop app can run the `.mcpb` extension, `Contents/Helpers/Apple Mail MCP Server.app`, or a dev build.
To prevent this confusion in future:

- Add `server_version` (and the build's git hash) to the `initialize` result, to every `ToolReply` that
  changes mail, and to each `activity.jsonl` line. `doctor` lists, per client, the version it last saw.
- The menu bar app warns when a client used an older server than the installed one in the last hour.

## Finding 2: `whose` picks the right message, but `delete` can still remove the wrong row

0.6.1 sends `delete (every message of <mailbox> whose message id = "<header>")`. `NSDeleteCommand` still turns
the evaluated specifier into **indexes** and removes them through
`_scriptingRemoveObjectsAtIndexes:fromValueForKey:` on the mailbox's `messages` array. That is the step that
removed the neighbour in the first incident. `whose` fixes *which message is meant*, but not *which row the
removal hits* when the array Mail removes from has shifted. The header-less fallback (`get` subject and date by
`id`, then `delete` by `id`) has the same problem, plus a gap between check and act.

So 0.6.1 on its own probably narrows the window (one message at a time, paced) without closing it. Phase 0
variant D of `TrashProbeTests` is meant to show this. Run it before deciding.

## Change: `trash_messages` moves to the account's Trash

1. `MailAutomation.trash(_:in:)` becomes `move(_:from:to: trash)`: one `core/move` with `insh` = the account's
   Trash mailbox (`Mailbox.role == .trash`). No `core/delo` is sent for a message anywhere. Add an
   `AppleEventTests` check that the trash path never builds a `delo` event with a `mssg` direct object.
2. The destination is resolved in the tool, where `ChangeStep.destination` is already the Trash mailbox. With
   no single Trash (several, or none): refuse with a clear error, and don't fall back to `delete`.
3. Gmail accounts: `move` to `[Gmail]/Trash` is what Mail's own Delete does for Gmail. Confirm in the probe
   with a Gmail account that labels are dropped and All Mail keeps nothing extra, or keep the current path for
   Gmail only until then.
4. `mustArrive` becomes `true` for trash, so a trashed message counts only once it shows up in Trash, as for a
   move, and the destination check catches gains.
5. Keep from 0.6.1: Message-ID `whose` specifiers, one message at a time, waiting for each, the call budget,
   the strays diff, the breaker and restoring strays.

## Proving it on live Mail

Add variant **E** to `TrashProbeTests`: variant C (move by Message-ID to Trash, paced, as the new code does)
**under load**. While it runs, a second task moves 50 messages between two other probe mailboxes on the same
account, so iCloud sync is busy, as during the incident.

- Run A, C, D and E with `APPLE_MAIL_MCP_PROBE_COUNT=200`, 5 rounds each, on the iCloud account.
- Exit criterion: C and E show **0 strays and 0 unverified over all rounds**, and A shows strays (otherwise the
  probe doesn't reproduce the problem and proves nothing). Record D's result in this file: if D also shows
  strays, Finding 2 is confirmed.
- Also time E against today's trash path. If a move is much slower, lower the batch limit for trash rather
  than going back to `delete`.

## Side issue: copies left in Trash after a restore

Messages moved out of `Deleted Messages` today now exist twice: in `Archive/<year>`, and again in
`Deleted Messages`, where the old row came back, or a new row appeared minutes later. Examples: 2005 order
mail restored at 10:12 UTC reappeared in Trash with new ROWIDs before 15:10, and restored personal mail kept
its old Trash rows.

- Probe: after moving N messages out of Trash, count rows per Message-ID in both mailboxes at +0, +1, +5 and
  +15 minutes.
- Impact: emptying Trash is harmless, because the Archive copy survives. But `ChangeCheck.headerCounts` and
  `MessageRef(carriers:)` see two carriers when a mailbox holds a ghost, and fall back to the `id` path.
- `doctor`: report Message-IDs present both in Trash and in another mailbox of the same account.

## Tests, docs and release

- `MailMCPKitTests`: `trashMovesToTrashMailbox`, `trashRefusesWithoutSingleTrash`, `trashCountsOnlyArrived`,
  `noDeleteEventForMessages`, plus the existing strays, restore, breaker and budget tests ported to the move
  path.
- `CLAUDE.md` › Mail facts: *"`delete` removes by index even with a `whose` specifier: trash by `move` to the
  account's Trash."* Correct the 0.6.1 line if it says `whose` is enough.
- Skills: no change in wording ("move to Trash"). Re-run `Scripts/embed-skills.sh` if any `SKILL.md` changes.
- `CHANGELOG.md`, then 0.6.2. Confirm Step 0 (the client runs 0.6.2) before the next live cleanup.
