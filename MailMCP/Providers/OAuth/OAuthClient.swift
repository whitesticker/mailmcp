import AppKit
import CryptoKit
import Foundation
import Network

struct OAuthProviderConfig: Sendable {
    var authorizeURL: URL
    var tokenURL: URL
    var clientID: String
    var redirectURI: String
    var scopes: [String]
    var extraAuthParams: [String: String]
    var clientSecret: String = ""
    var usesLoopback = false
}

enum OAuthClient {
    static func google(clientID: String, clientSecret: String) throws -> OAuthProviderConfig {
        let trimmed = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MailMCPError.oauth("Add a Google OAuth client ID in Settings first.")
        }
        guard !secret.isEmpty else {
            throw MailMCPError.oauth("Add the Google client secret in Settings first.")
        }
        return OAuthProviderConfig(
            authorizeURL: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            tokenURL: URL(string: "https://oauth2.googleapis.com/token")!,
            clientID: trimmed,
            redirectURI: "http://127.0.0.1",
            scopes: [
                "https://www.googleapis.com/auth/gmail.modify",
                "https://www.googleapis.com/auth/gmail.send",
                "https://www.googleapis.com/auth/userinfo.email"
            ],
            extraAuthParams: [
                "access_type": "offline",
                "prompt": "consent"
            ],
            clientSecret: secret,
            usesLoopback: true
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
        let state = randomURLSafe(16)

        let redirectURI: String
        let callbackURL: URL
        if config.usesLoopback {
            let server = try await OAuthLoopbackServer.start()
            defer { server.stop() }
            redirectURI = server.redirectURI
            let url = try authorizeURL(config: config, redirectURI: redirectURI, challenge: challenge, state: state)
            NSWorkspace.shared.open(url)
            callbackURL = try await server.nextCallback()
        } else {
            redirectURI = config.redirectURI
            let url = try authorizeURL(config: config, redirectURI: redirectURI, challenge: challenge, state: state)
            callbackURL = try await OAuthBrowserFlow.start(url: url)
        }

        let code = try codeAndState(from: callbackURL, expectedState: state)
        var exchanging = config
        exchanging.redirectURI = redirectURI
        return try await exchange(config: exchanging, code: code, verifier: verifier)
    }

    private static func authorizeURL(
        config: OAuthProviderConfig,
        redirectURI: String,
        challenge: String,
        state: String
    ) throws -> URL {
        var items = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: config.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        for (key, value) in config.extraAuthParams {
            items.append(URLQueryItem(name: key, value: value))
        }
        var components = URLComponents(url: config.authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = items
        guard let url = components.url else {
            throw MailMCPError.oauth("Could not build authorize URL")
        }
        return url
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
        var fields = [
            "client_id": tokens.clientID,
            "grant_type": "refresh_token",
            "refresh_token": refresh
        ]
        if let secret = tokens.clientSecret, !secret.isEmpty {
            fields["client_secret"] = secret
        }
        request.httpBody = form(fields)
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
        var fields = [
            "client_id": config.clientID,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": config.redirectURI,
            "code_verifier": verifier
        ]
        if !config.clientSecret.isEmpty {
            fields["client_secret"] = config.clientSecret
        }
        request.httpBody = form(fields)
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
            clientID: config.clientID,
            clientSecret: config.clientSecret.isEmpty ? nil : config.clientSecret
        )
    }

    private static func codeAndState(from url: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            let description = items.first(where: { $0.name == "error_description" })?.value ?? error
            throw MailMCPError.oauth(description)
        }
        guard items.first(where: { $0.name == "state" })?.value == expectedState else {
            throw MailMCPError.oauth("Sign-in response did not match this attempt.")
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

final class OAuthLoopbackServer: @unchecked Sendable {
    let redirectURI: String
    private let listener: NWListener
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var result: Result<URL, Error>?

    private init(listener: NWListener, queue: DispatchQueue, port: UInt16) {
        self.listener = listener
        self.queue = queue
        self.redirectURI = "http://127.0.0.1:\(port)"
    }

    static func start() async throws -> OAuthLoopbackServer {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters, on: .any)
        let queue = DispatchQueue(label: "mailmcp.oauth.loopback")
        let pending = ConnectionTarget()
        listener.newConnectionHandler = { connection in
            pending.server?.accept(connection)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard once.claim() else { return }
                    guard let port = listener.port else {
                        continuation.resume(throwing: MailMCPError.oauth("Could not bind the sign-in redirect."))
                        return
                    }
                    let server = OAuthLoopbackServer(listener: listener, queue: queue, port: port.rawValue)
                    pending.server = server
                    continuation.resume(returning: server)
                case .failed(let error):
                    guard once.claim() else { return }
                    continuation.resume(throwing: MailMCPError.oauth("Could not listen for the Google sign-in redirect: \(error.localizedDescription)"))
                case .cancelled:
                    guard once.claim() else { return }
                    continuation.resume(throwing: MailMCPError.oauth("Sign-in was cancelled."))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func nextCallback() async throws -> URL {
        let timeout = Task { [weak self] in
            try await Task.sleep(nanoseconds: 180_000_000_000)
            self?.deliver(.failure(MailMCPError.oauth("Sign-in timed out. Try again.")))
        }
        defer { timeout.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                self.result = nil
                lock.unlock()
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func stop() {
        listener.cancel()
        deliver(.failure(MailMCPError.oauth("Sign-in was cancelled.")))
    }

    static func callbackURL(requestLine: String, redirectURI: String) -> URL? {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        let target = String(parts[1])
        guard target.contains("code=") || target.contains("error=") else { return nil }
        guard let base = URL(string: redirectURI) else { return nil }
        return URL(string: target, relativeTo: base)?.absoluteURL
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data {
                buffer.append(data)
            }
            guard let text = String(data: buffer, encoding: .utf8), text.contains("\r\n\r\n") else {
                if isComplete || error != nil || buffer.count > 16_384 {
                    connection.cancel()
                } else {
                    self.receive(connection, buffer: buffer)
                }
                return
            }
            let line = text.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
            guard let callback = Self.callbackURL(requestLine: line, redirectURI: self.redirectURI) else {
                self.respond(connection, status: 404, body: "Not found")
                return
            }
            let denied = line.contains("error=") && !line.contains("code=")
            let body = denied
                ? "<!DOCTYPE html><html><body><p>Google did not grant access. You can close this window and return to MailMCP.</p></body></html>"
                : "<!DOCTYPE html><html><body><p>MailMCP is signed in. You can close this window and return to the app.</p></body></html>"
            self.respond(connection, status: 200, body: body)
            self.deliver(.success(callback))
        }
    }

    private func respond(_ connection: NWConnection, status: Int, body: String) {
        let reason = status == 200 ? "OK" : "Not Found"
        let payload = """
        HTTP/1.1 \(status) \(reason)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        connection.send(content: Data(payload.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func deliver(_ result: Result<URL, Error>) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
        } else if self.result == nil {
            self.result = result
            lock.unlock()
        } else {
            lock.unlock()
        }
    }
}

private final class ConnectionTarget: @unchecked Sendable {
    var server: OAuthLoopbackServer?
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
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
        request.timeoutInterval = 25
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
