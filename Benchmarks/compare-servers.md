## Apple Mail MCP vs other Apple Mail MCP servers

Same questions over real MCP stdio sessions, account with 80 592 messages (1 337 in its inbox). Median of 1 warm runs for Apple Mail MCP, 1 for the others (180 s timeout). Servers that read Mail's files are called in turns, one call each per round, so they share the same conditions; those that use AppleScript run afterwards, one at a time. Apple M1, 16 GB RAM, macOS Version 27.0.1 (Build 26A434), load average 132 at start.

– means the server has no tool for that question.

| Operation | **Apple Mail MCP** | Apple Mail MCP, no body index | ipsupport-llc 1.6.1 | jakobfigur 0.6.2 | jayvee6 0.1.0 | kiki830621 2.0.1 | mcp-apple-mail (Python) |
|---|---:|---:|---:|---:|---:|---:|---:|
| List accounts | 0.8 ms | 2.6 ms | 170 ms | error | error | timeout | error |
| Unread counts per mailbox | 0.8 ms | 0.9 ms | 7.63 s | – | – | timeout | error |
| Latest 20 inbox messages | 1.4 ms | 1.4 ms | 10.7 s | error | error | skipped | error |
| Subject search (inbox) | 0.9 ms | 0.9 ms | 2.42 s | error | error | skipped | error |
| Subject search (all mailboxes) | 3.1 ms | 4.0 ms | error | – | error | skipped | error |
| Sender search (inbox) | 1.6 ms | 1.6 ms | 3.93 s | error | error | skipped | error |
| Body text search (inbox) | 2.6 ms | 47 ms | error | – | – | – | error |
| Conversation thread | 3.8 ms | 5.3 ms | error | – | – | – | 58.4 s |
| Top senders, 30 days | 5.4 ms | 4.5 ms | – | – | – | – | 14.9 s |
| Statistics, 30 days | 17 ms | 16 ms | – | – | – | – | 84.2 s |
| Awaiting reply, 7 days | 1.4 ms | 5.1 ms | error | – | – | – | error |
| Needs response, 7 days | 3.9 ms | 3.4 ms | error | – | – | – | 16.1 s |
| Inbox overview | 11 ms | 6.8 ms | – | error | – | – | 8.02 s |

### Response size

What the client has to read (and the model to take in), in KB.

| Operation | **Apple Mail MCP** | Apple Mail MCP, no body index | ipsupport-llc 1.6.1 | jakobfigur 0.6.2 | jayvee6 0.1.0 | kiki830621 2.0.1 | mcp-apple-mail (Python) |
|---|---:|---:|---:|---:|---:|---:|---:|
| List accounts | 0.5 | 0.5 | 0.5 | error | error | timeout | error |
| Unread counts per mailbox | 3.7 | 3.7 | 9.7 | – | – | timeout | error |
| Latest 20 inbox messages | 8.6 | 8.6 | 6.4 | error | error | skipped | error |
| Subject search (inbox) | 3.0 | 3.0 | 2.9 | error | error | skipped | error |
| Subject search (all mailboxes) | 5.6 | 5.6 | error | – | error | skipped | error |
| Sender search (inbox) | 10.7 | 10.7 | 6.6 | error | error | skipped | error |
| Body text search (inbox) | 0.1 | 0.1 | error | – | – | – | error |
| Conversation thread | 10.3 | 10.3 | error | – | – | – | 1.4 |
| Top senders, 30 days | 1.2 | 1.2 | – | – | – | – | 0.8 |
| Statistics, 30 days | 2.1 | 2.1 | – | – | – | – | 1.2 |
| Awaiting reply, 7 days | 0.5 | 0.5 | error | – | – | – | error |
| Needs response, 7 days | 0.4 | 0.4 | error | – | – | – | 3.3 |
| Inbox overview | 5.5 | 5.5 | – | error | – | – | 5.2 |

