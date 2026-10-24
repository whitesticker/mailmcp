import Foundation

enum MailProviderKind: String, Codable, CaseIterable, Identifiable {
    case gmail
    case outlook
    case imap

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gmail: return "Gmail"
        case .outlook: return "Outlook / Microsoft 365"
        case .imap: return "IMAP / SMTP"
        }
    }
}

enum SafetyMode: String, Codable, CaseIterable, Identifiable {
    case readOnly
    case drafts
    case send

    var id: String { rawValue }

    var title: String {
        switch self {
        case .readOnly: return "Read only"
        case .drafts: return "Read + drafts + organize"
        case .send: return "Read + drafts + send"
        }
    }

    var allowsOrganize: Bool { self != .readOnly }
    var allowsDrafts: Bool { self != .readOnly }
    var allowsSend: Bool { self == .send }
}

enum CacheSyncMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case lazy
    case rollingWindow
    case timeWindow
    case fullSync

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lazy: return "Lazy sync (on-demand when agent calls MCP)"
        case .rollingWindow: return "Rolling window (latest N messages)"
        case .timeWindow: return "Past X days"
        case .fullSync: return "Full mailbox sync"
        }
    }

    var isProactive: Bool {
        self != .lazy
    }
}

enum AccountSyncScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case off
    case recent
    case days
    case everything

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off (lazy caching only)"
        case .recent: return "Most recent messages"
        case .days: return "Past X days"
        case .everything: return "Everything"
        }
    }

    var mode: CacheSyncMode {
        switch self {
        case .off: return .lazy
        case .recent: return .rollingWindow
        case .days: return .timeWindow
        case .everything: return .fullSync
        }
    }
}

enum AccountSyncSchedule: String, Codable, CaseIterable, Identifiable, Sendable {
    case manual
    case every15Minutes
    case every30Minutes
    case hourly
    case every6Hours
    case daily

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: return "Manual only"
        case .every15Minutes: return "Every 15 minutes"
        case .every30Minutes: return "Every 30 minutes"
        case .hourly: return "Every hour"
        case .every6Hours: return "Every 6 hours"
        case .daily: return "Daily"
        }
    }

    var interval: TimeInterval? {
        switch self {
        case .manual: return nil
        case .every15Minutes: return 15 * 60
        case .every30Minutes: return 30 * 60
        case .hourly: return 3_600
        case .every6Hours: return 6 * 3_600
        case .daily: return 86_400
        }
    }
}

struct CacheSyncPolicy: Codable, Hashable, Sendable {
    /// Global lazy-caching switch; per-account background sync works regardless.
    var enabled: Bool
    var mode: CacheSyncMode
    var rollingCount: Int
    var daysBack: Int
    var cooldownSeconds: Int
    var fullSyncBodies: Bool
    var dailyBandwidthCapMB: Int
    /// 0 means unlimited.
    var lazyCacheCapMB: Int
    var pauseAutoSyncOnBattery: Bool

    static let `default` = CacheSyncPolicy(
        enabled: true,
        mode: .lazy,
        rollingCount: 500,
        daysBack: 90,
        cooldownSeconds: 60,
        fullSyncBodies: true,
        dailyBandwidthCapMB: 1500,
        lazyCacheCapMB: 1024,
        pauseAutoSyncOnBattery: true
    )

    init(
        enabled: Bool = true,
        mode: CacheSyncMode = .lazy,
        rollingCount: Int = 500,
        daysBack: Int = 90,
        cooldownSeconds: Int = 60,
        fullSyncBodies: Bool = true,
        dailyBandwidthCapMB: Int = 1500,
        lazyCacheCapMB: Int = 1024,
        pauseAutoSyncOnBattery: Bool = true
    ) {
        self.enabled = enabled
        self.mode = mode
        self.rollingCount = rollingCount
        self.daysBack = daysBack
        self.cooldownSeconds = cooldownSeconds
        self.fullSyncBodies = fullSyncBodies
        self.dailyBandwidthCapMB = dailyBandwidthCapMB
        self.lazyCacheCapMB = lazyCacheCapMB
        self.pauseAutoSyncOnBattery = pauseAutoSyncOnBattery
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        mode = try container.decodeIfPresent(CacheSyncMode.self, forKey: .mode) ?? .lazy
        rollingCount = try container.decodeIfPresent(Int.self, forKey: .rollingCount) ?? 500
        daysBack = try container.decodeIfPresent(Int.self, forKey: .daysBack) ?? 90
        cooldownSeconds = try container.decodeIfPresent(Int.self, forKey: .cooldownSeconds) ?? 60
        fullSyncBodies = try container.decodeIfPresent(Bool.self, forKey: .fullSyncBodies) ?? true
        dailyBandwidthCapMB = try container.decodeIfPresent(Int.self, forKey: .dailyBandwidthCapMB) ?? 1500
        lazyCacheCapMB = try container.decodeIfPresent(Int.self, forKey: .lazyCacheCapMB) ?? 1024
        pauseAutoSyncOnBattery = try container.decodeIfPresent(Bool.self, forKey: .pauseAutoSyncOnBattery) ?? true
    }

