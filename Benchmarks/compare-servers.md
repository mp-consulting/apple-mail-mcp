## Apple Mail MCP vs other Apple Mail MCP servers

Same questions over real MCP stdio sessions, account with 80 474 messages (1 323 in its inbox). Median of 5 warm runs for Apple Mail MCP, 1 for the others (180 s timeout). Servers that read Mail's files are called in turns, one call each per round, so they share the same conditions; those that use AppleScript run afterwards, one at a time. Apple M1, 16 GB RAM, macOS Version 27.0.1 (Build 26A434), load average 114 at start.

– means the server has no tool for that question.

| Operation | **Apple Mail MCP** | Apple Mail MCP, no body index | ipsupport-llc 1.6.1 | jakobfigur 0.6.2 | jayvee6 0.1.0 | kiki830621 2.0.1 | mcp-apple-mail (Python) |
|---|---:|---:|---:|---:|---:|---:|---:|
| List accounts | 0.8 ms | 0.7 ms | 4.87 s | error | error | timeout | 280 ms |
| Unread counts per mailbox | 1.6 ms | 1.6 ms | error | – | – | error | 5.18 s |
| Latest 20 inbox messages | 3.6 ms | 3.3 ms | 22.6 s | error | error | timeout | 3.87 s |
| Subject search (inbox) | 2.0 ms | 2.1 ms | 4.13 s | error | error | timeout | 1.56 s |
| Subject search (all mailboxes) | 2.6 ms | 3.5 ms | error | – | error | skipped | 5.12 s |
| Sender search (inbox) | 3.2 ms | 4.4 ms | 6.63 s | error | error | skipped | 3.45 s |
| Body text search (inbox) | 4.0 ms | 78 ms | error | – | – | – | error |
| Conversation thread | 7.7 ms | 6.6 ms | error | – | – | – | error |
| Top senders, 30 days | 1.5 ms | 1.7 ms | – | – | – | – | error |
| Statistics, 30 days | 8.7 ms | 17 ms | – | – | – | – | error |
| Awaiting reply, 7 days | 4.8 ms | 4.4 ms | error | – | – | – | error |
| Needs response, 7 days | 4.6 ms | 2.6 ms | error | – | – | – | error |
| Inbox overview | 11 ms | 11 ms | – | error | – | – | error |

### Response size

What the client has to read (and the model to take in), in KB.

| Operation | **Apple Mail MCP** | Apple Mail MCP, no body index | ipsupport-llc 1.6.1 | jakobfigur 0.6.2 | jayvee6 0.1.0 | kiki830621 2.0.1 | mcp-apple-mail (Python) |
|---|---:|---:|---:|---:|---:|---:|---:|
| List accounts | 0.5 | 0.5 | 0.5 | error | error | timeout | 0.0 |
| Unread counts per mailbox | 3.6 | 3.6 | error | – | – | error | 0.2 |
| Latest 20 inbox messages | 9.3 | 9.3 | 6.3 | error | error | timeout | 10.0 |
| Subject search (inbox) | 3.0 | 3.0 | 2.9 | error | error | timeout | 2.0 |
| Subject search (all mailboxes) | 5.6 | 5.6 | error | – | error | skipped | 4.1 |
| Sender search (inbox) | 11.1 | 11.1 | 6.5 | error | error | skipped | 5.6 |
| Body text search (inbox) | 0.1 | 0.1 | error | – | – | – | error |
| Conversation thread | 10.3 | 10.3 | error | – | – | – | error |
| Top senders, 30 days | 1.2 | 1.2 | – | – | – | – | error |
| Statistics, 30 days | 2.1 | 2.1 | – | – | – | – | error |
| Awaiting reply, 7 days | 0.5 | 0.5 | error | – | – | – | error |
| Needs response, 7 days | 1.6 | 1.6 | error | – | – | – | error |
| Inbox overview | 6.8 | 6.8 | – | error | – | – | error |

