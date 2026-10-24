import Darwin
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
    var failed: Int = 0
}

struct MCPToolHistoryAggregate: Equatable, Sendable {
    var total: Int
    var failed: Int
    var byAgent: [MCPHistoryBucket]
    var byTool: [MCPHistoryBucket]
    var byMailbox: [MCPHistoryBucket]
    var byKind: [MCPHistoryBucket]
    var timeline: [MCPHistoryPoint]
}

enum ToolHistoryTimeRange: String, CaseIterable, Identifiable, Sendable {
    case all = "All time"
    case lastHour = "Last hour"
    case last24Hours = "Last 24h"
    case last7Days = "Last 7d"
    case last30Days = "Last 30d"

    var id: String { rawValue }

    func cutoff(now: Date = Date()) -> Date? {
        switch self {
        case .all: return nil
        case .lastHour: return now.addingTimeInterval(-3600)
        case .last24Hours: return now.addingTimeInterval(-24 * 3600)
        case .last7Days: return now.addingTimeInterval(-7 * 24 * 3600)
        case .last30Days: return now.addingTimeInterval(-30 * 24 * 3600)
        }
    }

    func filter(_ calls: [MCPToolCallRecord], now: Date = Date()) -> [MCPToolCallRecord] {
        guard let cutoff = cutoff(now: now) else { return calls }
        return calls.filter { $0.date >= cutoff }
    }
}

enum ToolHistoryStore {
    static var url: URL { Paths.toolHistoryURL }

    static func load() -> [MCPToolCallRecord] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONCoders.decoder.decode([MCPToolCallRecord].self, from: data) else {
            return []
        }
        let normalized = MCPCallLog.normalizeHistoricalAgents(decoded)
        if normalized != decoded {
            save(normalized)
        }
        return normalized
    }

    static func save(_ items: [MCPToolCallRecord]) {
        try? FileManager.default.createDirectory(at: Paths.applicationSupport, withIntermediateDirectories: true)
        try? JSONCoders.encoder.encode(items).write(to: url, options: .atomic)
    }

    static func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

enum MCPProcessInspector {
    private static let solLocal: Int32 = 0
    private static let localPeerPID: Int32 = 0x002

