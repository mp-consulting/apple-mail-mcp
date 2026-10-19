// Generated from Skills/*/SKILL.md by Scripts/embed-skills.sh. Do not edit by hand.

extension SkillCatalog {
    static let embedded: [(folder: String, content: String)] = [
        ("mail-attachments", #"""
---
name: mail-attachments
description: Find, save and organize email attachments from Apple Mail (invoices, contracts, receipts, photos, PDFs), or export messages to files. Use when the user wants to download, save, collect or archive attachments or emails to a folder, or asks where a file someone sent them is.
---

# Attachments and exports

## Find

1. `search_messages` with `has_attachments: true` plus whatever the user knows: `sender`, `subject`,
   `days`/`date_from`, `query` (e.g. "invoice", "facture", "contract"). Page with `offset`.
2. `list_attachments` on each candidate to see file names, types and sizes. `downloaded: false` means
   Mail has not fetched that file yet: tell the user to open the message in Mail (`open_in_mail`) first.

## Save

- `save_attachment` with `id`, an optional `attachment` (part id or file name; omit to save them all) and a
  `directory` (default `~/Downloads`). Existing files are never overwritten: a numbered copy is made
  unless `overwrite: true`.
- To collect a set (e.g. all 2025 invoices), confirm the folder first, save message by message, and report
  every saved path at the end. Suggest a naming scheme if the user wants one; the server keeps the
  sender's original file names.
- Some locations are refused on purpose (startup folders, `~/Library`, dotfiles, `.git/hooks`): pick a
  normal folder such as `~/Documents/Invoices`.

## Invoices and receipts to a spreadsheet

1. Build one precise search, then check it with `search_messages` and `group_by: "sender"` (counts only):
   - `query: "invoice, facture, fatura, receipt, Rechnung"` (any term matches)
   - `direction: "received"` and `exclude_replies: true` to drop sent mail and replies
   - `exclude_subject` for ads and newsletters ("économisez, newsletter, webinar"), `exclude_sender` for
     noisy domains, `category: "transactions"` when Mail has classified them
   - `exclude_from_self: true` drops invoices the user issued (their own names are set in the app's settings)
2. `export_search` with the same filters, a `path` such as `~/Desktop/invoices.xlsx` (`csv`, `json` or `xlsx`)
   and `include: ["amount", "invoice_number"]`: one call writes every match with vendor, total, currency
   and invoice number (read from bodies and attached PDFs) and returns only the path and row count.
3. Report the row count and how many rows got an amount (`with_amount`). Rows with
   `amount_confidence: "low"` are worth a glance; `extract_invoice_fields` on a few ids shows why.

## Export messages

- `export_messages` with `ids` and a `directory`: `format: "eml"` keeps the original message (opens in
  any mail app, attachments included); `format: "markdown"` writes readable text for notes or sharing.

## Send files

- To email files: `compose_email` with `attachments` (absolute paths). Secrets such as `~/.ssh`, `.env`
  files, keychains or browser profiles can never be attached.

<!-- Installed by Apple Mail MCP (https://github.com/mp-consulting/apple-mail-mcp). -->

"""#),
        ("mail-follow-up", #"""
---
name: mail-follow-up
description: Find emails the user sent that never got an answer and draft polite follow-ups. Use when the user asks who hasn't replied, what they're waiting on, to chase or nudge people, or to follow up on sent mail.
---

# Follow-ups

## Steps

1. Call `awaiting_reply` with `days: 14` and `min_age_hours: 48` (adjust if the user names a period).
   Each result is the latest message the user sent in a conversation that nobody has answered.
2. Drop what does not need chasing: messages that only said thanks, FYI notes, and anything sent to
   automated addresses. If unsure, read it with `get_message` (`max_chars: 1500`).
3. Present the list: recipient, subject, sent date, days waiting, one-line summary of what was asked.
   Sort by importance first (requests, deadlines), then by age.
4. Ask which ones to follow up on. For each chosen one:
   - read the conversation with `get_thread` to get the context right,
   - draft a short nudge with `reply_to_message` (`mode: "draft"`, `quote_original: true`): one or two
     sentences, refer to the original ask, offer a concrete next step or a new date.
     Match the language of the original thread.
5. Offer to flag the originals (`update_messages`, `flag_color: "orange"`) so they show up as pending.
6. If the user would rather nudge later (say, if there is still no answer by Friday), offer to schedule the
   nudge with `reply_to_message` and `send_at`; it can be cancelled with `cancel_scheduled` if a reply
   arrives first.

## Rules

- Drafts only. Send only when the user explicitly says so, and then with `mode: "send"`.
- Never guilt-trip or invent deadlines; keep the tone friendly and brief.
- One follow-up per conversation; if a nudge was already sent recently (visible in `get_thread`), say so
  instead of drafting another.

<!-- Installed by Apple Mail MCP (https://github.com/mp-consulting/apple-mail-mcp). -->

"""#),
        ("mail-inbox-zero", #"""
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
      to the inbox, unread, on that day. If it reports that Mail did not keep the new mailbox, snooze into a
      folder that already exists (`mailbox`, e.g. an archive folder).

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

"""#),
        ("mail-newsletter-cleanup", #"""
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
  offer a rule for senders the user wants to keep but not see in the inbox. Once they agree, `create_rule`
  (e.g. `conditions: [{field: "from", value: "news@example.com"}]`, `move_to: "archive"`). If it comes back
  `saved: false`, tell the user to keep Mail open until `mail_setup` no longer lists it under `pending_rules`.
- **Undo**: if the user regrets a batch, `undo_change` with `action: "list"` shows recent changes and
  `action: "undo"` puts one back (the latest by default, or its `change_id`).

## Rules

- Never trash mail from people (category `primary`, personal addresses) as part of a bulk cleanup.
- Trash is recoverable; still, ask before trashing and prefer archive when in doubt.
- Report totals at the end: messages archived, trashed, senders unsubscribed.

<!-- Installed by Apple Mail MCP (https://github.com/mp-consulting/apple-mail-mcp). -->

"""#),
        ("mail-reply-writer", #"""
---
name: mail-reply-writer
description: Draft email replies in the user's own voice with Apple Mail. Use when the user asks to reply to, answer, respond to, or write back to an email, or to draft a response. Reads the whole thread and the user's past messages to the same person first; saves a draft rather than sending.
---

# Reply writer

## Gather context first

1. Identify the message. If the user describes it ("Anna's email about the invoice"), find it with
   `search_messages` (`sender`, `subject`, or `query`); confirm if several match.
2. Read the conversation with `get_thread` (`strip_quotes: true`). Note what was asked, by whom, and any
   dates, numbers or attachments that the reply must address.
3. Learn the user's voice with this correspondent: `search_messages` with `mailbox: "sent"` and
   `recipient` set to the other person's address, `limit: 5`, then `get_message` on two or three of them.
   Notice greeting, sign-off, length, formality and language. If there is no history, look at a few
   recent sent messages instead.

## Write

- Answer every question asked, in order. Be specific: dates, amounts, next steps.
- Same language as the incoming message; same level of formality as the user's past replies.
- Short paragraphs. No filler ("I hope this email finds you well") unless the user writes that way.
- Do not invent facts, commitments or availability. Leave clearly marked gaps like `[confirm date]` and
  tell the user.

## Save

1. Show the draft text to the user.
2. Save it with `reply_to_message` (`mode: "draft"`; `reply_all: true` only when others on the thread need
   the answer). The original is quoted below the reply automatically. Attach files with `attachments`
   (absolute paths) when the user provides them.
3. Use `mode: "open"` if the user wants to edit it in Mail, and `mode: "send"` only when the user
   explicitly asks to send. Sending may require the user's approval in the Apple Mail MCP menu bar app.
4. If the user wants it to go out later ("send it Monday morning"), pass `send_at` (an ISO 8601 time, or
   `YYYY-MM-DD` for 8:00 that day) instead of a mode; `list_scheduled` and `cancel_scheduled` show and
   cancel what is waiting.

Replying to an unsent draft is not possible: for drafts, offer `open_in_mail` instead.

<!-- Installed by Apple Mail MCP (https://github.com/mp-consulting/apple-mail-mcp). -->

"""#),
        ("mail-research", #"""
---
name: mail-research
description: Find information buried in Apple Mail and answer questions from it, with links back to the messages. Use when the user asks to find an email, look something up in their mail, recall what someone said, find a number, address, confirmation code or date, or summarize everything about a topic or person.
---

# Mail research

The server searches Mail's own index directly, so searches are fast even across tens of thousands of
messages. Good results come from narrowing first, then reading.

## Search strategy

1. **Start with structured filters**: `sender`, `recipient`, `subject`, `account`, `mailbox`,
   `date_from`/`date_to` or `days`, `has_attachments`, `flagged`, `category`. They are exact and instant.
2. **Then free text**: `query` matches subject, sender and Mail's preview snippet.
3. **Then the body**: `body` searches full message text. Use distinctive words; put exact phrases in
   double quotes (`"order number"`). If the result says `body_search: "scan"` with a note that the scan was
   limited, narrow by account, mailbox or date, or build the index (`body_index` with `action: "update"`).
4. **Page** with `offset` while `has_more` is true; the newest results come first (`sort: "oldest"` to flip).
5. **Try variants** when nothing matches: other spellings, the other language, the company domain as
   `sender` (e.g. `@acme.com`), or `include_trash: true`. Several words in `query`, comma-separated,
   match any of them.
6. **Cut the noise** with `exclude_subject`, `exclude_sender`, `exclude_replies: true` and
   `direction: "received"` or `"sent"`; `compact: true` drops previews when many results are expected.
7. **Too many results to read?** `group_by: "sender"`, `"domain"` or `"month"` returns counts instead of
   messages; `export_search` writes all matches to a file.
8. **Looking for a code, a parcel or a booking?** `extract_fields` reads them out of the matching messages:
   verification codes, tracking numbers with the carrier, booking and order references, flights with the
   route, and calendar invitations (`kinds` narrows it). For a code that has not arrived yet,
   `wait_for_mail` (with `sender` or `subject`) returns the message as soon as it lands.
9. **Looking for a person's address?** `find_contact` searches Contacts and the people the user wrote with.

## Read and answer

- Open the best candidates with `get_message` (`max_chars` around 4000) or the whole conversation with
  `get_thread`. To read many at once, `get_messages` takes up to 200 `ids` (it returns `remaining_ids`
  when the reply would get too large). Check attachments with `list_attachments`.
- Answer the question directly, then cite the source messages: sender, date, subject and the `link`
  (a `message://` URL that opens the message in Mail).
- For "everything about X", group findings by conversation and give a dated timeline with open items.
- Say clearly when something could not be found and what was searched.

## Rules

- Quote only the parts needed to answer; do not paste whole emails back.
- Never change or move messages during research unless asked.

<!-- Installed by Apple Mail MCP (https://github.com/mp-consulting/apple-mail-mcp). -->

"""#),
        ("mail-triage", #"""
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
   - mark the rest read or archive it (`update_messages` `read: true`, or `move_messages` to `archive`),
   - snooze what can wait until a given day (`snooze_messages` with `until`).
7. **Anything suspicious?** For a message asking to pay, sign in, change bank details or open an unexpected
   attachment, run `check_authenticity` on it before suggesting any action, and flag a `caution` or `fail`
   verdict to the user with its findings.

## Rules

- Never send anything during triage. Replies are drafts unless the user explicitly says "send".
- Before changing more than a handful of messages, show the list and ask. Use `dry_run: true` on
  `move_messages` and `trash_messages` to preview.
- Message ids change when messages move; use the `new_ids` that `move_messages` returns.
- Quote as little message content as possible in the summary; the user can open anything with `open_in_mail`.
- If `inbox_overview` fails with a Full Disk Access error, tell the user to grant Full Disk Access to the app
  that runs the MCP client (or to "Apple Mail MCP.app") and stop.

<!-- Installed by Apple Mail MCP (https://github.com/mp-consulting/apple-mail-mcp). -->

"""#),
        ("mail-weekly-report", #"""
---
name: mail-weekly-report
description: Weekly (or monthly) email report from Apple Mail - volume, who wrote most, what is still open, what the user is waiting on, and where the noise comes from. Use when the user asks for an email summary, report, recap, statistics, or how their week in email went.
---

# Weekly mail report

## Collect (all read-only, fast)

1. `mail_statistics` with `days: 7` (or the period the user asked for): received, unread, flagged,
   sent by the user, busiest days and hours, categories, top senders and domains.
2. `needs_response` with `days: 7`: conversations waiting on the user.
3. `awaiting_reply` with `days: 14`: conversations the user is waiting on.
4. `search_messages` with `flagged: true`, `limit: 20`: open flagged items.
5. Optional comparison: `mail_statistics` for the previous period (`days: 14`, minus this week) to show trends.

## Write the report

Keep it to one screen:

- **Headline numbers**: received, sent, unread now, flagged; change vs the previous period.
- **Needs your reply** (top 5): sender, subject, waiting since.
- **Waiting on others** (top 5): recipient, subject, days.
- **Who wrote most**: top 5 senders, marking which are people and which are automated.
- **Noise**: share of promotions/updates; suggest the `mail-newsletter-cleanup` skill if it is high.
- **Rhythm**: busiest day and hour, if notable.

End with two or three concrete suggestions (e.g. "3 replies older than 5 days", "archive 240 read
notifications"). Do not change any mail while reporting; offer the actions instead.

<!-- Installed by Apple Mail MCP (https://github.com/mp-consulting/apple-mail-mcp). -->

"""#),
    ]
}