Notes:
- Awaiting reply, 7 days, ipsupport-llc 1.6.1: Error: Mail did not answer within 25 s, so the call was stopped.
How to fix: Mail may be busy, showing a dialog, or waiting for an Automation permission prompt — check it on the Mac. Then try again, perhaps with a smaller limit or a narrower search.
- Awaiting reply, 7 days, mcp-apple-mail (Python): Error calling tool 'get_awaiting_reply': AppleScript execution timed out
- Body text search (inbox), ipsupport-llc 1.6.1: Error: Mail did not answer within 25 s, so the call was stopped.
How to fix: Mail may be busy, showing a dialog, or waiting for an Automation permission prompt — check it on the Mac. Then try again, perhaps with a smaller limit or a narrower search.
- Body text search (inbox), mcp-apple-mail (Python): Error calling tool 'search_emails': AppleScript execution timed out
- Conversation thread, ipsupport-llc 1.6.1: Error: Mail did not answer within 25 s, so the call was stopped.
How to fix: Mail may be busy, showing a dialog, or waiting for an Automation permission prompt — check it on the Mac. Then try again, perhaps with a smaller limit or a narrower search.
- Conversation thread, mcp-apple-mail (Python): Error calling tool 'get_email_thread': AppleScript execution timed out
- Inbox overview, jakobfigur 0.6.2: Apple Mail did not complete the request (timed out): No additional detail
- Inbox overview, mcp-apple-mail (Python): Error calling tool 'get_inbox_overview': AppleScript execution timed out
- Latest 20 inbox messages, jakobfigur 0.6.2: Apple Mail did not complete the request (timed out): No additional detail
- Latest 20 inbox messages, jayvee6 0.1.0: Command failed: osascript /Users/mickael/.npm/_npx/bf6f8a38055c067c/node_modules/@jdot6/apple-mail-mcp/scripts/applescript/list_messages.applescript iCloud INBOX 1 20

- Latest 20 inbox messages, kiki830621 2.0.1: timeout after 180 s
- List accounts, jakobfigur 0.6.2: Apple Mail did not complete the request (timed out): No additional detail
- List accounts, jayvee6 0.1.0: Command failed: osascript /Users/mickael/.npm/_npx/bf6f8a38055c067c/node_modules/@jdot6/apple-mail-mcp/scripts/applescript/list_folders.applescript

- List accounts, kiki830621 2.0.1: timeout after 180 s
- Needs response, 7 days, ipsupport-llc 1.6.1: Error: Mail did not answer within 25 s, so the call was stopped.
How to fix: Mail may be busy, showing a dialog, or waiting for an Automation permission prompt — check it on the Mac. Then try again, perhaps with a smaller limit or a narrower search.
- Needs response, 7 days, mcp-apple-mail (Python): Error calling tool 'get_needs_response': AppleScript execution timed out
- Sender search (inbox), jakobfigur 0.6.2: Apple Mail did not complete the request (timed out): No additional detail
- Sender search (inbox), jayvee6 0.1.0: Command failed: osascript /Users/mickael/.npm/_npx/bf6f8a38055c067c/node_modules/@jdot6/apple-mail-mcp/scripts/applescript/search.applescript iCloud INBOX github    20

- Sender search (inbox), kiki830621 2.0.1: skipped after two timeouts in a row
- Statistics, 30 days, mcp-apple-mail (Python): Error calling tool 'get_statistics': AppleScript error: 395:407: execution error: Mail got an error: AppleEvent timed out. (-1712)
- Subject search (all mailboxes), ipsupport-llc 1.6.1: Error: Mail did not answer within 25 s, so the call was stopped.
How to fix: Mail may be busy, showing a dialog, or waiting for an Automation permission prompt — check it on the Mac. Then try again, perhaps with a smaller limit or a narrower search.
- Subject search (all mailboxes), jayvee6 0.1.0: Command failed: osascript /Users/mickael/.npm/_npx/bf6f8a38055c067c/node_modules/@jdot6/apple-mail-mcp/scripts/applescript/search.applescript iCloud ALL  invoice   20

- Subject search (all mailboxes), kiki830621 2.0.1: skipped after two timeouts in a row
- Subject search (inbox), jakobfigur 0.6.2: Apple Mail did not complete the request (timed out): No additional detail
- Subject search (inbox), jayvee6 0.1.0: Command failed: osascript /Users/mickael/.npm/_npx/bf6f8a38055c067c/node_modules/@jdot6/apple-mail-mcp/scripts/applescript/search.applescript iCloud INBOX  invoice   20

- Subject search (inbox), kiki830621 2.0.1: timeout after 180 s
- Top senders, 30 days, mcp-apple-mail (Python): Error calling tool 'get_top_senders': AppleScript error: 345:357: execution error: Mail got an error: AppleEvent timed out. (-1712)
- Unread counts per mailbox, ipsupport-llc 1.6.1: Error: Mail did not answer within 25 s, so the call was stopped.
How to fix: Mail may be busy, showing a dialog, or waiting for an Automation permission prompt — check it on the Mac. Then try again, perhaps with a smaller limit or a narrower search.
- Unread counts per mailbox, kiki830621 2.0.1: Error: AppleScript error (-1712): Mail got an error: AppleEvent timed out.
