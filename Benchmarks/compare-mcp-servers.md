## Apple Mail MCP vs other Apple Mail MCP servers

Same questions over real MCP stdio sessions, account with 80 474 messages (1 323 in its inbox). Median of 25 warm runs for Apple Mail MCP, 25 for the others (180 s timeout). Servers that read Mail's files are called in turns, one call each per round, so they share the same conditions; those that use AppleScript run afterwards, one at a time. Apple M1, 16 GB RAM, macOS Version 27.0.1 (Build 26A434), load average 8 at start.

– means the server has no tool for that question.

| Operation | **Apple Mail MCP** | Apple Mail MCP, no body index | imdinu 0.5.0 | mgcrea 1.28.0 | parasxos 1.8.0 |
|---|---:|---:|---:|---:|---:|
| List accounts | 0.3 ms | 0.3 ms | 1.4 ms | 0.4 ms | – |
| Unread counts per mailbox | 1.1 ms | 0.9 ms | 257 ms | 13.5 s | 56 ms |
| Latest 20 inbox messages | 1.2 ms | 1.1 ms | 8.0 ms | 4.98 s | 95 ms |
| Subject search (inbox) | 0.7 ms | 0.6 ms | 11 ms | 21 ms | 90 ms |
| Subject search (all mailboxes) | 2.0 ms | 1.8 ms | 13 ms | 3.6 ms | 164 ms |
| Sender search (inbox) | 1.1 ms | 1.0 ms | 13 ms | 1.5 ms | 55 ms |
| Body text search (inbox) | 0.8 ms | 12 ms | 2.4 ms | 804 ms | 80 ms |
| Conversation thread | 1.4 ms | 1.2 ms | – | 20 ms | 5.5 ms |
| Top senders, 30 days | 1.0 ms | 1.0 ms | – | 1.9 ms | – |
| Statistics, 30 days | 5.9 ms | 5.9 ms | – | – | – |
| Awaiting reply, 7 days | 0.7 ms | 0.7 ms | – | – | – |
| Needs response, 7 days | 0.6 ms | 0.6 ms | – | – | – |
| Inbox overview | 2.7 ms | 2.7 ms | – | – | – |

### Response size

What the client has to read (and the model to take in), in KB.

| Operation | **Apple Mail MCP** | Apple Mail MCP, no body index | imdinu 0.5.0 | mgcrea 1.28.0 | parasxos 1.8.0 |
|---|---:|---:|---:|---:|---:|
| List accounts | 0.6 | 0.6 | 0.2 | 1.3 | – |
| Unread counts per mailbox | 3.6 | 3.6 | 2.2 | 7.6 | 20.9 |
| Latest 20 inbox messages | 9.3 | 9.3 | 3.7 | 5.0 | 23.9 |
| Subject search (inbox) | 3.0 | 3.0 | 5.6 | 2.7 | 27.4 |
| Subject search (all mailboxes) | 5.6 | 5.6 | 7.8 | 5.3 | 27.4 |
| Sender search (inbox) | 11.1 | 11.1 | 8.5 | 6.2 | 22.1 |
| Body text search (inbox) | 0.1 | 0.1 | 0.5 | 0.2 | 2.1 |
| Conversation thread | 10.3 | 10.3 | – | 1.3 | 5.4 |
| Top senders, 30 days | 1.2 | 1.2 | – | 3.1 | – |
| Statistics, 30 days | 2.1 | 2.1 | – | – | – |
| Awaiting reply, 7 days | 0.5 | 0.5 | – | – | – |
| Needs response, 7 days | 1.6 | 1.6 | – | – | – |
| Inbox overview | 6.8 | 6.8 | – | – | – |

Notes:
- Unread counts per mailbox, mgcrea 1.28.0: {"error":"Mail did not answer within 30000ms. It may be mid-sync, or a permission prompt may be waiting on screen. Raise APPLE_MAIL_OSASCRIPT_TIMEOUT_MS if this is routine at your data size.","details":{"kind":"OsascriptTimeoutError"}}
