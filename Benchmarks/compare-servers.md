## Apple Mail MCP vs other Apple Mail MCP servers

Same questions over real MCP stdio sessions, one server at a time, account with 82 313 messages (1 305 in its inbox). Median of 3 warm runs for Apple Mail MCP, 1 for the others (180 s timeout). Apple M1, 16 GB RAM, macOS Version 27.0.1 (Build 26A434), load average 102 at start.

– means the server has no tool for that question.

| Operation | **Apple Mail MCP** | Apple Mail MCP, no body index | imdinu 0.5.0 | ipsupport-llc 1.6.1 | jakobfigur 0.6.2 | jayvee6 0.1.0 | kiki830621 2.0.1 | mgcrea 1.28.0 | parasxos 1.8.0 | mcp-apple-mail (Python) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| List accounts | 2.7 ms | 1.3 ms | 6.9 ms | 320 ms | error | 1.71 s | 11 ms | error | – | 364 ms |
| Unread counts per mailbox | 4.2 ms | 1.3 ms | 1.61 s | error | – | – | 12 ms | 28.1 s | 94 ms | 5.29 s |
| Latest 20 inbox messages | 6.7 ms | 6.3 ms | 25 ms | error | error | 1.98 s | 931 ms | 2.85 s | 104 ms | 3.86 s |
| Subject search (inbox) | 5.2 ms | 4.7 ms | 64 ms | error | error | 1.57 s | 38 ms | 35 ms | 2.17 s | 1.72 s |
| Subject search (all mailboxes) | 22 ms | 8.0 ms | 56 ms | error | – | 4.44 s | 29 ms | 13 ms | 2.26 s | 5.47 s |
| Sender search (inbox) | 8.8 ms | 8.7 ms | 74 ms | error | 8.80 s | 3.28 s | 29 ms | 7.0 ms | 112 ms | 3.57 s |
| Body text search (inbox) | 3.2 ms | 45 ms | 69 ms | error | – | – | – | 1.58 s | 2.12 s | error |
| Conversation thread | 4.5 ms | 6.3 ms | – | error | – | – | – | 32 ms | 71 ms | 23.6 s |
| Top senders, 30 days | 4.4 ms | 3.7 ms | – | – | – | – | – | 7.2 ms | – | 56.7 s |
| Statistics, 30 days | 13 ms | 29 ms | – | – | – | – | – | – | – | 78.5 s |
| Awaiting reply, 7 days | 2.3 ms | 3.9 ms | – | error | – | – | – | – | – | 71.0 s |
| Needs response, 7 days | 3.2 ms | 5.7 ms | – | error | – | – | – | – | – | 11.1 s |
| Inbox overview | 12 ms | 14 ms | – | – | 1.75 s | – | – | – | – | 7.83 s |

### Response size

What the client has to read (and the model to take in), in KB.

| Operation | **Apple Mail MCP** | Apple Mail MCP, no body index | imdinu 0.5.0 | ipsupport-llc 1.6.1 | jakobfigur 0.6.2 | jayvee6 0.1.0 | kiki830621 2.0.1 | mgcrea 1.28.0 | parasxos 1.8.0 | mcp-apple-mail (Python) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| List accounts | 0.5 | 0.5 | 0.2 | 0.5 | error | 1.2 | 0.1 | error | – | 0.0 |
| Unread counts per mailbox | 3.6 | 3.6 | 2.2 | error | – | – | 3.7 | 7.6 | 20.9 | 0.2 |
| Latest 20 inbox messages | 10.6 | 10.6 | 3.8 | error | error | 6.0 | 3.3 | 5.1 | 29.7 | 10.2 |
| Subject search (inbox) | 3.0 | 3.0 | 5.6 | error | error | 3.0 | 6.1 | 2.7 | 28.2 | 2.0 |
| Subject search (all mailboxes) | 5.6 | 5.6 | 7.8 | error | – | 6.2 | 6.1 | 5.3 | 28.2 | 4.1 |
| Sender search (inbox) | 10.7 | 10.7 | 8.5 | error | 4.8 | 7.6 | 7.1 | 6.2 | 21.2 | 5.7 |
| Body text search (inbox) | 0.1 | 0.1 | 0.5 | error | – | – | – | 0.2 | 2.1 | error |
| Conversation thread | 2.6 | 2.6 | – | error | – | – | – | 0.8 | 2.0 | 1.2 |
| Top senders, 30 days | 1.2 | 1.2 | – | – | – | – | – | 3.1 | – | 0.8 |
| Statistics, 30 days | 2.0 | 2.0 | – | – | – | – | – | – | – | 1.2 |
| Awaiting reply, 7 days | 0.5 | 0.5 | – | error | – | – | – | – | – | 0.5 |
| Needs response, 7 days | 2.0 | 2.0 | – | error | – | – | – | – | – | 3.4 |
| Inbox overview | 8.0 | 8.0 | – | – | 2.8 | – | – | – | – | 5.2 |

