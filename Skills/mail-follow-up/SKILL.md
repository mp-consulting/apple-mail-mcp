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
