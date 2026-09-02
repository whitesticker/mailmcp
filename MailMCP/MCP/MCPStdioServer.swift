import Darwin
import Foundation

enum MCPStdioServer {
    private static let lock = NSLock()
    private static var incoming = Data()
    private static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    static func run() {
        setbuf(stdout, nil)
        setbuf(stderr, nil)
        DispatchQueue.global(qos: .userInitiated).async {
            readLoop()
            CFRunLoopStop(CFRunLoopGetMain())
        }
        CFRunLoopRun()
    }

    private static func readLoop() {
        while true {
            var buffer = [UInt8](repeating: 0, count: 4096)
            let n = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
            if n < 0 {
                if errno == EINTR { continue }
                break
            }
            if n == 0 { break }
            let chunk = Data(buffer.prefix(n))
            lock.lock()
            incoming.append(chunk)
            lock.unlock()
            while let message = nextMessage() {
                handle(message)
            }
        }
    }

    private static func nextMessage() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if incoming.isEmpty { return nil }

        if let headerEnd = incoming.range(of: Data("\r\n\r\n".utf8)) {
            let header = String(decoding: incoming.subdata(in: incoming.startIndex..<headerEnd.lowerBound), as: UTF8.self)
            var length: Int?
            for line in header.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                    length = Int(parts[1].trimmingCharacters(in: .whitespaces))
                }
            }
            if let length {
                let start = headerEnd.upperBound
                guard incoming.distance(from: start, to: incoming.endIndex) >= length else { return nil }
                let end = incoming.index(start, offsetBy: length)
                let payload = incoming.subdata(in: start..<end)
                incoming.removeSubrange(incoming.startIndex..<end)
                return payload
            }
        }

        if let headerEnd = incoming.range(of: Data("\n\n".utf8)), incoming.range(of: Data("\r\n\r\n".utf8)) == nil {
            let header = String(decoding: incoming.subdata(in: incoming.startIndex..<headerEnd.lowerBound), as: UTF8.self)
            if header.lowercased().contains("content-length:") {
                var length: Int?
                for line in header.split(whereSeparator: \.isNewline) {
                    let parts = line.split(separator: ":", maxSplits: 1)
                    if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                        length = Int(parts[1].trimmingCharacters(in: .whitespaces))
                    }
                }
                if let length {
                    let start = headerEnd.upperBound
                    guard incoming.distance(from: start, to: incoming.endIndex) >= length else { return nil }
                    let end = incoming.index(start, offsetBy: length)
                    let payload = incoming.subdata(in: start..<end)
                    incoming.removeSubrange(incoming.startIndex..<end)
                    return payload
                }
            }
        }

        while let newline = incoming.range(of: Data("\n".utf8)) {
            var line = incoming.subdata(in: incoming.startIndex..<newline.lowerBound)
            incoming.removeSubrange(incoming.startIndex..<newline.upperBound)
            if line.last == 0x0D { line.removeLast() }
            if !line.isEmpty {
                return line
            }
        }

        if incoming.first == 0x7B, let end = completeJSONObjectEnd(incoming) {
            let payload = incoming.subdata(in: incoming.startIndex..<end)
            incoming.removeSubrange(incoming.startIndex..<end)
            return payload
        }
        return nil
    }

    private static func completeJSONObjectEnd(_ data: Data) -> Data.Index? {
        var depth = 0
        var inString = false
        var escaped = false
        var i = data.startIndex
        while i < data.endIndex {
            let byte = data[i]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                }
            } else {
                switch byte {
                case 0x22:
                    inString = true
                case 0x7B:
                    depth += 1
                case 0x7D:
                    depth -= 1
                    if depth == 0 {
                        return data.index(after: i)
                    }
                default:
                    break
                }
            }
            i = data.index(after: i)
        }
        return nil
    }

    private static func handle(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        let method = object["method"] as? String
        let id = object["id"]
        guard let method else { return }
        if method.hasPrefix("notifications/") {
            return
        }

        if method == "initialize" || method == "ping" || method == "tools/list" {
            do {
                let result = try dispatchSync(method: method, params: object["params"] as? [String: Any] ?? [:])
                if id != nil {
                    write(id: id, result: result, error: nil)
                }
            } catch {
                if id != nil {
                    write(id: id, result: nil, error: error.localizedDescription)
                }
            }
            return
        }

        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                let result = try await dispatchAsync(method: method, params: object["params"] as? [String: Any] ?? [:])
                if id != nil {
                    write(id: id, result: result, error: nil)
                }
            } catch {
                if id != nil {
                    write(id: id, result: nil, error: error.localizedDescription)
                }
            }
            semaphore.signal()
        }
        semaphore.wait()
    }

    private static func dispatchSync(method: String, params: [String: Any]) throws -> Any {
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? "2024-11-05"
            let version = supportedVersions.contains(requested) ? requested : "2024-11-05"
            return [
                "protocolVersion": version,
                "capabilities": [
                    "tools": ["listChanged": false]
                ],
                "serverInfo": [
                    "name": "mailmcp",
                    "version": "1.0.0"
                ]
            ]
        case "ping":
            return [String: Any]()
        case "tools/list":
            return ["tools": MailMCPTools.definitions]
        default:
            throw MailMCPError.invalidInput("Unsupported MCP method: \(method)")
        }
    }

    private static func dispatchAsync(method: String, params: [String: Any]) async throws -> Any {
        switch method {
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                let text = try await MailMCPTools.call(name: name, arguments: arguments)
                return [
                    "content": [
                        ["type": "text", "text": text]
                    ],
                    "isError": false
                ]
            } catch {
                return [
                    "content": [
                        ["type": "text", "text": error.localizedDescription]
                    ],
                    "isError": true
                ]
            }
        default:
            return try dispatchSync(method: method, params: params)
        }
    }

    private static func write(id: Any?, result: Any?, error: String?) {
        var response: [String: Any] = ["jsonrpc": "2.0"]
        if let id {
            response["id"] = id
        }
        if let error {
            response["error"] = ["code": -32000, "message": error]
        } else if let result {
            response["result"] = result
        } else {
            response["result"] = [String: Any]()
        }
        guard JSONSerialization.isValidJSONObject(response),
              let data = try? JSONSerialization.data(withJSONObject: response, options: []) else { return }
        var payload = data
        payload.append(Data("\n".utf8))
        FileHandle.standardOutput.write(payload)
        fflush(stdout)
    }
}
