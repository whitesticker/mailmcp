import Darwin
import Foundation

enum MCPProtocol {
    static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    static let appRequiredMessage = "Open MailMCP and unlock the vault. Agents talk to the running app, not this helper."

    static func writeJSON(_ response: [String: Any], to write: (Data) -> Void) {
        guard JSONSerialization.isValidJSONObject(response),
              let data = try? JSONSerialization.data(withJSONObject: response, options: []) else { return }
        var payload = data
        payload.append(Data("\n".utf8))
        write(payload)
    }

    static func encodeResponse(id: Any?, result: Any?, error: String?) -> [String: Any] {
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
        return response
    }

    static func dispatchSync(method: String, params: [String: Any]) throws -> Any {
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
                    "version": "1.4.0"
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

    static func dispatchAsync(method: String, params: [String: Any], agentName: String = "") async throws -> Any {
        switch method {
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                let text = try await MailMCPTools.call(name: name, arguments: arguments)
                await MainActor.run {
                    AppState.shared.recordMCPToolCall(
                        agentName: agentName,
                        tool: name,
                        arguments: arguments,
                        succeeded: true
                    )
                }
                return [
                    "content": [
                        ["type": "text", "text": text]
                    ],
                    "isError": false
                ]
            } catch {
                await MainActor.run {
                    AppState.shared.recordMCPToolCall(
                        agentName: agentName,
                        tool: name,
                        arguments: arguments,
                        succeeded: false
                    )
                }
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
}

final class MCPClientSession: @unchecked Sendable {
    let id = UUID()
    var name = ""
    var version = ""
    var detectedLauncher: String?
}

final class MCPMessageBuffer {
    private var incoming = Data()

    func append(_ data: Data) {
        incoming.append(data)
    }

    func nextMessage() -> Data? {
        if incoming.isEmpty { return nil }

        if let headerEnd = incoming.range(of: Data("\r\n\r\n".utf8)) {
            let header = String(decoding: incoming.subdata(in: incoming.startIndex..<headerEnd.lowerBound), as: UTF8.self)
            if let length = contentLength(in: header) {
                return takeLengthPrefixed(headerEnd: headerEnd.upperBound, length: length)
            }
        }

        if let headerEnd = incoming.range(of: Data("\n\n".utf8)), incoming.range(of: Data("\r\n\r\n".utf8)) == nil {
            let header = String(decoding: incoming.subdata(in: incoming.startIndex..<headerEnd.lowerBound), as: UTF8.self)
            if header.lowercased().contains("content-length:"), let length = contentLength(in: header) {
                return takeLengthPrefixed(headerEnd: headerEnd.upperBound, length: length)
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

    private func contentLength(in header: String) -> Int? {
        for line in header.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                return Int(parts[1].trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    private func takeLengthPrefixed(headerEnd: Data.Index, length: Int) -> Data? {
        let start = headerEnd
        guard incoming.distance(from: start, to: incoming.endIndex) >= length else { return nil }
        let end = incoming.index(start, offsetBy: length)
        let payload = incoming.subdata(in: start..<end)
        incoming.removeSubrange(incoming.startIndex..<end)
        return payload
    }

    private func completeJSONObjectEnd(_ data: Data) -> Data.Index? {
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
}

final class MCPInflight: @unchecked Sendable {
    private let writeLock = NSLock()
    private let write: (Data) -> Void
    private let tasksLock = NSLock()
    private var tasks: [String: Task<Void, Never>] = [:]

    init(write: @escaping (Data) -> Void) {
        self.write = write
    }

    func reply(_ response: [String: Any]) {
        writeLock.lock()
        defer { writeLock.unlock() }
        MCPProtocol.writeJSON(response, to: write)
    }

    func start(idKey: String, _ work: @escaping @Sendable () async -> Void) {
        let task = Task {
            await work()
        }
        tasksLock.lock()
        tasks[idKey] = task
        tasksLock.unlock()
        Task {
            await task.value
            tasksLock.lock()
            tasks[idKey] = nil
            tasksLock.unlock()
        }
    }

    func cancel(_ idKey: String) {
        tasksLock.lock()
        let task = tasks[idKey]
        tasksLock.unlock()
        task?.cancel()
    }

    func cancelAll() {
        tasksLock.lock()
        let all = Array(tasks.values)
        tasks.removeAll()
        tasksLock.unlock()
        all.forEach { $0.cancel() }
    }

    static func idKey(_ id: Any?) -> String? {
        guard let id else { return nil }
        if let text = id as? String { return text }
        if let number = id as? NSNumber { return number.stringValue }
        if let value = id as? Int { return String(value) }
        if let value = id as? Double { return String(Int(value)) }
        return String(describing: id)
    }
}

enum MCPSession {
    static func handle(_ data: Data, session: MCPClientSession? = nil, write: @escaping (Data) -> Void, offline: Bool, inflight: MCPInflight? = nil) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        let method = object["method"] as? String
        let id = object["id"]
        guard let method else { return }

        let params = object["params"] as? [String: Any] ?? [:]
        if method == "notifications/cancelled" {
            if let key = MCPInflight.idKey(params["requestId"]) ?? MCPInflight.idKey(params["request_id"]) {
                inflight?.cancel(key)
            }
            return
        }
        if method.hasPrefix("notifications/") {
            return
        }

        if method == "initialize", let session {
            let info = params["clientInfo"] as? [String: Any]
            let rawName = (info?["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let version = (info?["version"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedName = MCPCallLog.resolveSessionAgent(
                clientInfoName: rawName,
                detectedLauncher: session.detectedLauncher
            )
            session.name = resolvedName
            session.version = version
            Task { @MainActor in
                AppState.shared.mcpAgentDidIdentify(id: session.id, name: resolvedName, version: version)
            }
        }

        let send: (Any?, String?) -> Void = { result, error in
            let target = inflight
            if let target {
                target.reply(MCPProtocol.encodeResponse(id: id, result: result, error: error))
            } else {
                MCPProtocol.writeJSON(MCPProtocol.encodeResponse(id: id, result: result, error: error), to: write)
            }
        }

        if method == "initialize" || method == "ping" || method == "tools/list" {
            do {
                send(try MCPProtocol.dispatchSync(method: method, params: params), nil)
            } catch {
                if id != nil {
                    send(nil, error.localizedDescription)
                }
            }
            return
        }

        if offline {
            if id != nil {
                send(nil, MCPProtocol.appRequiredMessage)
            }
            return
        }

        guard let key = MCPInflight.idKey(id) else { return }
        let agentName = session?.name ?? ""
        let runner = inflight ?? MCPInflight(write: write)
        runner.start(idKey: key) {
            do {
                let result = try await MCPProtocol.dispatchAsync(
                    method: method,
                    params: params,
                    agentName: agentName
                )
                runner.reply(MCPProtocol.encodeResponse(id: id, result: result, error: nil))
            } catch is CancellationError {
                runner.reply(MCPProtocol.encodeResponse(id: id, result: nil, error: "cancelled"))
            } catch {
                runner.reply(MCPProtocol.encodeResponse(id: id, result: nil, error: error.localizedDescription))
            }
        }
    }
}

final class MCPSocketHost: @unchecked Sendable {
    static let shared = MCPSocketHost()

    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var thread: Thread?

    func start() {
        lock.lock()
        let already = listenFD >= 0 || thread != nil
        lock.unlock()
        guard !already else { return }
        let worker = Thread { [weak self] in
            self?.listen()
        }
        worker.name = "mailmcp.mcp.listen"
        worker.qualityOfService = .userInitiated
        lock.lock()
        thread = worker
        lock.unlock()
        worker.start()
    }

    func stop() {
        lock.lock()
        let fd = listenFD
        listenFD = -1
        lock.unlock()
        if fd >= 0 {
            Darwin.close(fd)
        }
        unlinkSocket()
    }

    private func listen() {
        unlinkSocket()
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var nosig: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
        guard bindUnix(fd, path: Paths.mcpSocket.path) else {
            Darwin.close(fd)
            unlinkSocket()
            return
        }
        chmod(Paths.mcpSocket.path, 0o600)
        guard Darwin.listen(fd, 16) == 0 else {
            Darwin.close(fd)
            unlinkSocket()
            return
        }
        lock.lock()
        listenFD = fd
        lock.unlock()
        while true {
            lock.lock()
            let running = listenFD == fd
            lock.unlock()
            guard running else { break }
            let client = Darwin.accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                break
            }
            var clientNosig: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &clientNosig, socklen_t(MemoryLayout<Int32>.size))
            DispatchQueue.global(qos: .userInitiated).async {
                self.serve(client)
            }
        }
        Darwin.close(fd)
        lock.lock()
        if listenFD == fd {
            listenFD = -1
        }
        thread = nil
        lock.unlock()
        unlinkSocket()
    }

    private func serve(_ fd: Int32) {
        let session = MCPClientSession()
        if let detected = MCPProcessInspector.detectAgent(forSocketFD: fd) {
            session.detectedLauncher = detected
            session.name = detected
        }
        let writeToClient: (Data) -> Void = { data in
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                _ = Darwin.write(fd, base, data.count)
            }
        }
        let inflight = MCPInflight(write: writeToClient)
        let initialName = session.name
        Task { @MainActor in
            AppState.shared.mcpAgentDidConnect(id: session.id)
            if !initialName.isEmpty {
                AppState.shared.mcpAgentDidIdentify(id: session.id, name: initialName, version: "")
            }
        }
        defer {
            inflight.cancelAll()
            Darwin.close(fd)
            Task { @MainActor in
                AppState.shared.mcpAgentDidDisconnect(id: session.id)
            }
        }
        let buffer = MCPMessageBuffer()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n < 0 {
                if errno == EINTR { continue }
                break
            }
            if n == 0 { break }
            buffer.append(Data(chunk.prefix(n)))
            while let message = buffer.nextMessage() {
                MCPSession.handle(message, session: session, write: writeToClient, offline: false, inflight: inflight)
            }
        }
    }

    private func unlinkSocket() {
        unlink(Paths.mcpSocket.path)
    }
}

@discardableResult
private func bindUnix(_ fd: Int32, path: String) -> Bool {
    guard var addr = unixAddress(path: path) else { return false }
    let length = socklen_t(addr.sun_len)
    return withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            Darwin.bind(fd, sockPtr, length) == 0
        }
    }
}

@discardableResult
private func connectUnix(_ fd: Int32, path: String) -> Bool {
    guard var addr = unixAddress(path: path) else { return false }
    let length = socklen_t(addr.sun_len)
    return withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            Darwin.connect(fd, sockPtr, length) == 0
        }
    }
}

private func unixAddress(path: String) -> sockaddr_un? {
    var addr = sockaddr_un()
    let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
    let utf8 = Array(path.utf8)
    guard utf8.count + 1 <= maxPath else { return nil }
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutablePointer(to: &addr.sun_path.0) { dst in
        path.withCString { src in
            _ = strncpy(dst, src, maxPath)
        }
    }
    let length = MemoryLayout<UInt8>.size + MemoryLayout<sa_family_t>.size + utf8.count
    addr.sun_len = UInt8(truncatingIfNeeded: length)
    return addr
}

enum MCPShim {
    static func run() {
        setbuf(stdout, nil)
        setbuf(stderr, nil)
        if let fd = connectToApp() {
            proxy(socket: fd)
            Darwin.close(fd)
            exit(0)
        }
        runOfflineUntilConnected()
    }

