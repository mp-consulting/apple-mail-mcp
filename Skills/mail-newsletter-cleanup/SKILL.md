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
  the server limits each call (default 50). Make the calls one after another, never in parallel, and never
  run two cleanups (two agents or chats) at the same time.
- **Check every reply**: the counts only include messages Mail really moved. If a reply lists `unverified`
  ids or has `collateral_suspected`, stop at once, tell the user what it says and ask them to check Trash
  (and the mailbox it names) before doing anything else. Do not retry the same ids.
- **Unsubscribe**: pass one recent message per sender to `unsubscribe` with `dry_run: true` to see how
  each list unsubscribes (`one_click`, `email`, `link` or `none`), then, once the user agrees, call it without
  `dry_run`. One-click is used only for senders whose signature verified; for a `link`, give the user the
  `url` to open. Do not open web links yourself.
- **Prevent it next time**: check the user's existing rules with `mail_setup` (`include: ["rules"]`), then
  suggest a Mail rule (Mail → Settings → Rules) for senders the user wants to keep but not see in the inbox.
- **Undo**: if the user regrets a batch, `undo_change` with `action: "list"` shows recent changes and
  `action: "undo"` puts one back (the latest by default, or its `change_id`).

## Rules

- Never trash mail from people (category `primary`, personal addresses) as part of a bulk cleanup.
- Trash is recoverable; still, ask before trashing and prefer archive when in doubt.
- Report totals at the end: messages archived, trashed, senders unsubscribed.

<!-- Installed by Apple Mail MCP (https://github.com/mp-consulting/apple-mail-mcp). -->
