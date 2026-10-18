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

Replying to an unsent draft is not possible: for drafts, offer `open_in_mail` instead.

<!-- Installed by Apple Mail MCP (https://github.com/mp-consulting/apple-mail-mcp). -->
