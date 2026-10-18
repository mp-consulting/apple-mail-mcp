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
