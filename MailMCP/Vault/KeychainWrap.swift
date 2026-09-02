import Foundation
import LocalAuthentication
import Security

enum KeychainWrap {
    static let service = "com.mailmcp.app.vault"
    static let legacyAccount = "vault-kek"
    static let prompt = "Unlock your MailMCP vault"

    static func account(for vaultID: UUID) -> String {
        "vault-kek.\(vaultID.uuidString)"
    }

    static var presenceButtonTitle: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .touchID:
            return "Unlock with Touch ID"
        case .faceID:
            return "Unlock with Face ID"
        default:
            return "Unlock with Mac password"
        }
    }

    /// Device-local convenience wrap. Failure must not block vault create/unlock.
    @discardableResult
    static func storeKey(_ key: Data, vaultID: UUID, requirePresence: Bool = true) -> Bool {
        _ = deleteKey(vaultID: vaultID)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: vaultID),
            kSecValueData as String: key
        ]
        if requirePresence, let access = presenceAccessControl() {
            query[kSecAttrAccessControl as String] = access
        } else {
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    static func loadKey(vaultID: UUID) -> Data? {
        load(account: account(for: vaultID), allowPrompt: false)
    }

    static func purgeKnownItems(vaultIDs: [UUID]) {
        for id in vaultIDs {
            deleteKey(vaultID: id)
        }
        deleteLegacyKey()
    }

    @discardableResult
    static func deleteKey(vaultID: UUID) -> Bool {
        delete(account: account(for: vaultID))
    }

    static func loadLegacyKey() -> Data? {
        load(account: legacyAccount, allowPrompt: false)
    }

    @discardableResult
    static func deleteLegacyKey() -> Bool {
        delete(account: legacyAccount)
    }

    static func migrateLegacyKey(to vaultID: UUID) {
        guard let data = load(account: legacyAccount, allowPrompt: false) ?? loadLegacyKey() else { return }
        if load(account: account(for: vaultID), allowPrompt: false) == nil {
            _ = storeKey(data, vaultID: vaultID)
        }
        _ = deleteLegacyKey()
    }

    private static func presenceAccessControl() -> SecAccessControl? {
        SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            nil
        )
    }

    private static func load(account: String, allowPrompt: Bool) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if allowPrompt {
            let context = LAContext()
            context.localizedReason = prompt
            context.localizedCancelTitle = "Use passphrase"
            query[kSecUseAuthenticationContext as String] = context
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIAllow
        } else {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    @discardableResult
    private static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