    var lazyEnabled: Bool { enabled }

    var cacheActive: Bool { enabled || mode.isProactive }

    var lazyCacheCapBytes: Int64? {
        lazyCacheCapMB > 0 ? Int64(lazyCacheCapMB) * 1_048_576 : nil
    }

    var targetLimitPerFolder: Int {
        switch mode {
        case .lazy:
            return min(max(rollingCount, 50), 5_000)
        case .rollingWindow:
            return min(max(rollingCount, 50), 5_000)
        case .timeWindow:
            return 2_500
        case .fullSync:
            return 25_000
        }
    }

    var cutoffDate: Date? {
        guard mode == .timeWindow else { return nil }
        return Date().addingTimeInterval(-Double(max(daysBack, 1)) * 86_400)
    }

    var dailyBandwidthCapBytes: Int64 {
        Int64(max(dailyBandwidthCapMB, 100)) * 1_048_576
    }

    func effective(for account: MailAccount) -> CacheSyncPolicy {
        var resolved = self
        resolved.mode = account.syncScope.mode
        resolved.rollingCount = account.syncRecentCount
        resolved.daysBack = account.syncDaysBack
        resolved.fullSyncBodies = account.fullSyncBodies
        return resolved
    }
}

struct OAuthTokens: Codable, Hashable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var scopes: [String]
    var tokenEndpoint: String
    var clientID: String
    var clientSecret: String?

    var isAccessTokenExpired: Bool {
        guard let expiresAt else { return true }
        return expiresAt.timeIntervalSinceNow < 60
    }
}

struct IMAPSettings: Codable, Hashable, Sendable {
    var imapHost: String
    var imapPort: Int
    var imapStartTLS: Bool
    var smtpHost: String
    var smtpPort: Int
    var smtpStartTLS: Bool
    var username: String
    var password: String

    func resolvingBlankHosts(for email: String) throws -> IMAPSettings {
        var resolved = self
        let domain = email.split(separator: "@").last.map(String.init)?.lowercased() ?? ""
        guard !domain.isEmpty else {
            throw MailMCPError.invalidInput("Enter a valid email address.")
        }

        let known: [String: (imap: String, smtp: String, smtpPort: Int, smtpStartTLS: Bool)] = [
            "gmail.com": ("imap.gmail.com", "smtp.gmail.com", 465, false),
            "googlemail.com": ("imap.gmail.com", "smtp.gmail.com", 465, false),
            "icloud.com": ("imap.mail.me.com", "smtp.mail.me.com", 587, true),
            "me.com": ("imap.mail.me.com", "smtp.mail.me.com", 587, true),
            "mac.com": ("imap.mail.me.com", "smtp.mail.me.com", 587, true),
            "fastmail.com": ("imap.fastmail.com", "smtp.fastmail.com", 465, false),
            "yahoo.com": ("imap.mail.yahoo.com", "smtp.mail.yahoo.com", 465, false),
            "outlook.com": ("outlook.office365.com", "smtp.office365.com", 587, true),
            "hotmail.com": ("outlook.office365.com", "smtp.office365.com", 587, true),
            "live.com": ("outlook.office365.com", "smtp.office365.com", 587, true)
        ]
        let defaults = known[domain] ?? ("imap.\(domain)", "smtp.\(domain)", 465, false)

        if resolved.imapHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolved.imapHost = defaults.imap
        }
        if resolved.smtpHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolved.smtpHost = defaults.smtp
            resolved.smtpPort = defaults.smtpPort
            resolved.smtpStartTLS = defaults.smtpStartTLS
        }
        guard (1...65535).contains(resolved.imapPort),
              (1...65535).contains(resolved.smtpPort) else {
            throw MailMCPError.invalidInput("Ports must be between 1 and 65535.")
        }
        return resolved
    }
}

