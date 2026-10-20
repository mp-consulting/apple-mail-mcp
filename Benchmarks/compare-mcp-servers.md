## Apple Mail MCP vs other Apple Mail MCP servers

Same questions over real MCP stdio sessions, account with 80 551 messages (1 336 in its inbox). Median of 25 warm runs for Apple Mail MCP, 25 for the others (180 s timeout). Servers that read Mail's files are called in turns, one call each per round, so they share the same conditions; those that use AppleScript run afterwards, one at a time. Apple M1, 16 GB RAM, macOS Version 27.0.1 (Build 26A434), load average 18 at start.

– means the server has no tool for that question.

| Operation | **Apple Mail MCP** | Apple Mail MCP, no body index | imdinu 0.5.0 | mgcrea 1.28.0 | parasxos 1.8.0 |
|---|---:|---:|---:|---:|---:|
| List accounts | 0.4 ms | 0.3 ms | 1.8 ms | 0.5 ms | – |
| Unread counts per mailbox | 2.1 ms | 2.2 ms | 258 ms | 7.05 s | 76 ms |
| Latest 20 inbox messages | 2.8 ms | 3.0 ms | 20 ms | 2.85 s | 104 ms |
| Subject search (inbox) | 1.2 ms | 1.4 ms | 18 ms | 31 ms | 139 ms |
| Subject search (all mailboxes) | 3.4 ms | 3.1 ms | 24 ms | 6.8 ms | 258 ms |
| Sender search (inbox) | 2.8 ms | 2.6 ms | 23 ms | 3.5 ms | 78 ms |
| Body text search (inbox) | 2.1 ms | 27 ms | 6.5 ms | 1.17 s | 112 ms |
| Conversation thread | 3.3 ms | 3.1 ms | – | 29 ms | 13 ms |
| Top senders, 30 days | 1.9 ms | 2.1 ms | – | 3.1 ms | – |
| Statistics, 30 days | 11 ms | 10 ms | – | – | – |
| Awaiting reply, 7 days | 1.1 ms | 1.3 ms | – | – | – |
| Needs response, 7 days | 1.3 ms | 1.5 ms | – | – | – |
| Inbox overview | 3.9 ms | 4.2 ms | – | – | – |

### Response size

What the client has to read (and the model to take in), in KB.

| Operation | **Apple Mail MCP** | Apple Mail MCP, no body index | imdinu 0.5.0 | mgcrea 1.28.0 | parasxos 1.8.0 |
|---|---:|---:|---:|---:|---:|
| List accounts | 0.6 | 0.6 | 0.2 | 1.3 | – |
| Unread counts per mailbox | 3.6 | 3.6 | 2.2 | 7.6 | 20.9 |
| Latest 20 inbox messages | 8.8 | 8.8 | 3.7 | 5.0 | 21.3 |
| Subject search (inbox) | 3.0 | 3.0 | 5.6 | 2.7 | 28.4 |
| Subject search (all mailboxes) | 5.6 | 5.6 | 7.8 | 5.3 | 28.4 |
| Sender search (inbox) | 10.7 | 10.7 | 8.5 | 6.2 | 21.3 |
| Body text search (inbox) | 0.1 | 0.1 | 0.5 | 0.2 | 2.1 |
| Conversation thread | 10.3 | 10.3 | – | 1.3 | 5.4 |
| Top senders, 30 days | 1.2 | 1.2 | – | 3.1 | – |
| Statistics, 30 days | 2.1 | 2.1 | – | – | – |
| Awaiting reply, 7 days | 0.5 | 0.5 | – | – | – |
| Needs response, 7 days | 1.6 | 1.6 | – | – | – |
| Inbox overview | 6.2 | 6.2 | – | – | – |
