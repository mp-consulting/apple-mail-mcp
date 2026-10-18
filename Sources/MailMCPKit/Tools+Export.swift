import Foundation
import MCP
import MailStore

extension MailToolbox {
    // MARK: Export

    /// Columns export_search can write, in the order they are documented.
    static let exportFields = [
        "date", "from_name", "from_address", "subject", "mailbox", "account", "unread", "flagged", "flag",
        "has_attachments", "attachment_names", "category", "id", "link", "message_id", "preview", "size",
        "vendor", "amount", "currency", "invoice_number", "amount_confidence", "amount_source", "pdf_names",
    ]
    static let defaultExportFields = [
        "date", "from_name", "from_address", "subject", "mailbox", "account", "unread", "flagged", "has_attachments",
        "attachment_names", "category", "id", "link",
    ]
    static let invoiceExportFields: Set<String> = ["amount", "currency", "invoice_number", "amount_confidence", "amount_source", "pdf_names"]

    var exportSearch: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "export_search", "Export search to a file",
                """
                Write every message matching the search_messages filters to one CSV, JSON or XLSX file and return \
                only the path and row count, so thousands of results never come back inline. `include` adds totals \
                and invoice numbers read from bodies and PDFs (as extract_invoice_fields does). Never overwrites \
                unless asked.
                """,
                Schema.object(
                    Self.filterSchema.merging([
                        "path": Schema.string("File to write, e.g. ~/Desktop/invoices.csv (default ~/Downloads/mail-export-<date>.<format>)"),
                        "format": Schema.string("csv (default, or from the path's extension), json or xlsx", enum: ExportFormat.allCases.map(\.rawValue)),
                        "fields": Schema.strings("Columns, in order: \(Self.exportFields.joined(separator: ", ")). Default: \(Self.defaultExportFields.joined(separator: ", "))"),
                        "include": Schema.strings("Extra columns: amount (adds amount, currency, amount_confidence), invoice_number"),
                        "dedupe": Schema.boolean("One row per Message-ID when a message sits in several mailboxes (default true)"),
                        "read_pdfs": Schema.boolean("For amounts, also read attached PDFs when the body has no clear total (default true)"),
                        "max_rows": Schema.integer("Stop after this many rows (default 50000, max 200000)", minimum: 1, maximum: 200_000),
                        "overwrite": Schema.boolean("Replace an existing file (default false: a numbered name is used)"),
                    ]) { a, _ in a }), kind: .fileWrite),
            kind: .fileWrite
        ) { arguments in
            let store = try self.store
            var query = try self.messageQuery(arguments)
            query.limit = 1

            // Format and destination: the extension always matches the content written.
            let requestedPath = try arguments.string("path")
            let pathExtension = requestedPath.map { ($0 as NSString).pathExtension.lowercased() } ?? ""
            let format: ExportFormat
            if let name = try arguments.string("format") {
                guard let value = ExportFormat(rawValue: name.lowercased()) else { throw ToolError("format must be csv, json or xlsx") }
                format = value
            } else {
                format = ExportFormat(rawValue: pathExtension) ?? .csv
            }
            let stamp = Self.fileStamp.string(from: Date())
            var target = try self.pathGuard.checkWrite(requestedPath ?? "~/Downloads/mail-export-\(stamp).\(format.rawValue)")
            if (target as NSString).pathExtension.lowercased() != format.rawValue { target += "." + format.rawValue }

            // Columns.
            var fields = try arguments.strings("fields").map { $0.lowercased() }
            if fields.isEmpty { fields = Self.defaultExportFields }
            for extra in try arguments.strings("include").map({ $0.lowercased() }) {
                switch extra {
                case "amount", "amounts", "total": fields += ["vendor", "amount", "currency", "amount_confidence"]
                case "invoice_number", "invoice_numbers": fields += ["invoice_number"]
                default: throw ToolError("include accepts amount and invoice_number")
                }
            }
            var seenField = Set<String>()
            fields = fields.filter { seenField.insert($0).inserted }
            if let unknown = fields.first(where: { !Self.exportFields.contains($0) }) {
                throw ToolError("unknown field \(unknown); use \(Self.exportFields.joined(separator: ", "))")
            }
            let wantsInvoice = fields.contains { Self.invoiceExportFields.contains($0) }
            let wantsAttachments = fields.contains("attachment_names")
            let readPDFs = try arguments.bool("read_pdfs") ?? true
            let dedupe = try arguments.bool("dedupe") ?? true
            let maxRows = min(200_000, max(1, try arguments.int("max_rows") ?? 50_000))

            // Rows, 500 envelopes at a time.
            let bodyIndex = self.searchIndex(for: query).index
            let matches = try store.allMatchingIDs(query, bodyIndex: bodyIndex, cap: dedupe ? maxRows * 2 : maxRows)
            var rows: [[Cell]] = []
            var seenMessages = Set<String>()
            var duplicates = 0
            var amounts = 0
            chunks: for start in stride(from: 0, to: matches.ids.count, by: 500) {
                var batch = try store.messages(ids: Array(matches.ids[start..<min(start + 500, matches.ids.count)]))
                if dedupe {
                    batch = batch.filter { message in
                        guard let key = message.messageIDHeader else { return true }
                        if seenMessages.insert(key).inserted { return true }
                        duplicates += 1
                        return false
                    }
                }
                let attachments = wantsAttachments ? try store.attachmentNames(ids: batch.map(\.id)) : [:]
                let invoices = wantsInvoice ? try store.invoiceFields(for: batch, readPDFs: readPDFs) : [:]
                for message in batch {
                    if rows.count >= maxRows { break chunks }
                    let invoice = invoices[message.id]
                    if invoice?.fields.total != nil { amounts += 1 }
                    rows.append(fields.map { Self.cell($0, message: message, attachments: attachments[message.id] ?? [], invoice: invoice) })
                }
            }

            let data = SpreadsheetWriter.data(format: format, columns: fields, rows: rows)
            let directory = (target as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let path = Self.destination(in: directory, name: (target as NSString).lastPathComponent, overwrite: try arguments.bool("overwrite") ?? false)
            _ = try self.pathGuard.checkWrite(path)
            try data.write(to: URL(filePath: path), options: .atomic)

            var notes: [JSON] = []
            if !matches.complete {
                notes.append(.string(
                    query.bodyText != nil && matches.bodySearchMode != "index"
                        ? "The body search stopped after scanning \(matches.scannedMessages) messages; build the body index (body_index action \"update\") for a complete export."
                        : "Stopped at max_rows; narrow the filters or raise max_rows."))
            } else if rows.count >= maxRows {
                notes.append(.string("Stopped at max_rows (\(maxRows)); narrow the filters or raise max_rows."))
            }
            let json = JSON.obj([
                ("path", .string(path)),
                ("format", .string(format.rawValue)),
                ("rows", .int(Int64(rows.count))),
                ("columns", .array(fields.map { .string($0) })),
                ("duplicates_skipped", duplicates > 0 ? .int(Int64(duplicates)) : nil),
                ("with_amount", wantsInvoice ? .int(Int64(amounts)) : nil),
                ("notes", notes.isEmpty ? nil : .array(notes)),
            ])
            return ToolReply(json: json, summary: "exported \(rows.count) rows")
        }
    }

    static let fileStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()

    /// Local date and time that sorts as text and reads well in a spreadsheet.
    static let cellDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    static func cell(_ field: String, message m: MessageSummary, attachments: [String], invoice: InvoiceResult?) -> Cell {
        func text(_ value: String?) -> Cell { value.map { $0.isEmpty ? .empty : .text($0) } ?? .empty }
        switch field {
        case "date": return .text(cellDate.string(from: m.dateReceived))
        case "from_name": return text(m.sender.name)
        case "from_address": return text(m.sender.address)
        case "subject": return text(m.subject)
        case "mailbox": return text(m.mailboxPath)
        case "account": return text(m.accountName)
        case "unread": return .bool(!m.isRead)
        case "flagged": return .bool(m.isFlagged)
        case "flag": return text(m.flagColor?.name)
        case "has_attachments": return .bool(m.hasAttachments)
        case "attachment_names": return text(attachments.joined(separator: "; "))
        case "category": return text(m.category?.name)
        case "id": return .number(String(m.id))
        case "link": return text(m.mailLink)
        case "message_id": return text(m.messageIDHeader)
        case "preview": return text(m.preview.map(Render.cleanPreview))
        case "size": return .number(String(m.size))
        case "vendor": return text(vendor(m.sender))
        case "amount": return invoice?.fields.total.map(Cell.number) ?? .empty
        case "currency": return text(invoice?.fields.currency)
        case "invoice_number": return text(invoice?.fields.invoiceNumber)
        case "amount_confidence": return text(invoice?.fields.confidence?.rawValue)
        case "amount_source": return text(invoice?.source)
        case "pdf_names": return text(invoice?.pdfNames.joined(separator: "; "))
        default: return .empty
        }
    }

    /// The sender's display name, else its domain without `www.`/mail subdomains' noise.
    static func vendor(_ sender: EmailAddress) -> String {
        if let name = sender.name, !name.isEmpty { return name }
        return sender.domain.hasPrefix("www.") ? String(sender.domain.dropFirst(4)) : sender.domain
    }

    // MARK: Batch read

    /// Characters of body text one get_messages call returns at most, so replies stay within client limits.
    static let batchCharacterBudget = 120_000

    var getMessages: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "get_messages", "Read several messages",
                """
                Read up to 200 messages in one call: envelope, recipients, attachment names and body text \
                (quotes stripped, 2000 characters each by default). When the reply would get too large it stops \
                early and lists the ids still to read in `remaining_ids`.
                """,
                Schema.object(
                    [
                        "ids": Schema.ids("Message ids (up to 200)"),
                        "max_chars": Schema.integer("Characters of body per message (default 2000, 0 = no body)", minimum: 0),
                        "strip_quotes": Schema.boolean("Drop quoted earlier messages from each body (default true)"),
                    ], required: ["ids"]), kind: .read),
            kind: .read
        ) { arguments in
            let store = try self.store
            let ids = try arguments.ids("ids")
            guard !ids.isEmpty, ids.count <= 200 else { throw ToolError("ids must contain 1 to 200 message ids") }
            let maxChars = try arguments.int("max_chars") ?? 2000
            let strip = try arguments.bool("strip_quotes") ?? true
            var items: [JSON] = []
            var missing: [Int64] = []
            var used = 0
            var remaining: [Int64] = []
            for (index, id) in ids.enumerated() {
                if used >= Self.batchCharacterBudget {
                    remaining = Array(ids[index...])
                    break
                }
                guard let detail = try? store.detail(id: id) else {
                    missing.append(id)
                    continue
                }
                let s = detail.summary
                var body: String?
                var truncated = false
                if maxChars > 0 {
                    var text = detail.bodyAvailable ? (detail.textBody ?? "") : (s.preview ?? "")
                    if strip { text = MessageContent.stripQuotedReply(text) }
                    let limit = min(maxChars, max(200, Self.batchCharacterBudget - used))
                    truncated = text.count > limit
                    body = Render.truncate(text, limit)
                    used += body?.count ?? 0
                }
                items.append(.obj([
                    ("id", .int(s.id)),
                    ("date", Render.date(s.dateReceived)),
                    ("from", .string(s.sender.formatted)),
                    ("to", Render.addresses(detail.to)),
                    ("cc", Render.addresses(detail.cc)),
                    ("subject", .string(s.subject)),
                    ("account", .string(s.accountName)),
                    ("mailbox", .string(s.mailboxPath)),
                    ("category", s.category.map { .string($0.name) }),
                    ("link", s.mailLink.map { .string($0) }),
                    ("attachments", detail.attachments.isEmpty ? nil : .array(detail.attachments.map { .string($0.filename) })),
                    ("body_downloaded", detail.bodyAvailable ? nil : .bool(false)),
                    ("body", body.map { .string($0) }),
                    ("body_truncated", truncated ? .bool(true) : nil),
                ]))
            }
            let json = JSON.obj([
                ("returned", .int(Int64(items.count))),
                ("messages", .array(items)),
                ("missing", missing.isEmpty ? nil : .array(missing.map { .int($0) })),
                ("remaining_ids", remaining.isEmpty ? nil : .array(remaining.map { .int($0) })),
            ])
            return ToolReply(json: json, summary: "read \(items.count) messages")
        }
    }

    // MARK: Invoices

    var extractInvoiceFields: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "extract_invoice_fields", "Extract invoice totals",
                """
                Vendor, invoice number, total and currency for invoice and receipt emails, read from the body \
                (and attached PDFs when the body has no clear total). Pass ids, or the search_messages filters \
                (up to 200 newest matches). For a spreadsheet of many invoices use export_search with \
                include ["amount", "invoice_number"].
                """,
                Schema.object(
                    Self.filterSchema.merging([
                        "ids": Schema.ids("Message ids (up to 200); omit to use the filters"),
                        "limit": Schema.integer("With filters: how many matches (default 50, max 200)", minimum: 1, maximum: 200),
                        "read_pdfs": Schema.boolean("Also read attached PDFs when the body has no clear total (default true)"),
                    ]) { a, _ in a }), kind: .read),
            kind: .read
        ) { arguments in
            let store = try self.store
            var ids = try arguments.ids("ids")
            if ids.isEmpty {
                var query = try self.messageQuery(arguments)
                query.limit = min(200, max(1, try arguments.int("limit") ?? 50))
                ids = try store.search(query, bodyIndex: self.searchIndex(for: query).index).messages.map(\.id)
            }
            guard ids.count <= 200 else { throw ToolError("ids must contain at most 200 message ids; use export_search for more") }
            let messages = try store.messages(ids: ids)
            let results = try store.invoiceFields(for: messages, readPDFs: try arguments.bool("read_pdfs") ?? true)
            let items: [JSON] = messages.map { m in
                let result = results[m.id]
                let fields = result?.fields ?? InvoiceFields()
                return .obj([
                    ("id", .int(m.id)),
                    ("date", Render.date(m.dateReceived)),
                    ("vendor", .string(Self.vendor(m.sender))),
                    ("subject", .string(m.subject)),
                    ("invoice_number", fields.invoiceNumber.map { .string($0) }),
                    ("total", fields.total.flatMap { Double($0) }.map { .double($0) }),
                    ("currency", fields.currency.map { .string($0) }),
                    ("confidence", fields.confidence.map { .string($0.rawValue) }),
                    ("source", result?.source.map { .string($0) }),
                    ("has_pdf", (result?.pdfNames.isEmpty ?? true) ? nil : .bool(true)),
                    ("pdf_names", (result?.pdfNames.isEmpty ?? true) ? nil : .array(result!.pdfNames.map { .string($0) })),
                    ("body_downloaded", result?.bodyAvailable ?? true ? nil : .bool(false)),
                    ("link", m.mailLink.map { .string($0) }),
                ])
            }
            let found = results.values.filter { $0.fields.total != nil }.count
            return ToolReply(
                json: .obj([("count", .int(Int64(items.count))), ("with_total", .int(Int64(found))), ("invoices", .array(items))]),
                summary: "\(found) of \(items.count) with a total")
        }
    }
}
