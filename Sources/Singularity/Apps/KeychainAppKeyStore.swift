import Foundation
import Security
import SingularityCore

/// The values of apps' keys, in the owner's login keychain: one "generic password" item per key,
/// all under the service name below. macOS ties an item to the app that made it, so another
/// program (an agent's shell in a terminal tab) can't read it without the owner being asked.
///
/// This is the one place key values are kept in a normal copy. It is a known exception to
/// "everything lives under ~/Singularity/" (decided by the owner, 2026-11-14). A copy started
/// with `SINGULARITY_HOME` uses `FileAppKeyStore` instead and never comes here.
final class KeychainAppKeyStore: AppKeyStore, @unchecked Sendable {   // no state of its own
    static let service = "dev.roosa.Singularity.app-keys"

    /// What identifies one item: our service and the key's address (Space id, app, name).
    private func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: account]
    }

    func value(space: UUID, app: String, name: String) -> String? {
        var query = query(account: AppKeyAddress.account(space: space, app: app, name: name))
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func set(_ value: String, space: UUID, app: String, name: String) throws {
        let query = query(account: AppKeyAddress.account(space: space, app: app, name: name))
        let data = Data(value.utf8)
        // Update the item if it exists, else add it.
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            // What Keychain Access shows as the item's name.
            item[kSecAttrLabel as String] = "Singularity app key: \(app) / \(name)"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: (SecCopyErrorMessageString(status, nil) as String?) ?? "The keychain refused (\(status)).",
            ])
        }
    }

    func delete(space: UUID, app: String, name: String) {
        SecItemDelete(query(account: AppKeyAddress.account(space: space, app: app, name: name)) as CFDictionary)
    }

    func deleteAll(space: UUID, app: String?) {
        // The keychain can't match "account starts with": list our items' accounts, then delete
        // the ones that belong to the app (or the Space).
        let all: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: Self.service,
                                  kSecReturnAttributes as String: true,
                                  kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        guard SecItemCopyMatching(all as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return }
        let prefix = AppKeyAddress.prefix(space: space, app: app)
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String, account.hasPrefix(prefix) else { continue }
            SecItemDelete(query(account: account) as CFDictionary)
        }
    }
}
