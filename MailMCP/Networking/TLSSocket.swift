import Darwin
import Foundation
import Security

final class TLSSocket: @unchecked Sendable {
    private var fd: Int32 = -1
    private var context: SSLContext?
    private let lock = NSLock()
    private var ioTimeout: TimeInterval = 30

    deinit {
        close()
    }

    func connect(host: String, port: Int, useTLS: Bool, timeout: TimeInterval = 30) throws {
        lock.lock()
        defer { lock.unlock() }
        closeLocked()
        ioTimeout = timeout

        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        hints.ai_family = AF_UNSPEC
        var result: UnsafeMutablePointer<addrinfo>?
        let gai = getaddrinfo(host, String(port), &hints, &result)
        guard gai == 0, let first = result else {
            throw MailMCPError.network("Could not resolve \(host):\(port)")
        }
        defer { freeaddrinfo(result) }

        var candidates: [UnsafeMutablePointer<addrinfo>] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            candidates.append(info)
            cursor = info.pointee.ai_next
        }
        candidates.sort { lhs, rhs in
            (lhs.pointee.ai_family == AF_INET ? 0 : 1) < (rhs.pointee.ai_family == AF_INET ? 0 : 1)
        }

        var lastError: Error = MailMCPError.network("Could not connect to \(host):\(port)")
        for info in candidates {
            let socketFD = Darwin.socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            guard socketFD >= 0 else { continue }
            do {
                try connectNonBlocking(socketFD, address: info.pointee.ai_addr, length: info.pointee.ai_addrlen)
                fd = socketFD
                if useTLS {
                    try startTLSLocked(hostname: host)
                }
                return
            } catch {
                lastError = error
                Darwin.close(socketFD)
                fd = -1
                context = nil
            }
        }
        throw lastError
    }

    func startTLS(hostname: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try startTLSLocked(hostname: hostname)
    }

    func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        if let context {
            try writeSSL(context: context, data: data)
        } else {
            try writeRaw(data)
        }
    }

    func writeLine(_ line: String) throws {
        try write(Data((line + "\r\n").utf8))
    }

    func read(maxLength: Int = 32_768) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        if let context {
            return try readSSL(context: context, maxLength: maxLength)
        }
        return try readRaw(maxLength: maxLength)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        closeLocked()
    }

    private func connectNonBlocking(_ socketFD: Int32, address: UnsafePointer<sockaddr>, length: socklen_t) throws {
        setNonBlocking(socketFD)
        let ok = Darwin.connect(socketFD, address, length)
        if ok == 0 { return }
        guard errno == EINPROGRESS || errno == EINTR else {
            throw MailMCPError.network("connect failed: \(posixError())")
        }
        try wait(socketFD, events: Int16(POLLOUT))
        var soError: Int32 = 0
        var soLen = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(socketFD, SOL_SOCKET, SO_ERROR, &soError, &soLen)
        guard soError == 0 else {
            throw MailMCPError.network("connect failed: \(String(cString: strerror(soError)))")
        }
    }

    private func startTLSLocked(hostname: String) throws {
        guard fd >= 0 else { throw MailMCPError.network("socket not connected") }
        guard let ctx = SSLCreateContext(nil, .clientSide, .streamType) else {
            throw MailMCPError.network("SSLCreateContext failed")
        }
        SSLSetIOFuncs(ctx, sslRead, sslWrite)
        SSLSetConnection(ctx, Unmanaged.passUnretained(self).toOpaque())
        hostname.withCString { ptr in
            _ = SSLSetPeerDomainName(ctx, ptr, strlen(ptr))
        }
        _ = SSLSetProtocolVersionMin(ctx, .tlsProtocol12)

        let deadline = Date().addingTimeInterval(ioTimeout)
        var status = SSLHandshake(ctx)
        var paramRetries = 0
        while status != errSecSuccess {
            if Date() > deadline {
                throw MailMCPError.network("TLS handshake timed out")
            }
            if status == errSSLWouldBlock {
                try wait(fd, events: Int16(POLLIN | POLLOUT))
                status = SSLHandshake(ctx)
                continue
            }
            if status == errSecParam && paramRetries < 4 {
                paramRetries += 1
                try wait(fd, events: Int16(POLLIN | POLLOUT), timeout: 0.4)
                status = SSLHandshake(ctx)
                continue
            }
            throw MailMCPError.network("TLS handshake failed (\(status))")
        }
        context = ctx
    }

    private func writeRaw(_ data: Data) throws {
        var written = 0
        try data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            while written < data.count {
                let n = Darwin.write(fd, base.advanced(by: written), data.count - written)
                if n > 0 {
                    written += n
                    continue
                }
                if n < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                    try wait(fd, events: Int16(POLLOUT))
                    continue
                }
                throw MailMCPError.network("write failed: \(posixError())")
            }
        }
    }

    private func readRaw(maxLength: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: maxLength)
        while true {
            let n = Darwin.read(fd, &buffer, maxLength)
            if n > 0 {
                return Data(buffer.prefix(n))
            }
            if n == 0 {
                throw MailMCPError.network("connection closed")
            }
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                try wait(fd, events: Int16(POLLIN))
                continue
            }
            throw MailMCPError.network("read failed: \(posixError())")
        }
    }

    private func writeSSL(context: SSLContext, data: Data) throws {
        var offset = 0
        let deadline = Date().addingTimeInterval(ioTimeout)
        var paramRetries = 0
        while offset < data.count {
            if Date() > deadline {
                throw MailMCPError.network("SSLWrite timed out")
            }
            var processed = 0
            let status = data.withUnsafeBytes { buf in
                SSLWrite(context, buf.baseAddress?.advanced(by: offset), data.count - offset, &processed)
            }
            if processed > 0 {
                offset += processed
                paramRetries = 0
            }
            if status == errSecSuccess {
                continue
            }
            if status == errSSLWouldBlock || (status == errSecParam && paramRetries < 6) {
                if status == errSecParam { paramRetries += 1 }
                try wait(fd, events: Int16(POLLOUT | POLLIN), timeout: status == errSecParam ? 0.4 : ioTimeout)
                continue
            }
            throw MailMCPError.network("SSLWrite failed (\(status))")
        }
    }

    private func readSSL(context: SSLContext, maxLength: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: maxLength)
        let deadline = Date().addingTimeInterval(ioTimeout)
        var paramRetries = 0
        while Date() <= deadline {
            var processed = 0
            let status = SSLRead(context, &buffer, maxLength, &processed)
            if status == errSSLClosedGraceful || status == errSSLClosedNoNotify {
                throw MailMCPError.network("TLS connection closed")
            }
            if processed > 0 {
                return Data(buffer.prefix(processed))
            }
            if status == errSecSuccess {
                continue
            }
            if status == errSSLWouldBlock || (status == errSecParam && paramRetries < 6) {
                if status == errSecParam { paramRetries += 1 }
                try wait(fd, events: Int16(POLLIN), timeout: status == errSecParam ? 0.4 : ioTimeout)
                continue
            }
            throw MailMCPError.network("SSLRead failed (\(status))")
        }
        throw MailMCPError.network("TLS read timed out")
    }

    fileprivate func posixRead(_ data: UnsafeMutableRawPointer, length: Int) -> (OSStatus, Int) {
        let n = Darwin.read(fd, data, length)
        if n > 0 { return (errSecSuccess, n) }
        if n == 0 { return (errSSLClosedGraceful, 0) }
        if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
            return (errSSLWouldBlock, 0)
        }
        return (errSSLClosedAbort, 0)
    }

    fileprivate func posixWrite(_ data: UnsafeRawPointer, length: Int) -> (OSStatus, Int) {
        let n = Darwin.write(fd, data, length)
        if n > 0 { return (errSecSuccess, n) }
        if n < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
            return (errSSLWouldBlock, 0)
        }
        return (errSSLClosedAbort, 0)
    }

    private func wait(_ socketFD: Int32, events: Int16, timeout: TimeInterval? = nil) throws {
        var pfd = pollfd(fd: socketFD, events: events, revents: 0)
        let ms = Int32(min((timeout ?? ioTimeout) * 1000, Double(Int32.max - 1)))
        let n = poll(&pfd, 1, ms)
        if n == 0 {
            throw MailMCPError.network("socket timed out")
        }
        if n < 0 {
            if errno == EINTR {
                try wait(socketFD, events: events, timeout: timeout)
                return
            }
            throw MailMCPError.network("poll failed: \(posixError())")
        }
        if pfd.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 && pfd.revents & events == 0 {
            throw MailMCPError.network("socket closed")
        }
    }

    private func setNonBlocking(_ socketFD: Int32) {
        let flags = fcntl(socketFD, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(socketFD, F_SETFL, flags | O_NONBLOCK)
        }
    }

    private func posixError() -> String {
        String(cString: strerror(errno))
    }

    private func closeLocked() {
        if let context {
            SSLClose(context)
            self.context = nil
        }
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }
}

