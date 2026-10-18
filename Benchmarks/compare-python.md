## apple-mail-mcp (Swift) vs Python apple-mail-mcp

Same questions over real MCP stdio sessions, account with 81 646 messages (4 255 in its inbox).
Median of 3 warm runs for Swift, 1 for Python (180 s timeout). Apple M1, 16 GB RAM, macOS Version 27.0.1 (Build 26A434), load average 66 at start.

| Operation | Swift | Swift, no body index | Python (AppleScript) | Speed-up |
|---|---:|---:|---:|---:|
| List accounts | 23 ms | 23 ms | 1.23 s | 54× |
| Unread counts per mailbox | 21 ms | 25 ms | 5.20 s | 243× |
| Latest 20 inbox messages | 34 ms | 25 ms | 4.25 s | 126× |
| Subject search (inbox) | 48 ms | 48 ms | 4.99 s | 104× |
| Subject search (all mailboxes) | 173 ms | 152 ms | 7.43 s | 43× |
| Sender search (inbox) | 42 ms | 55 ms | 54.1 s | 1284× |
| Body text search (inbox) | 45 ms | 785 ms | timeout | Python failed |
| Conversation thread | 56 ms | 66 ms | error | Python failed |
| Top senders, 30 days | 16 ms | 15 ms | 38.5 s | 2449× |
| Statistics, 30 days | 38 ms | 37 ms | error | Python failed |
| Awaiting reply, 7 days | 45 ms | 47 ms | error | Python failed |
| Needs response, 7 days | 40 ms | 34 ms | error | Python failed |
| Inbox overview | 45 ms | 36 ms | error | Python failed |

Notes:
- Awaiting reply, 7 days: python: Error calling tool 'get_awaiting_reply': AppleScript execution timed out
- Body text search (inbox): python: timeout after 180 s
- Conversation thread: python: Error calling tool 'get_email_thread': AppleScript execution timed out
- Inbox overview: python: Error calling tool 'get_inbox_overview': AppleScript error: 582:595: execution error: Mail got an error: AppleEvent timed out. (-1712)
- Needs response, 7 days: python: Error calling tool 'get_needs_response': AppleScript execution timed out
- Statistics, 30 days: python: Error calling tool 'get_statistics': AppleScript execution timed out
