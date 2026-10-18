## In-process timings on a real mailbox (83 636 messages)

Apple M1, 16 GB RAM, macOS Version 27.0.1 (Build 26A434), load average 143 at start

### MailStore

| Operation | Median | Min | Max |
|---|---:|---:|---:|
| Recent 20 in inbox | 22 ms | 15 ms | 28 ms |
| Unread in inbox (count + 50) | 4.1 ms | 1.5 ms | 7.1 ms |
| Subject search, all mailboxes | 258 ms | 185 ms | 377 ms |
| Sender search, all mailboxes | 159 ms | 64 ms | 316 ms |
| Flagged, all mailboxes | 15 ms | 9.9 ms | 23 ms |
| Read 20 full messages | 79 ms | 53 ms | 123 ms |
| Top senders, 30 days | 17 ms | 3.0 ms | 43 ms |
| Statistics, 30 days | 61 ms | 37 ms | 155 ms |
| Awaiting reply, 14 days | 119 ms | 95 ms | 215 ms |
| Needs response, 7 days | 13 ms | 9.3 ms | 21 ms |
| Body search, scan 2,000 newest | 855 ms | 499 ms | 1.13 s |
| Body search, full index | 24 ms | 17 ms | 80 ms |
