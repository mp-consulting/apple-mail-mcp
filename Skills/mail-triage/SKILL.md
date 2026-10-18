---
name: mail-triage
description: Daily Apple Mail triage. Use when the user asks what's new in their mail, what needs their attention, to check or go through their inbox, or for a morning email review. Produces a prioritized list (reply, read, ignore) and offers to act on it.
---

# Mail triage

Turn an unread pile into a short, prioritized list the user can act on in a few minutes. Uses the
Apple Mail MCP server (`apple-mail`): reads are instant and never disturb Mail; changes go through Mail.

## Steps

1. **Overview.** Call `inbox_overview` (use `recent: 15`). Note unread totals per account and what is flagged.
2. **What needs a reply.** Call `needs_response` (`days: 7`). These are messages from people, addressed
   to the user, where the conversation is waiting on them. Lists, newsletters, promotions and no-reply
   senders are already excluded.
3. **Read before judging.** For each candidate that is not obvious from its preview, call `get_message`
   with `strip_quotes: true` and `max_chars: 2000`. For a long back-and-forth use `get_thread`.
4. **Sort into three buckets:**
   - **Reply needed**: a question, a request, a deadline, or a person waiting on the user.
   - **Worth reading**: relevant to the user, no action.
   - **Can wait or go**: notifications, receipts, automated mail (category `updates`/`promotions`/`transactions`).
5. **Present** a compact table per bucket: sender, subject, one-line why, age. Lead with the reply-needed
   items, most urgent first (explicit deadlines, then waiting longest). Keep it scannable, not an essay.
6. **Offer actions**, then wait for the user to choose:
   - draft replies (use the `mail-reply-writer` skill, or `reply_to_message` with `mode: "draft"`),
   - flag what needs follow-up (`update_messages` with `flag_color`),
   - mark the rest read or archive it (`update_messages` `read: true`, or `move_messages` to `archive`).

## Rules

- Never send anything during triage. Replies are drafts unless the user explicitly says "send".
- Before changing more than a handful of messages, show the list and ask. Use `dry_run: true` on
  `move_messages` and `trash_messages` to preview.
- Message ids change when messages move; use the `new_ids` that `move_messages` returns.
- Quote as little message content as possible in the summary; the user can open anything with `open_in_mail`.
- If `inbox_overview` fails with a Full Disk Access error, tell the user to grant Full Disk Access to the app
  that runs the MCP client (or to "Apple Mail MCP.app") and stop.

<!-- Installed by Apple Mail MCP (https://github.com/mp-consulting/apple-mail-mcp). -->