struct MailAccount: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var provider: MailProviderKind
    var email: String
    var displayName: String
    var oauth: OAuthTokens?
    var imap: IMAPSettings?
    var lastError: String?
    var createdAt: Date
    var syncScope: AccountSyncScope
    var syncRecentCount: Int
    var syncDaysBack: Int
    var syncSchedule: AccountSyncSchedule
    var fullSyncBodies: Bool

    init(
        id: UUID = UUID(),
        provider: MailProviderKind,
        email: String,
        displayName: String = "",
        oauth: OAuthTokens? = nil,
        imap: IMAPSettings? = nil,
        lastError: String? = nil,
        createdAt: Date = Date(),
        syncScope: AccountSyncScope = .off,
        syncRecentCount: Int = 500,
        syncDaysBack: Int = 90,
        syncSchedule: AccountSyncSchedule = .manual,
        fullSyncBodies: Bool = true
    ) {
        self.id = id
        self.provider = provider
        self.email = email
        self.displayName = displayName
        self.oauth = oauth
        self.imap = imap
        self.lastError = lastError
        self.createdAt = createdAt
        self.syncScope = syncScope
        self.syncRecentCount = syncRecentCount
        self.syncDaysBack = syncDaysBack
        self.syncSchedule = syncSchedule
        self.fullSyncBodies = fullSyncBodies
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case cacheOverride
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        provider = try container.decode(MailProviderKind.self, forKey: .provider)
        email = try container.decode(String.self, forKey: .email)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        oauth = try container.decodeIfPresent(OAuthTokens.self, forKey: .oauth)
        imap = try container.decodeIfPresent(IMAPSettings.self, forKey: .imap)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        if let scope = try container.decodeIfPresent(AccountSyncScope.self, forKey: .syncScope) {
            syncScope = scope
        } else {
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            switch try legacy.decodeIfPresent(String.self, forKey: .cacheOverride) {
            case "rollingWindow": syncScope = .recent
            case "timeWindow": syncScope = .days
            case "fullSync": syncScope = .everything
            default: syncScope = .off
            }
        }
        syncRecentCount = try container.decodeIfPresent(Int.self, forKey: .syncRecentCount) ?? 500
        syncDaysBack = try container.decodeIfPresent(Int.self, forKey: .syncDaysBack) ?? 90
        syncSchedule = try container.decodeIfPresent(AccountSyncSchedule.self, forKey: .syncSchedule) ?? .manual
        fullSyncBodies = try container.decodeIfPresent(Bool.self, forKey: .fullSyncBodies) ?? true
    }
}

struct AppSettings: Codable, Hashable, Sendable {
    var safetyMode: SafetyMode
    var confirmBeforeSend: Bool
    var syncFolderPath: String?
    var googleClientID: String
    var googleClientSecret: String
    var microsoftClientID: String
    var disabledTools: [String]
    var cachePolicy: CacheSyncPolicy

    static let `default` = AppSettings(
        safetyMode: .readOnly,
        confirmBeforeSend: true,
        syncFolderPath: nil,
        googleClientID: "",
        googleClientSecret: "",
        microsoftClientID: "",
        disabledTools: [],
        cachePolicy: .default
    )

    init(
        safetyMode: SafetyMode,
        confirmBeforeSend: Bool,
        syncFolderPath: String?,
        googleClientID: String,
        googleClientSecret: String = "",
        microsoftClientID: String,
        disabledTools: [String] = [],
        cachePolicy: CacheSyncPolicy = .default
    ) {
        self.safetyMode = safetyMode
        self.confirmBeforeSend = confirmBeforeSend
        self.syncFolderPath = syncFolderPath
        self.googleClientID = googleClientID
        self.googleClientSecret = googleClientSecret
        self.microsoftClientID = microsoftClientID
        self.disabledTools = disabledTools
        self.cachePolicy = cachePolicy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        safetyMode = try container.decodeIfPresent(SafetyMode.self, forKey: .safetyMode) ?? .readOnly
        confirmBeforeSend = try container.decodeIfPresent(Bool.self, forKey: .confirmBeforeSend) ?? true
        syncFolderPath = try container.decodeIfPresent(String.self, forKey: .syncFolderPath)
        googleClientID = try container.decodeIfPresent(String.self, forKey: .googleClientID) ?? ""
        googleClientSecret = try container.decodeIfPresent(String.self, forKey: .googleClientSecret) ?? ""
        microsoftClientID = try container.decodeIfPresent(String.self, forKey: .microsoftClientID) ?? ""
        disabledTools = try container.decodeIfPresent([String].self, forKey: .disabledTools) ?? []
        cachePolicy = try container.decodeIfPresent(CacheSyncPolicy.self, forKey: .cachePolicy) ?? .default
    }
}