private func sslRead(
    connection: SSLConnectionRef,
    data: UnsafeMutableRawPointer,
    dataLength: UnsafeMutablePointer<Int>
) -> OSStatus {
    let socket = Unmanaged<TLSSocket>.fromOpaque(connection).takeUnretainedValue()
    let (status, n) = socket.posixRead(data, length: dataLength.pointee)
    dataLength.pointee = n
    return status
}

private func sslWrite(
    connection: SSLConnectionRef,
    data: UnsafeRawPointer,
    dataLength: UnsafeMutablePointer<Int>
) -> OSStatus {
    let socket = Unmanaged<TLSSocket>.fromOpaque(connection).takeUnretainedValue()
    let (status, n) = socket.posixWrite(data, length: dataLength.pointee)
    dataLength.pointee = n
    return status
}

final class LineBuffer {
    private var buffer = Data()

    func append(_ data: Data) {
        buffer.append(data)
    }

    func nextLine() -> String? {
        guard let range = buffer.range(of: Data("\n".utf8)) else { return nil }
        var lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
        if lineData.last == 0x0D {
            lineData.removeLast()
        }
        buffer.removeSubrange(buffer.startIndex..<range.upperBound)
        return String(data: lineData, encoding: .utf8) ?? String(decoding: lineData, as: UTF8.self)
    }

    func take(_ count: Int) -> Data? {
        guard buffer.count >= count else { return nil }
        let chunk = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(chunk)
    }
}

final class ProtocolReader {
    private let socket: TLSSocket
    private let lines = LineBuffer()

    init(socket: TLSSocket) {
        self.socket = socket
    }

    func readLine() throws -> String {
        if let existing = lines.nextLine() {
            return existing
        }
        while true {
            let data = try socket.read()
            lines.append(data)
            if let line = lines.nextLine() {
                return line
            }
        }
    }

    func readExact(_ count: Int) throws -> Data {
        if let existing = lines.take(count) {
            return existing
        }
        while true {
            let data = try socket.read()
            lines.append(data)
            if let chunk = lines.take(count) {
                return chunk
            }
        }
    }
}
