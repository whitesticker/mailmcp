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

struct MCPToolCallRecord: Identifiable, Equatable, Codable, Sendable {
    var id: UUID
    var date: Date
    var agentName: String
    var tool: String
    var argumentsJSON: String
    var succeeded: Bool
}

struct MCPHistoryBucket: Identifiable, Equatable, Sendable {
    var id: String { name }
    var name: String
    var count: Int
    var failed: Int
}

struct MCPHistoryPoint: Identifiable, Equatable, Sendable {
    var id: Date { date }
    var date: Date
    var count: Int
}

struct MCPToolHistoryAggregate: Equatable, Sendable {
    var total: Int
    var failed: Int
    var byAgent: [MCPHistoryBucket]
    var byTool: [MCPHistoryBucket]
    var byKind: [MCPHistoryBucket]
    var timeline: [MCPHistoryPoint]
}

enum ToolHistoryStore {
    static var url: URL { Paths.toolHistoryURL }

    static func load() -> [MCPToolCallRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONCoders.decoder.decode([MCPToolCallRecord].self, from: data)) ?? []
    }

    static func save(_ items: [MCPToolCallRecord]) {
        try? FileManager.default.createDirectory(at: Paths.applicationSupport, withIntermediateDirectories: true)
        try? JSONCoders.encoder.encode(items).write(to: url, options: .atomic)
    }

    static func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

enum MCPCallLog {
    static let defaultHistoryLimit = 500
    static let minHistoryLimit = 50
    static let maxHistoryLimit = 5000
    static let historyLimit = defaultHistoryLimit

    static func clampedLimit(_ value: Int) -> Int {
        min(max(value, minHistoryLimit), maxHistoryLimit)
    }

    static func aggregate(_ calls: [MCPToolCallRecord], now: Date = Date()) -> MCPToolHistoryAggregate {
        var agentCounts: [String: (count: Int, failed: Int)] = [:]
        var toolCounts: [String: (count: Int, failed: Int)] = [:]
        var kindCounts: [String: (count: Int, failed: Int)] = [:]
        for call in calls {
            bump(&agentCounts, call.agentName, failed: !call.succeeded)
            bump(&toolCounts, call.tool, failed: !call.succeeded)
            let kind = MCPToolCatalog.audience(forTool: call.tool)?.title ?? "Other"
            bump(&kindCounts, kind, failed: !call.succeeded)
        }
        return MCPToolHistoryAggregate(
            total: calls.count,
            failed: calls.filter { !$0.succeeded }.count,
            byAgent: buckets(agentCounts),
            byTool: Array(buckets(toolCounts).prefix(12)),
            byKind: buckets(kindCounts),
            timeline: timeline(calls, now: now)
        )
    }

    private static func bump(
        _ table: inout [String: (count: Int, failed: Int)],
        _ key: String,
        failed: Bool
    ) {
        let current = table[key] ?? (0, 0)
        table[key] = (current.count + 1, current.failed + (failed ? 1 : 0))
    }

    private static func buckets(_ table: [String: (count: Int, failed: Int)]) -> [MCPHistoryBucket] {
        table.map { MCPHistoryBucket(name: $0.key, count: $0.value.count, failed: $0.value.failed) }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private static func timeline(_ calls: [MCPToolCallRecord], now: Date) -> [MCPHistoryPoint] {
        guard let oldest = calls.map(\.date).min() else { return [] }
        let span = now.timeIntervalSince(oldest)
        let step: TimeInterval = span > 6 * 3600 ? 3600 : (span > 1800 ? 300 : 60)
        var counts: [TimeInterval: Int] = [:]
        for call in calls {
            let slot = (call.date.timeIntervalSince1970 / step).rounded(.down) * step
            counts[slot, default: 0] += 1
        }
        return counts.keys.sorted().map { MCPHistoryPoint(date: Date(timeIntervalSince1970: $0), count: counts[$0] ?? 0) }
    }

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