struct VaultPayload: Codable, Hashable, Sendable {
    static let unsignedID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    var version: Int
    var vaultID: UUID
    var name: String
    var generation: Int
    var accounts: [MailAccount]
    var settings: AppSettings

    static func empty(name: String = "Personal", id: UUID = UUID()) -> VaultPayload {
        VaultPayload(version: 1, vaultID: id, name: name, generation: 1, accounts: [], settings: .default)
    }

    init(
        version: Int,
        vaultID: UUID,
        name: String,
        generation: Int,
        accounts: [MailAccount],
        settings: AppSettings
    ) {
        self.version = version
        self.vaultID = vaultID
        self.name = name
        self.generation = generation
        self.accounts = accounts
        self.settings = settings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        vaultID = try container.decodeIfPresent(UUID.self, forKey: .vaultID) ?? Self.unsignedID
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Personal"
        generation = try container.decodeIfPresent(Int.self, forKey: .generation) ?? 1
        accounts = try container.decodeIfPresent([MailAccount].self, forKey: .accounts) ?? []
        settings = try container.decodeIfPresent(AppSettings.self, forKey: .settings) ?? .default
    }
}

enum MCPExposure: String, Codable, CaseIterable, Identifiable, Sendable {
    case activeOnly
    case allUnlocked

    var id: String { rawValue }

    var title: String {
        switch self {
        case .activeOnly: return "Active vault only"
        case .allUnlocked: return "All unlocked vaults"
        }
    }
}

struct MailSummary: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var accountID: UUID
    var accountEmail: String
    var threadID: String?
    var from: String
    var to: [String]
    var subject: String
    var date: Date?
    var snippet: String
    var isUnread: Bool
    var labels: [String]
    var mailbox: String?
    var mailboxKind: String?

    init(
        id: String,
        accountID: UUID,
        accountEmail: String,
        threadID: String? = nil,
        from: String,
        to: [String],
        subject: String,
        date: Date?,
        snippet: String,
        isUnread: Bool,
        labels: [String],
        mailbox: String? = nil,
        mailboxKind: String? = nil
    ) {
        self.id = id
        self.accountID = accountID
        self.accountEmail = accountEmail
        self.threadID = threadID
        self.from = from
        self.to = to
        self.subject = subject
        self.date = date
        self.snippet = snippet
        self.isUnread = isUnread
        self.labels = labels
        self.mailbox = mailbox
        self.mailboxKind = mailboxKind
    }
}

struct MailAttachmentMeta: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var filename: String
    var mimeType: String
    var size: Int?
}

struct MailMessage: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var accountID: UUID
    var accountEmail: String
    var threadID: String?
    var from: String
    var to: [String]
    var cc: [String]
    var bcc: [String]
    var subject: String
    var date: Date?
    var body: String
    var bodyHTML: String?
    var isUnread: Bool
    var labels: [String]
    var attachments: [MailAttachmentMeta]
    var mailbox: String? = nil
    var mailboxKind: String? = nil
}

struct MailFolderCount: Codable, Hashable, Sendable, Identifiable {
    var id: String { remoteID ?? name }
    var name: String
    var messages: Int?
    var unseen: Int?
    var selectable: Bool
    var remoteID: String? = nil
}

struct MailThread: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var accountID: UUID
    var accountEmail: String
    var subject: String
    var participants: [String]
    var snippet: String
    var date: Date?
    var messageCount: Int
    var isUnread: Bool
}

struct MailDraft: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var accountEmail: String
    var to: [String]
    var cc: [String]
    var subject: String
    var snippet: String
    var date: Date?
}

struct MailContact: Codable, Hashable, Sendable, Identifiable {
    var id: String { address }
    var address: String
    var name: String
    var count: Int
}

struct InboxDigest: Codable, Sendable {
    var account: String
    var inboxTotal: Int
    var inboxUnread: Int
    var snoozed: Int
    var needsReply: [MailSummary]
    var agingUnread: [MailSummary]
    var topSenders: [MailContact]
    var note: String
}

struct MailAttachmentData: Codable, Hashable, Sendable {
    var meta: MailAttachmentMeta
    var dataBase64: String
}

