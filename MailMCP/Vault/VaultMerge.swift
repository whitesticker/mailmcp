import Foundation

enum MergeChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case current
    case incoming

    var id: String { rawValue }

    var title: String {
        switch self {
        case .current: return "Keep current"
        case .incoming: return "Use incoming"
        }
    }
}

struct VaultAccountConflict: Identifiable, Hashable, Sendable {
    var id: String { key }
    var key: String
    var current: MailAccount
    var incoming: MailAccount
}

struct VaultMergePreview: Hashable, Sendable {
    var additions: [MailAccount]
    var onlyInCurrent: [MailAccount]
    var conflicts: [VaultAccountConflict]
    var settingsDiffer: Bool
    var currentSettings: AppSettings
    var incomingSettings: AppSettings
    var incomingName: String
    var incomingVaultID: UUID
    var currentName: String

    var isNoOp: Bool {
        additions.isEmpty && conflicts.isEmpty && !settingsDiffer
    }
}

enum VaultMerge {
    static func accountKey(_ account: MailAccount) -> String {
        "\(account.provider.rawValue)|\(account.email.lowercased())"
    }

    static func comparable(_ account: MailAccount) -> MailAccount {
        var copy = account
        copy.id = VaultPayload.unsignedID
        copy.createdAt = Date(timeIntervalSince1970: 0)
        copy.lastError = nil
        return copy
    }

    static func keyedAccounts(_ accounts: [MailAccount]) -> [String: MailAccount] {
        Dictionary(accounts.map { (accountKey($0), $0) }, uniquingKeysWith: { first, _ in first })
    }

    static func preview(current: VaultPayload, incoming: VaultPayload) -> VaultMergePreview {
        let currentByKey = keyedAccounts(current.accounts)
        let incomingByKey = keyedAccounts(incoming.accounts)
        let keys = Set(currentByKey.keys).union(incomingByKey.keys)

        var additions: [MailAccount] = []
        var onlyInCurrent: [MailAccount] = []
        var conflicts: [VaultAccountConflict] = []

        for key in keys.sorted() {
            let currentAccount = currentByKey[key]
            let incomingAccount = incomingByKey[key]
            switch (currentAccount, incomingAccount) {
            case let (current?, incoming?):
                if comparable(current) != comparable(incoming) {
                    conflicts.append(VaultAccountConflict(key: key, current: current, incoming: incoming))
                }
            case let (nil, incoming?):
                additions.append(incoming)
            case let (current?, nil):
                onlyInCurrent.append(current)
            case (nil, nil):
                break
            }
        }

        return VaultMergePreview(
            additions: additions,
            onlyInCurrent: onlyInCurrent,
            conflicts: conflicts,
            settingsDiffer: current.settings != incoming.settings,
            currentSettings: current.settings,
            incomingSettings: incoming.settings,
            incomingName: incoming.name,
            incomingVaultID: incoming.vaultID,
            currentName: current.name
        )
    }

    static func apply(
        current: VaultPayload,
        incoming: VaultPayload,
        accountChoices: [String: MergeChoice],
        settingsChoice: MergeChoice,
        includeAdditions: Bool = true
    ) -> VaultPayload {
        let incomingByKey = keyedAccounts(incoming.accounts)
        var ordered: [MailAccount] = []
        var seen = Set<String>()

        for account in current.accounts {
            let key = accountKey(account)
            seen.insert(key)
            if let incomingAccount = incomingByKey[key] {
                if comparable(account) == comparable(incomingAccount) {
                    ordered.append(account)
                } else {
                    let choice = accountChoices[key] ?? .current
                    ordered.append(choice == .incoming ? incomingAccount : account)
                }
            } else {
                ordered.append(account)
            }
        }

        if includeAdditions {
            for account in incoming.accounts {
                let key = accountKey(account)
                if seen.insert(key).inserted {
                    ordered.append(account)
                }
            }
        }

        var result = current
        result.accounts = ordered
        result.settings = settingsChoice == .incoming ? incoming.settings : current.settings
        result.generation += 1
        return result
    }
}

enum ExposedAccountResolver {
    static func resolve(idOrEmail: String?, accounts: [MailAccount]) throws -> MailAccount {
        if let idOrEmail, !idOrEmail.isEmpty {
            if let uuid = UUID(uuidString: idOrEmail),
               let account = accounts.first(where: { $0.id == uuid }) {
                return account
            }
            let matches = accounts.filter { $0.email.caseInsensitiveCompare(idOrEmail) == .orderedSame }
            if matches.count == 1 {
                return matches[0]
            }
            if matches.count > 1 {
                throw MailMCPError.ambiguousAccount(
                    "Multiple mailboxes match \(idOrEmail). Pass the account UUID from list_accounts."
                )
            }
            throw MailMCPError.accountNotFound
        }
        if accounts.count == 1 {
            return accounts[0]
        }
        throw MailMCPError.invalidInput("Pass account_id or account_email when more than one mailbox is configured.")
    }
}
