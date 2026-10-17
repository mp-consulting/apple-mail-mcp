import Foundation

/// Resolves account UUIDs to display names without asking Mail.
///
/// Names come from the system Accounts database (`Accounts4.sqlite`): the
/// account's description, else its parent's (iCloud mail accounts are children
/// of the "iCloud" account), else the username. Unknown accounts fall back to
/// the UUID, and "On My Mac" is named explicitly.
public enum AccountDirectory {
    public static func names(for accountIDs: Set<String>, accountsDatabase: URL?) -> [String: String] {
        var names: [String: String] = [:]
        if let accountsDatabase, FileManager.default.isReadableFile(atPath: accountsDatabase.path),
           let db = try? SQLiteConnection(path: accountsDatabase.path, readOnly: true)
        {
            let sql = """
                SELECT a.ZIDENTIFIER, a.ZACCOUNTDESCRIPTION, p.ZACCOUNTDESCRIPTION, a.ZUSERNAME
                FROM ZACCOUNT a LEFT JOIN ZACCOUNT p ON a.ZPARENTACCOUNT = p.Z_PK
                WHERE a.ZIDENTIFIER IS NOT NULL
                """
            try? db.query(sql) { row in
                let id = row.string(0)
                guard accountIDs.contains(id) else { return }
                let candidates = [row.optionalString(1), row.optionalString(2), row.optionalString(3)]
                if let name = candidates.compactMap({ $0 }).first(where: { !$0.isEmpty }) { names[id] = name }
            }
        }
        for id in accountIDs where names[id] == nil {
            names[id] = id
        }
        return names
    }
}
