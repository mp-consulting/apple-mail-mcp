---
name: mail-newsletter-cleanup
description: Find the newsletters, promotions and notification senders that flood an Apple Mail inbox and clean them up in bulk, with unsubscribe links. Use when the user complains about too much mail, spam-like senders, newsletters, promotions, or wants to unsubscribe or declutter.
---

# Newsletter and bulk-mail cleanup

## Find the noise

1. Call `top_senders` with `days: 90`, `limit: 25` (and again with `by_domain: true`) to find who sends the
   most. Note unread counts: mail the user never opens is the best candidate.
2. Confirm what kind of mail it is with `search_messages` (`sender: …`, `limit: 3`): Mail's `category`
   (`promotions`, `updates`) and the `preview` tell newsletters apart from real people.
3. Also list what Mail itself classified: `search_messages` with `category: "promotions"`, `days: 90`.

Present one table: sender, messages in 90 days, unread %, category, suggested action
(keep / archive all / trash all / unsubscribe).

## Clean up (after the user picks)

- **Archive or trash a sender's mail**: page through `search_messages` (`sender`, `limit: 50`), preview
  with `dry_run: true`, then `move_messages` (`to_mailbox: "archive"`) or `trash_messages`. Repeat per page;
  the server limits each call (default 50).
- **Unsubscribe**: read one recent message's headers with `get_message_source` and look for
  `List-Unsubscribe` (a mailto: or https: link). Give the user the link to open; for a mailto: link,
  offer to draft the email with `compose_email` (`mode: "draft"`). Do not open web links yourself.
- **Prevent it next time**: suggest a Mail rule (Mail → Settings → Rules) for senders the user wants to keep
  but not see in the inbox.

## Rules

- Never trash mail from people (category `primary`, personal addresses) as part of a bulk cleanup.
- Trash is recoverable; still, ask before trashing and prefer archive when in doubt.
- Report totals at the end: messages archived, trashed, senders unsubscribed.

<!-- Installed by Apple Mail MCP (https://github.com/mp-consulting/apple-mail-mcp). -->
