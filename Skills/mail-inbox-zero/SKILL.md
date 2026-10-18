---
name: mail-inbox-zero
description: Bring an Apple Mail inbox to zero (or close) safely in batches. Use when the user wants to clean up, empty, declutter or process their whole inbox, archive old mail, or "get to inbox zero".
---

# Inbox zero

Process the inbox in batches: decide, preview, confirm, apply. Nothing is deleted permanently; the worst
outcome of a mistake is a message in Archive or Trash that can be moved back.

## Plan the batches

1. Call `list_mailboxes` for the account to learn the archive and project folder names
   (roles such as `archive`, `trash`, `junk` are listed).
2. Size the job with `search_messages` (`mailbox: "inbox"`, `limit: 1`): `total` is the inbox size.
3. Work from the cheapest decisions to the hardest:
   1. **Old and read**: `search_messages` with `mailbox: "inbox"`, `unread: false`, `date_to` 30+ days ago → archive.
   2. **Bulk mail**: `category: "promotions"` and `"updates"`, and the biggest senders from
      `top_senders` (`mailbox: "inbox"`, `days: 0`) → archive (or trash if the user says so).
   3. **Receipts and notifications**: `category: "transactions"` → archive.
   4. **What is left**: real conversations. Use `needs_response`; reply, flag or archive one by one. Mail
      that can wait until a given day can be snoozed with `snooze_messages` (`until`), which brings it back
      to the inbox, unread, on that day.

## For every batch

1. Collect ids with `search_messages` (page with `offset` when `has_more` is true).
2. Show the user what will happen: count, top senders, date range, destination.
3. Preview with `move_messages` / `trash_messages` and `dry_run: true`.
4. Apply only after the user agrees. Respect the server's per-call limit (default 50): split larger sets,
   and send the calls one after another, never in parallel or alongside another cleanup agent.
5. Check the reply: counts only include messages Mail really moved. If it lists `unverified` ids or has
   `collateral_suspected`, stop all batches, tell the user and ask them to check Trash (and the mailbox it
   names). Do not retry the same ids.
6. Report the outcome and the new totals.

## Rules

- Prefer archive over trash. Trash only bulk/promotional mail, and only with explicit agreement.
- Never touch flagged messages or anything from the last 3 days without asking.
- Keep a running tally (archived, trashed, flagged, left) and show it at the end.
- Ids change after a move; never reuse an old id. `move_messages` returns `new_ids`.
- Every move and trash reply has a `change_id`. If the user wants a batch back, `undo_change` with
  `action: "undo"` and that `change_id` restores it.
- If a call reports `not_found`, search again rather than guessing.

<!-- Installed by Apple Mail MCP (https://github.com/mp-consulting/apple-mail-mcp). -->