    private static func connectToApp() -> Int32? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var nosig: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
        if connectUnix(fd, path: Paths.mcpSocket.path) {
            return fd
        }
        Darwin.close(fd)
        return nil
    }

    private static func proxy(socket fd: Int32) {
        let toSocket = DispatchQueue(label: "mailmcp.mcp.shim.in")
        toSocket.async {
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = Darwin.read(STDIN_FILENO, &buf, buf.count)
                if n < 0 {
                    if errno == EINTR { continue }
                    Darwin.close(fd)
                    return
                }
                if n == 0 {
                    Darwin.shutdown(fd, SHUT_WR)
                    return
                }
                var written = 0
                while written < n {
                    let w = Darwin.write(fd, buf.withUnsafeBufferPointer { $0.baseAddress!.advanced(by: written) }, n - written)
                    if w <= 0 { return }
                    written += w
                }
            }
        }
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n < 0 {
                if errno == EINTR { continue }
                return
            }
            if n == 0 { return }
            var written = 0
            while written < n {
                let w = Darwin.write(STDOUT_FILENO, buf.withUnsafeBufferPointer { $0.baseAddress!.advanced(by: written) }, n - written)
                if w <= 0 { return }
                written += w
            }
        }
    }

    private static func runOfflineUntilConnected() {
        let buffer = MCPMessageBuffer()
        var chunk = [UInt8](repeating: 0, count: 4096)
        var poller = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        while true {
            if let fd = connectToApp() {
                proxy(socket: fd)
                Darwin.close(fd)
                exit(0)
            }
            poller.revents = 0
            let ready = poll(&poller, 1, 400)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 { continue }
            let n = Darwin.read(STDIN_FILENO, &chunk, chunk.count)
            if n < 0 {
                if errno == EINTR { continue }
                break
            }
            if n == 0 { break }
            buffer.append(Data(chunk.prefix(n)))
            while let message = buffer.nextMessage() {
                MCPSession.handle(message, write: { data in
                    FileHandle.standardOutput.write(data)
                    fflush(stdout)
                }, offline: true)
            }
        }
    }
}