Notes:
- Awaiting reply, 7 days, ipsupport-llc 1.6.1: Error: Mail did not answer within 25 s, so the call was stopped.
How to fix: Mail may be busy, showing a dialog, or waiting for an Automation permission prompt — check it on the Mac. Then try again, perhaps with a smaller limit or a narrower search.
- Awaiting reply, 7 days, mcp-apple-mail (Python): Error calling tool 'get_awaiting_reply': AppleScript execution timed out
- Body text search (inbox), ipsupport-llc 1.6.1: Error: Mail did not answer within 25 s, so the call was stopped.
How to fix: Mail may be busy, showing a dialog, or waiting for an Automation permission prompt — check it on the Mac. Then try again, perhaps with a smaller limit or a narrower search.
- Body text search (inbox), mcp-apple-mail (Python): Error calling tool 'search_emails': AppleScript execution timed out
- Conversation thread, ipsupport-llc 1.6.1: Error: Mail did not answer within 25 s, so the call was stopped.
How to fix: Mail may be busy, showing a dialog, or waiting for an Automation permission prompt — check it on the Mac. Then try again, perhaps with a smaller limit or a narrower search.
- Inbox overview, jakobfigur 0.6.2: Apple Mail did not complete the request (timed out): No additional detail
- Latest 20 inbox messages, jakobfigur 0.6.2: Apple Mail did not complete the request (timed out): No additional detail
- Latest 20 inbox messages, jayvee6 0.1.0: Command failed: osascript /Users/mickael/.npm/_npx/bf6f8a38055c067c/node_modules/@jdot6/apple-mail-mcp/scripts/applescript/list_messages.applescript iCloud INBOX 1 20

- Latest 20 inbox messages, kiki830621 2.0.1: skipped after two timeouts in a row
- Latest 20 inbox messages, mcp-apple-mail (Python): Error calling tool 'list_inbox_emails': AppleScript error: 186:199: execution error: Mail got an error: AppleEvent timed out. (-1712)
- List accounts, jakobfigur 0.6.2: Apple Mail did not complete the request (timed out): No additional detail
- List accounts, jayvee6 0.1.0: Command failed: osascript /Users/mickael/.npm/_npx/bf6f8a38055c067c/node_modules/@jdot6/apple-mail-mcp/scripts/applescript/list_folders.applescript

- List accounts, kiki830621 2.0.1: timeout after 180 s
- List accounts, mcp-apple-mail (Python): Error calling tool 'list_accounts': AppleScript error: 115:128: execution error: Mail got an error: AppleEvent timed out. (-1712)
- Needs response, 7 days, ipsupport-llc 1.6.1: Error: Mail did not answer within 25 s, so the call was stopped.
How to fix: Mail may be busy, showing a dialog, or waiting for an Automation permission prompt — check it on the Mac. Then try again, perhaps with a smaller limit or a narrower search.
- Sender search (inbox), jakobfigur 0.6.2: Apple Mail did not complete the request (timed out): No additional detail
- Sender search (inbox), jayvee6 0.1.0: Command failed: osascript /Users/mickael/.npm/_npx/bf6f8a38055c067c/node_modules/@jdot6/apple-mail-mcp/scripts/applescript/search.applescript iCloud INBOX github    20

- Sender search (inbox), kiki830621 2.0.1: skipped after two timeouts in a row
- Sender search (inbox), mcp-apple-mail (Python): Error calling tool 'search_emails': AppleScript execution timed out
- Subject search (all mailboxes), ipsupport-llc 1.6.1: Error: Mail did not answer within 25 s, so the call was stopped.
How to fix: Mail may be busy, showing a dialog, or waiting for an Automation permission prompt — check it on the Mac. Then try again, perhaps with a smaller limit or a narrower search.
- Subject search (all mailboxes), jayvee6 0.1.0: Command failed: osascript /Users/mickael/.npm/_npx/bf6f8a38055c067c/node_modules/@jdot6/apple-mail-mcp/scripts/applescript/search.applescript iCloud ALL  invoice   20

- Subject search (all mailboxes), kiki830621 2.0.1: skipped after two timeouts in a row
- Subject search (all mailboxes), mcp-apple-mail (Python): Error calling tool 'search_emails': AppleScript execution timed out
- Subject search (inbox), jakobfigur 0.6.2: Apple Mail did not complete the request (timed out): No additional detail
- Subject search (inbox), jayvee6 0.1.0: Command failed: osascript /Users/mickael/.npm/_npx/bf6f8a38055c067c/node_modules/@jdot6/apple-mail-mcp/scripts/applescript/search.applescript iCloud INBOX  invoice   20

- Subject search (inbox), kiki830621 2.0.1: skipped after two timeouts in a row
- Subject search (inbox), mcp-apple-mail (Python): Error calling tool 'search_emails': AppleScript execution timed out
- Unread counts per mailbox, kiki830621 2.0.1: timeout after 180 s
- Unread counts per mailbox, mcp-apple-mail (Python): Error calling tool 'get_mailbox_unread_counts': AppleScript error: 113:126: execution error: Mail got an error: AppleEvent timed out. (-1712)
