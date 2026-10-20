# Plan: bulk trash hits the wrong message, and calls stall

Status: proposed · 2026-10-20 · affects 0.6.0 (`trash_messages`, likely `move_messages` and every per-message Apple Event)

## What happened

A live cleanup ran `trash_messages` on three iCloud IMAP mailboxes (`Archive/2005`, `Archive/2006` and
`Archive/2007`, with 250–500 messages each) in batches of 10–50 ids, sent back to back.

- 27 messages nobody asked for went to Trash (2005 alone: 8 + 10 + 6 in three batches). Each batch's
  `collateral_suspected` drop matched its stray count exactly.
- Every stray is the **date-neighbour** (the next-older message in the list) of a requested message
  reported as `unverified`. The requested message stayed where it was.
- Several calls exceeded the client's ~125 s timeout. Afterwards some of those calls finished on their own,
  and others queued behind them.
- `undo_change` could not have repaired it. The journal only holds `done` items, and the reply gave counts
  but no ids, so the strays had to be found by hand in Trash.

## Evidence from `activity.jsonl` (2026-10-20, 09:22–10:14 UTC, 48 calls)

- **The slow calls are the misfires.** All 20 `trash_messages` calls that took 26–28 s report `unverified`. All
  of the 1.6–2.7 s calls are clean. The Apple Events return quickly: the extra 25 s is
  `ChangeVerification.timeout` waiting for a requested message that Mail never removed, because it removed
  the neighbour.
- One call took **193.5 s** ("trashed 1, 9 unverified"): Mail itself blocked. The client gave up at about
  125 s, so the reply was lost.
- **Hung calls leave no trace.** Each line is written when a call *finishes*. Several calls the client timed out
  on (reads included: the searches at about 09:28, 09:34 and 10:16) have no line, so it can't tell whether they
  reached the server, waited on the lock, or are still running. Between 09:55 and 10:07 the server restarted
  (pid 38355 → 5288).
