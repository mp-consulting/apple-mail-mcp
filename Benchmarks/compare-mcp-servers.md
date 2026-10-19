## Apple Mail MCP vs other Apple Mail MCP servers

Same questions over real MCP stdio sessions, account with 80 467 messages (1 316 in its inbox). Median of 25 warm runs for Apple Mail MCP, 25 for the others (180 s timeout). Servers that read Mail's files are called in turns, one call each per round, so they share the same conditions; those that use AppleScript run afterwards, one at a time. Apple M1, 16 GB RAM, macOS Version 27.0.1 (Build 26A434), load average 15 at start.

– means the server has no tool for that question.

| Operation | **Apple Mail MCP** | Apple Mail MCP, no body index | imdinu 0.5.0 | mgcrea 1.28.0 | parasxos 1.8.0 |
|---|---:|---:|---:|---:|---:|
| List accounts | 0.6 ms | 0.8 ms | 2.3 ms | 0.6 ms | – |
| Unread counts per mailbox | 1.3 ms | 1.1 ms | 216 ms | 22.8 s | 36 ms |
| Latest 20 inbox messages | 2.1 ms | 1.9 ms | 9.4 ms | 7.54 s | 75 ms |
| Subject search (inbox) | 1.4 ms | 1.2 ms | 12 ms | 25 ms | 105 ms |
| Subject search (all mailboxes) | 2.9 ms | 2.9 ms | 17 ms | 4.2 ms | 191 ms |
| Sender search (inbox) | 1.9 ms | 1.8 ms | 15 ms | 2.0 ms | 61 ms |
| Body text search (inbox) | 1.5 ms | 20 ms | 3.0 ms | 971 ms | 96 ms |
| Conversation thread | 2.1 ms | 1.8 ms | – | 22 ms | 5.8 ms |
| Top senders, 30 days | 1.9 ms | 1.8 ms | – | 2.2 ms | – |
| Statistics, 30 days | 8.6 ms | 8.6 ms | – | – | – |
| Awaiting reply, 7 days | 1.7 ms | 1.7 ms | – | – | – |
| Needs response, 7 days | 0.9 ms | 1.0 ms | – | – | – |
| Inbox overview | 3.4 ms | 3.4 ms | – | – | – |

### Response size

What the client has to read (and the model to take in), in KB.

| Operation | **Apple Mail MCP** | Apple Mail MCP, no body index | imdinu 0.5.0 | mgcrea 1.28.0 | parasxos 1.8.0 |
|---|---:|---:|---:|---:|---:|
| List accounts | 0.6 | 0.6 | 0.2 | 1.3 | – |
| Unread counts per mailbox | 3.6 | 3.6 | 2.2 | 7.6 | 20.9 |
| Latest 20 inbox messages | 10.5 | 10.5 | 3.8 | 5.1 | 29.6 |
| Subject search (inbox) | 3.0 | 3.0 | 5.6 | 2.7 | 28.2 |
| Subject search (all mailboxes) | 5.6 | 5.6 | 7.8 | 5.3 | 28.2 |
| Sender search (inbox) | 11.1 | 11.1 | 8.5 | 6.2 | 22.1 |
| Body text search (inbox) | 0.1 | 0.1 | 0.5 | 0.2 | 2.1 |
| Conversation thread | 10.3 | 10.3 | – | 1.3 | 5.4 |
| Top senders, 30 days | 1.2 | 1.2 | – | 3.1 | – |
| Statistics, 30 days | 2.1 | 2.1 | – | – | – |
| Awaiting reply, 7 days | 0.5 | 0.5 | – | – | – |
| Needs response, 7 days | 1.6 | 1.6 | – | – | – |
| Inbox overview | 7.6 | 7.6 | – | – | – |

Notes:
- Unread counts per mailbox, mgcrea 1.28.0: {"error":"Mail did not answer within 30000ms. It may be mid-sync, or a permission prompt may be waiting on screen. Raise APPLE_MAIL_OSASCRIPT_TIMEOUT_MS if this is routine at your data size.","details":{"kind":"OsascriptTimeoutError"}}
