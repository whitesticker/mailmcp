import Foundation

enum MCPClientKind: String, CaseIterable, Identifiable {
    case cursor
    case claudeCode
    case claudeDesktop
    case windsurf
    case vscode
    case gemini
    case codex

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cursor: return "Cursor"
        case .claudeCode: return "Claude Code"
        case .claudeDesktop: return "Claude Desktop"
        case .windsurf: return "Windsurf"
        case .vscode: return "VS Code / Copilot"
        case .gemini: return "Gemini CLI"
        case .codex: return "Codex"
        }
    }

    var detail: String {
        configURL.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    var configURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .cursor:
            return home.appendingPathComponent(".cursor/mcp.json")
        case .claudeCode:
            return home.appendingPathComponent(".claude.json")
        case .claudeDesktop:
            return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Claude/claude_desktop_config.json")
        case .windsurf:
            return home.appendingPathComponent(".codeium/windsurf/mcp_config.json")
        case .vscode:
            return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Code/User/mcp.json")
        case .gemini:
            return home.appendingPathComponent(".gemini/settings.json")
        case .codex:
            return home.appendingPathComponent(".codex/config.toml")
        }
    }

    var appHints: [URL] {
        let apps = URL(fileURLWithPath: "/Applications")
        switch self {
        case .cursor: return [apps.appendingPathComponent("Cursor.app")]
        case .claudeCode: return [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")]
        case .claudeDesktop: return [apps.appendingPathComponent("Claude.app")]
        case .windsurf: return [apps.appendingPathComponent("Windsurf.app")]
        case .vscode: return [
            apps.appendingPathComponent("Visual Studio Code.app"),
            apps.appendingPathComponent("Code.app")
        ]
        case .gemini: return [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini")]
        case .codex: return [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")]
        }
    }
}

enum MCPInstallState: Equatable {
    case agentMissing
    case notAdded
    case added
    case stale

    var title: String {
        switch self {
        case .agentMissing: return "Agent not found on this Mac"
        case .notAdded: return "MailMCP not added"
        case .added: return "MailMCP installed"
        case .stale: return "Installed — path is stale"
        }
    }
}

enum MCPClientInstaller {
    static func cliURL() -> URL? {
        let sibling = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("mailmcp-mcp")
        if FileManager.default.isExecutableFile(atPath: sibling.path) {
            return sibling
        }
        if let exec = Bundle.main.executableURL, FileManager.default.isExecutableFile(atPath: exec.path) {
            return exec
        }
        return nil
    }

    static func commandAndArgs() throws -> (command: String, args: [String]) {
        guard let executable = cliURL() else {
            throw MailMCPError.invalidInput("Could not locate mailmcp-mcp.")
        }
        if executable.lastPathComponent == "MailMCP" {
            return (executable.path, ["--mcp"])
        }
        return (executable.path, [])
    }

    static func agentPresent(_ client: MCPClientKind) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: client.configURL.path) { return true }
        return client.appHints.contains { fm.fileExists(atPath: $0.path) }
    }

    static func state(for client: MCPClientKind) -> MCPInstallState {
        let recorded = recordedCommand(for: client)
        if recorded == nil && !agentPresent(client) {
            return .agentMissing
        }
        guard let recorded else { return .notAdded }
        if let current = try? commandAndArgs(), recorded != current.command {
            return .stale
        }
        return .added
    }

    static func install(_ client: MCPClientKind) throws -> String {
        switch client {
        case .codex:
            return try installCodex()
        case .vscode:
            return try installVSCode()
        default:
            return try installJSON(at: client.configURL)
        }
    }

    static func snippet() -> String {
        let pair = (try? commandAndArgs()) ?? ("/usr/local/bin/mailmcp-mcp", [])
        let args = pair.1.map { "\"\($0)\"" }.joined(separator: ", ")
        return """
        {
          "mcpServers": {
            "mailmcp": {
              "command": "\(pair.0)",
              "args": [\(args)]
            }
          }
        }
        """
    }

    private static func recordedCommand(for client: MCPClientKind) -> String? {
        if client == .codex {
            guard let text = try? String(contentsOf: client.configURL, encoding: .utf8),
                  let range = text.range(of: "[mcp_servers.mailmcp]") else {
                return nil
            }
            let after = text[range.upperBound...]
            let block = after.split(separator: "[", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? String(after)
            for line in block.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("command") {
                    return trimmed.split(separator: "=", maxSplits: 1).last?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                }
            }
            return "mailmcp"
        }
        guard let data = try? Data(contentsOf: client.configURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let servers = (root["mcpServers"] as? [String: Any])
            ?? (root["servers"] as? [String: Any])
            ?? [:]
        guard let entry = servers["mailmcp"] as? [String: Any] else { return nil }
        return entry["command"] as? String ?? "mailmcp"
    }

    private static func installJSON(at url: URL) throws -> String {
        let pair = try commandAndArgs()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = existing
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers["mailmcp"] = [
            "command": pair.command,
            "args": pair.args
        ]
        root["mcpServers"] = servers
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        return url.path
    }

    private static func installVSCode() throws -> String {
        let pair = try commandAndArgs()
        let url = MCPClientKind.vscode.configURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = existing
        }
        var servers = root["servers"] as? [String: Any] ?? [:]
        servers["mailmcp"] = [
            "type": "stdio",
            "command": pair.command,
            "args": pair.args
        ]
        root["servers"] = servers
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        return url.path
    }

    private static func installCodex() throws -> String {
        let pair = try commandAndArgs()
        let url = MCPClientKind.codex.configURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let block = """
        [mcp_servers.mailmcp]
        command = "\(tomlString(pair.command))"
        args = [\(pair.args.map { "\"\(tomlString($0))\"" }.joined(separator: ", "))]
        """
        if let range = text.range(of: "[mcp_servers.mailmcp]") {
            let after = text[range.lowerBound...]
            let restStart = after.dropFirst().firstIndex(of: "[") ?? after.endIndex
            text.replaceSubrange(range.lowerBound..<restStart, with: block + "\n")
        } else {
            if !text.isEmpty, !text.hasSuffix("\n") {
                text += "\n"
            }
            if !text.isEmpty {
                text += "\n"
            }
            text += block + "\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private static func tomlString(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