- **Detection is incomplete.** The 2006 calls at 09:49–09:55 flagged no `collateral_suspected`, yet 3 strays from
  those batches turned up in Trash. The strays left the source *after* `verdict()` had read its counts (the
  requested message's 25 s wait ends first).
- Older runs (18 Oct) show the 60 s ceiling: 6 `trash_messages` calls failed after 60.0–71.1 s with "Mail did
  not answer in time".

## Root cause (to confirm in phase 0)

1. **Index-based delete.** `MailAutomation.trash` sends `delete message id <rowid> of mailbox …` one id at a
   time. Cocoa scripting evaluates the delete through `-[NSObject(NSScriptingInternal)
   _scriptingRemoveObjectsAtIndexes:fromValueForKey:]` (the same path as in the 19 Oct crash report). The ID
   becomes an **index** into the mailbox's `messages` array, and the object at that index is what gets removed.
   On an IMAP mailbox with removals still in flight, the array Mail resolves against is out of step with the
   array it removes from, so the delete lands one position off: the neighbour goes and the target stays.
   This only happens under load, which explains why unit tests and small calls never show it.
2. **No pacing.** `forEach` fires the next event without waiting for the previous change to reach the
   database. Every in-flight removal widens the gap.
3. **Detection without identification.** `ChangeCheck.verdict` compares counts, so it knows *that* strays
   exist but not *which* ones. The strays are never journalled.
4. **Unbounded call time.** Each event may wait up to `eventTimeout` (60 s), then `applyVerified` waits up to
   25 + 1 s, all inside `exclusive` holding the automation lock. Ten ids can take more than ten minutes. The
   per-id loop ignores task cancellation, so a call the client has given up on keeps running and keeps the
   lock. `.canInteract` lets a Mail alert, such as an IMAP "couldn't move" sheet, block an event until
   someone dismisses it.

## Phase 0: reproduce before changing anything

Add `Tests/MailAutomationTests/TrashProbeTests.swift`, live and opt-in (`APPLE_MAIL_MCP_LIVE_TRASH=1`,
`APPLE_MAIL_MCP_PROBE_ACCOUNT=<IMAP account id>`), modelled on `RuleProbeTests`:

1. `createMailbox` a throwaway `MCP Probe <timestamp>` on the IMAP account. `copy` 40 messages into it from
   a mailbox the tester names.
2. **A, today's path:** `delete message id` for every second id, back to back. Record which Message-IDs left
   and which stayed.
3. **B:** the same, with each event waiting until the database shows the message gone.
4. **C:** `move … to <account Trash>` instead of `delete`.
5. **D:** a `whose message id = "<header>"` test specifier (phase 1) instead of `id`.
6. Print only counts and a stray count per variant (repo rule: no message content). Clean up the probe
   mailbox and its Trash copies at the end.

Exit criterion: A shows strays at a reproducible rate; D, and ideally B, show none. If A is clean, look at
the iCloud side before going further (Mail doing a server-side move by UID).

## Phase 1: address messages by Message-ID, not by `id`

- `AppleEvents.swift`: add `MailSpec.message(header:in:)`, which builds `every message of <mailbox> whose
  message id = "<header>"` (form `test`, a `cmpd` comparison on the `message id` property). Check its
  four-character code in `sdef /System/Applications/Mail.app` (expected `meid`) and pin it in
  `AppleEventTests`.
- `MailAutomating`: take `[MessageRef]` (`rowid`, `messageIDHeader?`) instead of `[Int64]` in `move`, `trash`,
  `copy`, `setState` and `setColor`. Update `RecordingAutomation` and the call sites in `Tools+Write`,
  `Tools+ApplyRules`, `Schedule` and `Tools+Undo`.
- Messages without a Message-ID: keep `id`, but first `get` the specifier's subject and date and compare
  them with the store's row, skipping the message on a mismatch. In a batch above 1, leave them as
  `not_attempted`, with a reason.
- Duplicate headers in the same mailbox (seen live: same `Message-ID` on 2 rows): `whose` matches both.
  Delete only when the store has exactly one live row for that header in the source. Otherwise fall back to
  the guarded `id` path.
- Measure the cost of `whose` on a 7 k and an 80 k mailbox in the probe. If it is too slow, send one event per
  batch with a list of test specifiers instead of N events.
- Decide `delete` vs `move to Trash` based on phase 0 variant C. If C is clean and as fast, use `move` for
  trash too, since the destination is then explicit.

## Phase 2: pace per message, with a time budget

- `applyVerified`: after each event, poll `ChangeCheck` for **that** message (short interval, cap about 10 s)
  before sending the next one. A message still in place by then is `unverified`, and the step stops: the
  remaining ids become `not_attempted` instead of being fired into a backlog.
- New `Settings.callBudget` (default 90 s, below the client timeout). Before each event, stop if
  `elapsed + eventTimeout + perMessageWait > callBudget`, and return `not_attempted` plus a `resume_ids` field.
- `MailEventSender`: use `eventTimeout` 20 s for message events. Send `[.waitForReply, .neverInteract]`
  everywhere except compose `.open`, so that an alert fails fast (-1713) instead of hanging.
- Activity log: write a `started` line when a call begins (same `id`; `finished` replaces it). Add
  `lockWaitMs`, `eventMs` (sum and max) and `verifyMs`, so a hang shows where it is stuck: lock, Mail or
  database. `doctor` lists calls that have been running for more than 2 minutes.
- Cancellation: check `Task.isCancelled` between ids in `MailAutomation.forEach`. Wire the MCP
  `notifications/cancelled` into the tool task, so a call the client gave up on stops and releases the lock.

## Phase 3: name the strays, journal them, and stop the next batch

- `ChangeCheck`: snapshot the source's `{header → [rowid]}` for the **whole mailbox**, not only the requested
  rows (this is cheap: one indexed query). Diff it in `verdict()` and return each stray as `{old_id, header,
  now_in, new_id}`. Put the list in `collateral_suspected.strays`.
- Journal the strays as their own `ChangeRecord` (`kind: .move`, `stray: true`), so `undo_change` can put back
  exactly those. Return its `stray_change_id`.
- Re-check late: strays can land after the requested message's wait ends (seen live). Take a second
  `verdict()` 5 s after the first, and once more at the start of the next change on the same mailbox,
  through the breaker below.
- New setting `restoreStrays` (default **on**): `applyVerified` moves the strays back at once, by header,
  verified the same way, and reports `strays_restored`.
- Circuit breaker: write `{account, mailbox, until}` to a shared file (next to the change journal) after
  `collateral_suspected` or `unverified`. `move`, `trash` and `apply_rules` on that mailbox refuse with a clear
  error until the unverified ids have settled (gone, or confirmed still there) or 2 minutes have passed.
  This works across processes, because the next call comes from a new tool call.

## Phase 4: tests, docs and release

- Unit tests (`MailMCPKitTests`, fixtures only):
  - `RecordingAutomation.onTrash` in "shift" mode removes the neighbour row. Test that `trashNamesStrays`,
    `straysAreRestored` and `strayChangeIsUndoable` all pass.
  - A slow `onTrash` triggers `callBudgetStopsEarly`.
  - A cancelled task triggers `cancellationStopsLoop`.
  - `breakerBlocksNextBatch` and `breakerClearsWhenSettled`.
- `AppleEventTests`: encoding of the `whose` specifier.
- `CLAUDE.md` › Mail facts: add *"Do not address messages by `id` for delete or move during bulk changes on
  IMAP: scripting resolves the id to an index and can remove the neighbour. Use `whose message id`."*
- Skills that mention trash or move: drop the "stop and ask the user to check Trash" step for strays that
  were restored, and keep it for strays that were not. Run `Scripts/embed-skills.sh`.
- `CHANGELOG.md` under Unreleased, then 0.6.1.

## Open questions

- Is `move` affected too? Every restore (`move` from Trash, 140 messages) was exact, but Trash was not
  shrinking while it ran. Phase 0 variant C will tell.
- One `group_by` search returned this morning's pre-cleanup counts, and later reads returned the real ones.
  Was that Mail resyncing the IMAP mailbox, or a stale read in `MailStore`? Check `refreshCachesIfNeeded`
  against `dataVersion` under heavy write load.
- The body index has a `index.db.malformed-20261019` copy: a separate issue, but worth a `doctor` check.
