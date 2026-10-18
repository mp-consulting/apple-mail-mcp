---
name: mail-attachments
description: Find, save and organize email attachments from Apple Mail (invoices, contracts, receipts, photos, PDFs), or export messages to files. Use when the user wants to download, save, collect or archive attachments or emails to a folder, or asks where a file someone sent them is.
---

# Attachments and exports

## Find

1. `search_messages` with `has_attachments: true` plus whatever the user knows: `sender`, `subject`,
   `days`/`date_from`, `query` (e.g. "invoice", "facture", "contract"). Page with `offset`.
2. `list_attachments` on each candidate to see file names, types and sizes. `downloaded: false` means
   Mail has not fetched that file yet: tell the user to open the message in Mail (`open_in_mail`) first.

## Save

- `save_attachment` with `id`, an optional `attachment` (part id or file name; omit to save them all) and a
  `directory` (default `~/Downloads`). Existing files are never overwritten: a numbered copy is made
  unless `overwrite: true`.
- To collect a set (e.g. all 2025 invoices), confirm the folder first, save message by message, and report
  every saved path at the end. Suggest a naming scheme if the user wants one; the server keeps the
  sender's original file names.
- Some locations are refused on purpose (startup folders, `~/Library`, dotfiles, `.git/hooks`): pick a
  normal folder such as `~/Documents/Invoices`.

## Invoices and receipts to a spreadsheet

1. Build one precise search, then check it with `search_messages` and `group_by: "sender"` (counts only):
   - `query: "invoice, facture, fatura, receipt, Rechnung"` (any term matches)
   - `direction: "received"` and `exclude_replies: true` to drop sent mail and replies
   - `exclude_subject` for ads and newsletters ("économisez, newsletter, webinar"), `exclude_sender` for
     noisy domains, `category: "transactions"` when Mail has classified them
   - `exclude_from_self: true` drops invoices the user issued (their own names are set in the app's settings)
2. `export_search` with the same filters, a `path` such as `~/Desktop/invoices.xlsx` (`csv`, `json` or `xlsx`)
   and `include: ["amount", "invoice_number"]`: one call writes every match with vendor, total, currency
   and invoice number (read from bodies and attached PDFs) and returns only the path and row count.
3. Report the row count and how many rows got an amount (`with_amount`). Rows with
   `amount_confidence: "low"` are worth a glance; `extract_invoice_fields` on a few ids shows why.

## Export messages

- `export_messages` with `ids` and a `directory`: `format: "eml"` keeps the original message (opens in
  any mail app, attachments included); `format: "markdown"` writes readable text for notes or sharing.

## Send files

- To email files: `compose_email` with `attachments` (absolute paths). Secrets such as `~/.ssh`, `.env`
  files, keychains or browser profiles can never be attached.

<!-- Installed by Apple Mail MCP (https://github.com/mp-consulting/apple-mail-mcp). -->
