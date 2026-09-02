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

struct OAuthTokens: Codable, Hashable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var scopes: [String]
    var tokenEndpoint: String
    var clientID: String

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

    init(
        id: UUID = UUID(),
        provider: MailProviderKind,
        email: String,
        displayName: String = "",
        oauth: OAuthTokens? = nil,
        imap: IMAPSettings? = nil,
        lastError: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.provider = provider
        self.email = email
        self.displayName = displayName
        self.oauth = oauth
        self.imap = imap
        self.lastError = lastError
        self.createdAt = createdAt
    }
}

struct AppSettings: Codable, Hashable, Sendable {
    var safetyMode: SafetyMode
    var confirmBeforeSend: Bool
    var syncFolderPath: String?
    var googleClientID: String
    var microsoftClientID: String
    var disabledTools: [String]

    static let `default` = AppSettings(
        safetyMode: .readOnly,
        confirmBeforeSend: true,
        syncFolderPath: nil,
        googleClientID: "",
        microsoftClientID: "",
        disabledTools: []
    )

    init(
        safetyMode: SafetyMode,
        confirmBeforeSend: Bool,
        syncFolderPath: String?,
        googleClientID: String,
        microsoftClientID: String,
        disabledTools: [String] = []
    ) {
        self.safetyMode = safetyMode
        self.confirmBeforeSend = confirmBeforeSend
        self.syncFolderPath = syncFolderPath
        self.googleClientID = googleClientID
        self.microsoftClientID = microsoftClientID
        self.disabledTools = disabledTools
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        safetyMode = try container.decodeIfPresent(SafetyMode.self, forKey: .safetyMode) ?? .readOnly
        confirmBeforeSend = try container.decodeIfPresent(Bool.self, forKey: .confirmBeforeSend) ?? true
        syncFolderPath = try container.decodeIfPresent(String.self, forKey: .syncFolderPath)
        googleClientID = try container.decodeIfPresent(String.self, forKey: .googleClientID) ?? ""
        microsoftClientID = try container.decodeIfPresent(String.self, forKey: .microsoftClientID) ?? ""
        disabledTools = try container.decodeIfPresent([String].self, forKey: .disabledTools) ?? []
    }
}

struct VaultPayload: Codable, Hashable, Sendable {
    var version: Int
    var generation: Int
    var accounts: [MailAccount]
    var settings: AppSettings

    static func empty() -> VaultPayload {
        VaultPayload(version: 1, generation: 1, accounts: [], settings: .default)
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
