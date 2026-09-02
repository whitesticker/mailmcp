import Foundation

struct MCPAgentConnection: Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var version: String
    var connectedAt: Date

    var displayName: String {
        MCPCallLog.displayName(clientName: name)
    }
}

struct MCPToolCallRecord: Identifiable, Equatable, Sendable {
    var id: UUID
    var date: Date
    var agentName: String
    var tool: String
    var argumentsJSON: String
    var succeeded: Bool
}

enum MCPCallLog {
    static let historyLimit = 200

    private static let secretKeys: Set<String> = [
        "password", "passphrase", "pass", "secret", "token",
        "authorization", "app_password", "apppassword",
        "refresh_token", "access_token", "client_secret"
    ]

    static func displayName(clientName: String) -> String {
        let trimmed = clientName.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.contains("cursor") { return "Cursor" }
        if lower.contains("claude") && (lower.contains("code") || lower.contains("cli")) {
            return "Claude Code"
        }
        if lower.contains("claude") { return "Claude Desktop" }
        if lower.contains("windsurf") { return "Windsurf" }
        if lower.contains("visual studio") || lower == "vscode" || lower.contains("copilot") {
            return "VS Code"
        }
        if lower.contains("gemini") { return "Gemini CLI" }
        if lower.contains("codex") { return "Codex" }
        return trimmed.isEmpty ? "Unknown agent" : trimmed
    }

    static func redact(_ value: Any, key: String? = nil) -> Any {
        if let key {
            let normalized = key.lowercased().replacingOccurrences(of: "-", with: "_")
            if secretKeys.contains(normalized) {
                return "••••"
            }
        }
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            out.reserveCapacity(dict.count)
            for (nestedKey, nestedValue) in dict {
                out[nestedKey] = redact(nestedValue, key: nestedKey)
            }
            return out
        }
        if let array = value as? [Any] {
            return array.map { redact($0) }
        }
        if let text = value as? String, text.count > 400 {
            return String(text.prefix(400)) + "…"
        }
        return value
    }

    static func prettyJSON(_ arguments: [String: Any]) -> String {
        let redacted = redact(arguments) as? [String: Any] ?? [:]
        guard JSONSerialization.isValidJSONObject(redacted),
              let data = try? JSONSerialization.data(
                withJSONObject: redacted,
                options: [.prettyPrinted, .sortedKeys]
              ),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