enum MailModifyAction: String, Codable, Sendable {
    case archive
    case trash
    case markRead
    case markUnread
    case addLabel
    case removeLabel
}

struct PendingSend: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var accountID: UUID
    var accountEmail: String
    var to: [String]
    var cc: [String]
    var bcc: [String]
    var subject: String
    var body: String
    var createdAt: Date
    var extraHeaders: [String: String]

    init(
        id: UUID = UUID(),
        accountID: UUID,
        accountEmail: String,
        to: [String],
        cc: [String],
        bcc: [String],
        subject: String,
        body: String,
        createdAt: Date = Date(),
        extraHeaders: [String: String] = [:]
    ) {
        self.id = id
        self.accountID = accountID
        self.accountEmail = accountEmail
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
        self.createdAt = createdAt
        self.extraHeaders = extraHeaders
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        accountID = try container.decode(UUID.self, forKey: .accountID)
        accountEmail = try container.decode(String.self, forKey: .accountEmail)
        to = try container.decode([String].self, forKey: .to)
        cc = try container.decodeIfPresent([String].self, forKey: .cc) ?? []
        bcc = try container.decodeIfPresent([String].self, forKey: .bcc) ?? []
        subject = try container.decode(String.self, forKey: .subject)
        body = try container.decode(String.self, forKey: .body)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        extraHeaders = try container.decodeIfPresent([String: String].self, forKey: .extraHeaders) ?? [:]
    }
}

struct IMAPPreset: Identifiable, Hashable, Sendable {
    var id: String { name }
    var name: String
    var imapHost: String
    var imapPort: Int
    var imapStartTLS: Bool
    var smtpHost: String
    var smtpPort: Int
    var smtpStartTLS: Bool

    static let all: [IMAPPreset] = [
        IMAPPreset(name: "Custom", imapHost: "", imapPort: 993, imapStartTLS: false, smtpHost: "", smtpPort: 465, smtpStartTLS: false),
        IMAPPreset(name: "iCloud", imapHost: "imap.mail.me.com", imapPort: 993, imapStartTLS: false, smtpHost: "smtp.mail.me.com", smtpPort: 587, smtpStartTLS: true),
        IMAPPreset(name: "Fastmail", imapHost: "imap.fastmail.com", imapPort: 993, imapStartTLS: false, smtpHost: "smtp.fastmail.com", smtpPort: 465, smtpStartTLS: false),
        IMAPPreset(name: "Yahoo", imapHost: "imap.mail.yahoo.com", imapPort: 993, imapStartTLS: false, smtpHost: "smtp.mail.yahoo.com", smtpPort: 465, smtpStartTLS: false),
        IMAPPreset(name: "Gmail (app password)", imapHost: "imap.gmail.com", imapPort: 993, imapStartTLS: false, smtpHost: "smtp.gmail.com", smtpPort: 465, smtpStartTLS: false),
        IMAPPreset(name: "Outlook (IMAP)", imapHost: "outlook.office365.com", imapPort: 993, imapStartTLS: false, smtpHost: "smtp.office365.com", smtpPort: 587, smtpStartTLS: true)
    ]
}

enum MailMCPError: LocalizedError {
    case vaultLocked
    case vaultNotFound
    case vaultExists
    case wrongPassphrase
    case crypto(String)
    case accountNotFound
    case safetyDenied(String)
    case provider(String)
    case oauth(String)
    case network(String)
    case invalidInput(String)
    case conflict(String)
    case notImplemented(String)
    case ambiguousAccount(String)
    case timeout(String)
    case cancelled(String)

    var errorDescription: String? {
        switch self {
        case .vaultLocked: return "Unlock MailMCP and enter your vault passphrase."
        case .vaultNotFound: return "No vault found. Create or import one in MailMCP."
        case .vaultExists: return "A vault already exists at this location."
        case .wrongPassphrase: return "Incorrect vault passphrase."
        case .crypto(let m): return "Vault crypto error: \(m)"
        case .accountNotFound: return "No matching mail account."
        case .safetyDenied(let m): return m
        case .provider(let m): return m
        case .oauth(let m): return m
        case .network(let m): return m
        case .invalidInput(let m): return m
        case .conflict(let m): return m
        case .notImplemented(let m): return m
        case .ambiguousAccount(let m): return m
        case .timeout(let m): return m
        case .cancelled(let m): return m
        }
    }
}

enum JSONCoders {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static let prettyEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
