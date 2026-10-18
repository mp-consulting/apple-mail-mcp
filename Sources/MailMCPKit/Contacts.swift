import Contacts
import Foundation

/// A card from the user's Contacts.
public struct ContactCard: Sendable, Hashable {
    public var name: String
    public var organization: String?
    public var emails: [(label: String?, address: String)]

    public init(name: String, organization: String? = nil, emails: [(label: String?, address: String)]) {
        self.name = name
        self.organization = organization
        self.emails = emails
    }

    public static func == (a: ContactCard, b: ContactCard) -> Bool {
        a.name == b.name && a.organization == b.organization && a.emails.map(\.address) == b.emails.map(\.address)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(emails.map(\.address))
    }
}

public enum ContactsLookup: Sendable {
    case found([ContactCard])
    /// Contacts could not be read; the reason is shown to the model.
    case unavailable(String)
}

/// Where `find_contact` looks people up besides the mail history (tests use a fixed list).
public protocol ContactsProviding: Sendable {
    func search(_ text: String, limit: Int) async -> ContactsLookup
}

/// The user's Contacts, through Contacts.framework. Read-only; asks for access at most once.
public struct SystemContacts: ContactsProviding {
    public init() {}

    public func search(_ text: String, limit: Int) async -> ContactsLookup {
        let store = CNContactStore()
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized:
            break
        case .notDetermined:
            // Asking needs a usage description; without one macOS refuses, so do not ask from a bare binary.
            guard Bundle.main.object(forInfoDictionaryKey: "NSContactsUsageDescription") != nil,
                  (try? await store.requestAccess(for: .contacts)) == true
            else { return .unavailable(Self.hint) }
        default:
            return .unavailable(Self.hint)
        }
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName), CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]
        let predicate = text.contains("@")
            ? CNContact.predicateForContacts(matchingEmailAddress: text.trimmingCharacters(in: .whitespaces))
            : CNContact.predicateForContacts(matchingName: text)
        guard let contacts = try? store.unifiedContacts(matching: predicate, keysToFetch: keys) else {
            return .unavailable("Contacts could not be read.")
        }
        return .found(contacts.prefix(limit).compactMap { contact in
            let emails = contact.emailAddresses.map { labeled -> (label: String?, address: String) in
                (labeled.label.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) }, labeled.value as String)
            }
            let name = CNContactFormatter.string(from: contact, style: .fullName) ?? contact.organizationName
            guard !name.isEmpty else { return nil }
            return ContactCard(name: name, organization: contact.organizationName.isEmpty ? nil : contact.organizationName, emails: emails)
        })
    }

    static let hint = """
        Contacts are not available to this app (System Settings › Privacy & Security › Contacts); \
        only people from your mail history are listed.
        """
}
