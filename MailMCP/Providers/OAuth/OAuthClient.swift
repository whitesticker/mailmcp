import AppKit
import CryptoKit
import Foundation

struct OAuthProviderConfig: Sendable {
    var authorizeURL: URL
    var tokenURL: URL
    var clientID: String
    var redirectURI: String
    var scopes: [String]
    var extraAuthParams: [String: String]
}

enum OAuthClient {
    static func google(clientID: String) throws -> OAuthProviderConfig {
        let trimmed = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MailMCPError.oauth("Add a Google OAuth client ID in Settings first.")
        }
        return OAuthProviderConfig(
            authorizeURL: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            tokenURL: URL(string: "https://oauth2.googleapis.com/token")!,
            clientID: trimmed,
            redirectURI: "mailmcp://oauth/google",
            scopes: [
                "https://www.googleapis.com/auth/gmail.modify",
                "https://www.googleapis.com/auth/gmail.send",
                "https://www.googleapis.com/auth/userinfo.email"
            ],
            extraAuthParams: [
                "access_type": "offline",
                "prompt": "consent"
            ]
        )
    }

    static func microsoft(clientID: String) throws -> OAuthProviderConfig {
        let trimmed = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MailMCPError.oauth("Add a Microsoft OAuth client ID in Settings first.")
        }
        return OAuthProviderConfig(
            authorizeURL: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!,
            tokenURL: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!,
            clientID: trimmed,
            redirectURI: "mailmcp://oauth/microsoft",
            scopes: [
                "offline_access",
                "User.Read",
                "Mail.Read",
                "Mail.ReadWrite",
                "Mail.Send"
            ],
            extraAuthParams: [
                "response_mode": "query"
            ]
        )
    }

    @MainActor
    static func signIn(config: OAuthProviderConfig) async throws -> OAuthTokens {
        let verifier = randomURLSafe(32)
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        var items = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: config.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        for (key, value) in config.extraAuthParams {
            items.append(URLQueryItem(name: key, value: value))
        }
        var components = URLComponents(url: config.authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = items
        guard let url = components.url else {
            throw MailMCPError.oauth("Could not build authorize URL")
        }

        let callbackURL = try await OAuthBrowserFlow.start(url: url)

        let code = try extractCode(from: callbackURL)
        return try await exchange(config: config, code: code, verifier: verifier)
    }

    static func refresh(tokens: OAuthTokens) async throws -> OAuthTokens {
        guard let refresh = tokens.refreshToken, !refresh.isEmpty else {
            throw MailMCPError.oauth("No refresh token. Sign in again.")
        }
        guard let endpoint = URL(string: tokens.tokenEndpoint) else {
            throw MailMCPError.oauth("Missing token endpoint")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form([
            "client_id": tokens.clientID,
            "grant_type": "refresh_token",
            "refresh_token": refresh
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        try throwIfHTTPError(data: data, response: response)
        let json = try decodeJSON(data)
        let access = json["access_token"] as? String
        guard let access else { throw MailMCPError.oauth("Refresh did not return an access token") }
        var next = tokens
        next.accessToken = access
        if let refreshToken = json["refresh_token"] as? String {
            next.refreshToken = refreshToken
        }
        if let expires = json["expires_in"] as? Double {
            next.expiresAt = Date().addingTimeInterval(expires)
        }
        return next
    }

    private static func exchange(config: OAuthProviderConfig, code: String, verifier: String) async throws -> OAuthTokens {
        var request = URLRequest(url: config.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form([
            "client_id": config.clientID,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": config.redirectURI,
            "code_verifier": verifier
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        try throwIfHTTPError(data: data, response: response)
        let json = try decodeJSON(data)
        guard let access = json["access_token"] as? String else {
            throw MailMCPError.oauth("Token response missing access_token")
        }
        let expires = (json["expires_in"] as? Double) ?? 3600
        return OAuthTokens(
            accessToken: access,
            refreshToken: json["refresh_token"] as? String,
            expiresAt: Date().addingTimeInterval(expires),
            scopes: config.scopes,
            tokenEndpoint: config.tokenURL.absoluteString,
            clientID: config.clientID
        )
    }

    private static func extractCode(from url: URL) throws -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            let description = items.first(where: { $0.name == "error_description" })?.value ?? error
            throw MailMCPError.oauth(description)
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw MailMCPError.oauth("Authorization code missing from callback")
        }
        return code
    }

    static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))
        let body = fields.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    static func decodeJSON(_ data: Data) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MailMCPError.oauth("Token response was not JSON")
        }
        return json
    }

    static func throwIfHTTPError(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw MailMCPError.oauth(body)
        }
    }

    static func randomURLSafe(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum OAuthBrowserFlow {
    private static let lock = NSLock()
    private static var continuation: CheckedContinuation<URL, Error>?

    static func start(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            NSWorkspace.shared.open(url)
        }
    }

    static func handle(url: URL) -> Bool {
        guard url.scheme == "mailmcp" else { return false }
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: url)
        return pending != nil
    }
}

enum HTTPJSON {
    static func request(
        url: URL,
        method: String = "GET",
        token: String,
        body: Data? = nil,
        headers: [String: String] = [:]
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MailMCPError.network("Missing HTTP response")
        }
        return (data, http)
    }

    static func jsonObject(_ data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data)
    }
}
