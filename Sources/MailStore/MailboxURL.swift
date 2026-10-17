import Foundation

/// Parses Mail's mailbox URLs (`imap://<account-uuid>/Archive/2020`,
/// `local://<uuid>/Outbox`, `ews://<uuid>/Inbox`).
public struct MailboxURL: Sendable, Hashable {
    public var scheme: String
    public var accountID: String
    /// Decoded path components below the account.
    public var components: [String]

    public var path: String { components.joined(separator: "/") }
    public var name: String { components.last ?? "" }

    public init?(_ string: String) {
        guard let schemeEnd = string.range(of: "://") else { return nil }
        scheme = String(string[..<schemeEnd.lowerBound])
        let rest = string[schemeEnd.upperBound...]
        let parts = rest.split(separator: "/", omittingEmptySubsequences: false)
        guard let account = parts.first, !account.isEmpty else { return nil }
        accountID = String(account)
        components = parts.dropFirst()
            .filter { !$0.isEmpty }
            .map { String($0).removingPercentEncoding.map(Self.precomposed) ?? String($0) }
    }

    /// Mail percent-encodes decomposed (NFD) Unicode; AppleScript names are precomposed.
    static func precomposed(_ s: String) -> String { s.precomposedStringWithCanonicalMapping }

    /// Folder of this mailbox under `~/Library/Mail/V10/<account>/`: each component gets `.mbox`.
    public var relativeDirectory: String {
        ([accountID] + components.map { $0 + ".mbox" }).joined(separator: "/")
    }
}

enum MailboxRoleDetector {
    private static let names: [MailboxRole: Set<String>] = [
        .inbox: ["inbox", "boîte de réception", "posteingang", "bandeja de entrada", "posta in arrivo"],
        .sent: [
            "sent", "sent messages", "sent items", "sent mail", "messages envoyés", "éléments envoyés",
            "envoyés", "gesendet", "gesendete elemente", "gesendete objekte", "enviados", "elementos enviados",
            "posta inviata", "inviata",
        ],
        .drafts: ["drafts", "draft", "brouillons", "entwürfe", "borradores", "bozze"],
        .trash: [
            "trash", "deleted messages", "deleted items", "bin", "corbeille", "éléments supprimés",
            "papierkorb", "gelöschte elemente", "papelera", "elementos eliminados", "cestino",
        ],
        .junk: [
            "junk", "spam", "junk email", "junk e-mail", "bulk mail", "courrier indésirable", "indésirables",
            "werbung", "spamverdacht", "correo no deseado", "posta indesiderata",
        ],
        .archive: ["archive", "archives", "archiv", "archivo", "archivio"],
        .outbox: ["outbox", "boîte d'envoi", "postausgang", "bandeja de salida", "posta in uscita"],
        .allMail: ["all mail", "tous les messages", "alle nachrichten", "todos", "tutti i messaggi"],
    ]

    static func role(for url: MailboxURL) -> MailboxRole {
        guard let last = url.components.last?.lowercased() else { return .other }
        // Only top-level folders, or folders under Gmail's [Gmail]/[Google Mail] container,
        // carry a system role: "Projects/Sent" is just a project folder.
        let depth = url.components.count
        let underGoogle = depth == 2 && url.components[0].hasPrefix("[G")
        guard depth == 1 || underGoogle else {
            // "Archive/2020" is still part of the archive.
            if let first = url.components.first?.lowercased(), names[.archive]!.contains(first) { return .archive }
            return .other
        }
        for (role, set) in names where set.contains(last) { return role }
        // "Deleted Messages (someone@example.com)" style local recovery folders.
        if last.hasPrefix("deleted messages") { return .trash }
        if last.hasPrefix("sent messages") { return .sent }
        return .other
    }
}