    static func detectAgent(forSocketFD fd: Int32) -> String? {
        var peerPID: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, solLocal, localPeerPID, &peerPID, &len) == 0, peerPID > 1 else {
            return nil
        }
        return detectAgent(fromPID: peerPID)
    }

    static func detectAgent(fromPID startPID: pid_t) -> String? {
        var currentPID = startPID
        var visited = Set<pid_t>()
        var fallbackTerminal: String?

        for _ in 0..<24 {
            guard currentPID > 1, visited.insert(currentPID).inserted else { break }

            let path = processPath(pid: currentPID) ?? ""
            let comm = processCommAndPPID(pid: currentPID)
            let name = comm.name
            let combined = (path + " " + name).lowercased()

            if combined.contains("cursor.app") || combined.contains("/cursor") || name.lowercased() == "cursor" {
                return "Cursor"
            }
            if combined.contains("claude.app") {
                return "Claude Desktop"
            }
            if combined.contains("/claude") || name.lowercased() == "claude" || combined.contains("claude-code") {
                return "Claude Code"
            }
            if combined.contains("/codex") || name.lowercased() == "codex" || combined.contains("codex.app") {
                return "Codex"
            }
            if combined.contains("windsurf") {
                return "Windsurf"
            }
            if combined.contains("visual studio code") || combined.contains("/code.app/") || combined.contains("vscode") {
                return "VS Code"
            }
            if combined.contains("/gemini") || name.lowercased() == "gemini" {
                return "Gemini CLI"
            }
            if combined.contains("zed.app") {
                return "Zed"
            }

            if fallbackTerminal == nil {
                if combined.contains("warp.app") { fallbackTerminal = "Warp" }
                else if combined.contains("iterm.app") { fallbackTerminal = "iTerm" }
                else if combined.contains("terminal.app") { fallbackTerminal = "Terminal" }
            }

            guard let ppid = comm.ppid, ppid > 1, ppid != currentPID else { break }
            currentPID = ppid
        }

        return fallbackTerminal
    }

    private static func processPath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let ret = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard ret > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func processCommAndPPID(pid: pid_t) -> (name: String, ppid: pid_t?) {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let status = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard status == 0, size > 0 else { return ("", nil) }
        let comm = withUnsafePointer(to: &info.kp_proc.p_comm) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { cStr in
                String(cString: cStr)
            }
        }
        return (comm, info.kp_eproc.e_ppid)
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

    static func aggregate(
        _ calls: [MCPToolCallRecord],
        accounts: [MailAccount] = [],
        now: Date = Date()
    ) -> MCPToolHistoryAggregate {
        var agentCounts: [String: (count: Int, failed: Int)] = [:]
        var toolCounts: [String: (count: Int, failed: Int)] = [:]
        var mailboxCounts: [String: (count: Int, failed: Int)] = [:]
        var kindCounts: [String: (count: Int, failed: Int)] = [:]

        for call in calls {
            let normalizedAgent = displayName(clientName: call.agentName)
            bump(&agentCounts, normalizedAgent, failed: !call.succeeded)
            bump(&toolCounts, call.tool, failed: !call.succeeded)
            let kind = MCPToolCatalog.audience(forTool: call.tool)?.title ?? "Other"
            bump(&kindCounts, kind, failed: !call.succeeded)

            let targetMailboxes = mailboxes(for: call, accounts: accounts)
            for box in targetMailboxes {
                bump(&mailboxCounts, box, failed: !call.succeeded)
            }
        }
        return MCPToolHistoryAggregate(
            total: calls.count,
            failed: calls.filter { !$0.succeeded }.count,
            byAgent: buckets(agentCounts),
            byTool: Array(buckets(toolCounts).prefix(12)),
            byMailbox: Array(buckets(mailboxCounts).prefix(15)),
            byKind: buckets(kindCounts),
            timeline: timeline(calls, now: now)
        )
    }

    static func mailboxes(for call: MCPToolCallRecord, accounts: [MailAccount] = []) -> [String] {
        guard let data = call.argumentsJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        var rawTokens: [String] = []
        if let one = json["account_id"] as? String {
            rawTokens.append(contentsOf: one.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        }
        if let many = json["account_ids"] as? [String] {
            for item in many {
                rawTokens.append(contentsOf: item.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            }
        }
        rawTokens = rawTokens.filter { !$0.isEmpty }
        guard !rawTokens.isEmpty else { return [] }

        var resolved: [String] = []
        var seen = Set<String>()
        for token in rawTokens {
            let label = resolveMailboxLabel(token: token, accounts: accounts)
            let key = label.lowercased()
            if seen.insert(key).inserted {
                resolved.append(label)
            }
        }
        return resolved
    }

    static func resolveMailboxLabel(token: String, accounts: [MailAccount]) -> String {
        if let uuid = UUID(uuidString: token),
           let match = accounts.first(where: { $0.id == uuid }) {
            return match.email.lowercased()
        }
        if let match = accounts.first(where: {
            $0.email.caseInsensitiveCompare(token) == .orderedSame
                || (!$0.displayName.isEmpty && $0.displayName.caseInsensitiveCompare(token) == .orderedSame)
        }) {
            return match.email.lowercased()
        }
        return token.lowercased()
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
        guard let oldest = calls.map(\.date).min(),
              let newest = calls.map(\.date).max() else { return [] }
        let rawSpan = max(newest.timeIntervalSince(oldest), 0)
        let step: TimeInterval
        if rawSpan > 24 * 3600 {
            step = 3600 * 2
        } else if rawSpan > 6 * 3600 {
            step = 3600
        } else if rawSpan > 1800 {
            step = 300
        } else {
            step = 60
        }

        let endSlot = (max(now, newest).timeIntervalSince1970 / step).rounded(.down) * step
        let minBuckets = 10
        let rawStartSlot = (oldest.timeIntervalSince1970 / step).rounded(.down) * step
        let startSlot = min(rawStartSlot, endSlot - Double(minBuckets - 1) * step)

        var counts: [TimeInterval: (total: Int, failed: Int)] = [:]
        for call in calls {
            let slot = (call.date.timeIntervalSince1970 / step).rounded(.down) * step
            let current = counts[slot] ?? (0, 0)
            counts[slot] = (current.total + 1, current.failed + (call.succeeded ? 0 : 1))
        }

        var points: [MCPHistoryPoint] = []
        var cursor = startSlot
        let maxIterations = 60
        var iterations = 0
        while cursor <= endSlot && iterations < maxIterations {
            let item = counts[cursor] ?? (0, 0)
            points.append(
                MCPHistoryPoint(
                    date: Date(timeIntervalSince1970: cursor),
                    count: item.total,
                    failed: item.failed
                )
            )
            cursor += step
            iterations += 1
        }
        return points
    }

    private static let secretKeys: Set<String> = [
        "password", "passphrase", "pass", "secret", "token",
        "authorization", "app_password", "apppassword",
        "refresh_token", "access_token", "client_secret"
    ]

    static func knownAgentName(from clientName: String) -> String? {
        let trimmed = clientName.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        guard !lower.isEmpty else { return nil }
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
        if lower.contains("zed") { return "Zed" }
        if ["warp", "iterm", "terminal"].contains(lower) { return trimmed }
        return nil
    }

    static func resolveSessionAgent(clientInfoName: String, detectedLauncher: String?) -> String {
        if let known = knownAgentName(from: clientInfoName) {
            return known
        }
        if let detectedLauncher, !detectedLauncher.isEmpty {
            return detectedLauncher
        }
        return displayName(clientName: clientInfoName)
    }

    static func displayName(clientName: String) -> String {
        if let known = knownAgentName(from: clientName) {
            return known
        }
        let trimmed = clientName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.lowercased() == "unknown agent" {
            return "Unknown agent"
        }
        return trimmed
    }

    static func normalizeHistoricalAgents(_ records: [MCPToolCallRecord]) -> [MCPToolCallRecord] {
        guard !records.isEmpty else { return records }
        // Find nearest known agent by timestamp for ad-hoc script names (e.g. core412x-file, ce628s-inbox2, Unknown agent)
        let knownEntries: [(date: Date, agent: String)] = records.compactMap { rec in
            guard let known = knownAgentName(from: rec.agentName) else { return nil }
            return (rec.date, known)
        }
        return records.map { rec in
            if let known = knownAgentName(from: rec.agentName) {
                var copy = rec
                copy.agentName = known
                return copy
            }
            var copy = rec
            if let nearest = knownEntries.min(by: {
                abs($0.date.timeIntervalSince(rec.date)) < abs($1.date.timeIntervalSince(rec.date))
            }) {
                copy.agentName = nearest.agent
            } else {
                copy.agentName = "Cursor"
            }
            return copy
        }
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
