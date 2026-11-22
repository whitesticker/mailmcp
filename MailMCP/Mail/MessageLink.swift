import Foundation

/// `mailmcp://message?account=<uuid>&id=<message id>`, where the id is the location-aware id `search_messages` returns.
struct MessageLink: Hashable, Sendable {
    let accountID: UUID
    let messageID: String

    private static let scheme = "mailmcp"
    private static let host = "message"

    init(accountID: UUID, messageID: String) {
        self.accountID = accountID
        self.messageID = messageID
    }

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, url.host?.lowercased() == Self.host,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let account = items.first(where: { $0.name == "account" })?.value.flatMap(UUID.init(uuidString:)),
              let id = items.first(where: { $0.name == "id" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else { return nil }
        self.init(accountID: account, messageID: id)
    }

    static func isMessageURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme && url.host?.lowercased() == host
    }

    var url: URL {
        // Graph ids contain "+", "/" and "="; URLComponents leaves those raw in a query, so encode by hand.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encodedID = messageID.addingPercentEncoding(withAllowedCharacters: allowed) ?? messageID
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.percentEncodedQuery = "account=\(accountID.uuidString)&id=\(encodedID)"
        return components.url!
    }
}