Notes:
- Awaiting reply, 7 days, ipsupport-llc 1.6.1: Error: Mail did not answer within 25 s, so the call was stopped.
How to fix: Mail may be busy, showing a dialog, or waiting for an Automation permission prompt — check it on the Mac. Then try again, perhaps with a smaller limit or a narrower search.
- Body text search (inbox), ipsupport-llc 1.6.1: Error: Mail did not answer within 25 s, so the call was stopped.
How to fix: Mail may be busy, showing a dialog, or waiting for an Automation permission prompt — check it on the Mac. Then try again, perhaps with a smaller limit or a narrower search.
- Body text search (inbox), mcp-apple-mail (Python): Error calling tool 'search_emails': AppleScript execution timed out
- Conversation thread, ipsupport-llc 1.6.1: Error: Mail did not answer within 25 s, so the call was stopped.
How to fix: Mail may be busy, showing a dialog, or waiting for an Automation permission prompt — check it on the Mac. Then try again, perhaps with a smaller limit or a narrower search.
- Latest 20 inbox messages, ipsupport-llc 1.6.1: Error: Mail did not answer within 25 s, so the call was stopped.
How to fix: Mail may be busy, showing a dialog, or waiting for an Automation permission prompt — check it on the Mac. Then try again, perhaps with a smaller limit or a narrower search.
- Latest 20 inbox messages, jakobfigur 0.6.2: Apple Mail did not complete the request (timed out): No additional detail
- List accounts, jakobfigur 0.6.2: Apple Mail did not complete the request (timed out): No additional detail
- List accounts, mgcrea 1.28.0: {"error":"Mail did not answer within 30000ms. It may be mid-sync, or a permission prompt may be waiting on screen. Raise APPLE_MAIL_OSASCRIPT_TIMEOUT_MS if this is routine at your data size.","details":{"kind":"OsascriptTimeoutError"}}
- Needs response, 7 days, ipsupport-llc 1.6.1: Error: Mail did not answer within 25 s, so the call was stopped.
How to fix: Mail may be busy, showing a dialog, or waiting for an Automation permission prompt — check it on the Mac. Then try again, perhaps with a smaller limit or a narrower search.
- Sender search (inbox), ipsupport-llc 1.6.1: Error: Mail did not answer within 25 s, so the call was stopped.
How to fix: Mail may be busy, showing a dialog, or waiting for an Automation permission prompt — check it on the Mac. Then try again, perhaps with a smaller limit or a narrower search.
- Subject search (all mailboxes), ipsupport-llc 1.6.1: Error: Mail did not answer within 25 s, so the call was stopped.
How to fix: Mail may be busy, showing a dialog, or waiting for an Automation permission prompt — check it on the Mac. Then try again, perhaps with a smaller limit or a narrower search.
- Subject search (inbox), ipsupport-llc 1.6.1: Error: Mail did not answer within 25 s, so the call was stopped.
How to fix: Mail may be busy, showing a dialog, or waiting for an Automation permission prompt — check it on the Mac. Then try again, perhaps with a smaller limit or a narrower search.
- Subject search (inbox), jakobfigur 0.6.2: Apple Mail did not complete the request (timed out): No additional detail
- Unread counts per mailbox, ipsupport-llc 1.6.1: Error: Mail did not answer within 25 s, so the call was stopped.
How to fix: Mail may be busy, showing a dialog, or waiting for an Automation permission prompt — check it on the Mac. Then try again, perhaps with a smaller limit or a narrower search.
