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
