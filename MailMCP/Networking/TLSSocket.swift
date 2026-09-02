import Darwin
import Foundation
import Security

final class TLSSocket: @unchecked Sendable {
    private var fd: Int32 = -1
    private var context: SSLContext?
    private let lock = NSLock()

    deinit {
        close()
    }

    func connect(host: String, port: Int, useTLS: Bool, timeout: TimeInterval = 30) throws {
        lock.lock()
        defer { lock.unlock() }
        closeLocked()

        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        hints.ai_family = AF_UNSPEC
        var result: UnsafeMutablePointer<addrinfo>?
        let portString = String(port)
        let gai = getaddrinfo(host, portString, &hints, &result)
        guard gai == 0, let first = result else {
            throw MailMCPError.network("Could not resolve \(host):\(port)")
        }
        defer { freeaddrinfo(result) }

        var connectedFD: Int32 = -1
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            let socketFD = Darwin.socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if socketFD >= 0 {
                let ok = Darwin.connect(socketFD, info.pointee.ai_addr, info.pointee.ai_addrlen)
                if ok == 0 {
                    connectedFD = socketFD
                    break
                }
                Darwin.close(socketFD)
            }
            cursor = info.pointee.ai_next
        }
        guard connectedFD >= 0 else {
            throw MailMCPError.network("Could not connect to \(host):\(port)")
        }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(connectedFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(connectedFD, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        fd = connectedFD

        if useTLS {
            try startTLSLocked(hostname: host)
        }
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

    private func startTLSLocked(hostname: String) throws {
        guard fd >= 0 else { throw MailMCPError.network("socket not connected") }
        guard let ctx = SSLCreateContext(nil, .clientSide, .streamType) else {
            throw MailMCPError.network("SSLCreateContext failed")
        }
        SSLSetIOFuncs(ctx, sslRead, sslWrite)
        let connection = Unmanaged.passUnretained(self).toOpaque()
        SSLSetConnection(ctx, connection)
        hostname.withCString { ptr in
            _ = SSLSetPeerDomainName(ctx, ptr, strlen(ptr))
        }
        var status: OSStatus = errSSLWouldBlock
        var tries = 0
        while status == errSSLWouldBlock && tries < 80 {
            status = SSLHandshake(ctx)
            if status == errSSLWouldBlock {
                Thread.sleep(forTimeInterval: 0.05)
            }
            tries += 1
        }
        guard status == errSecSuccess else {
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
                if n < 0 {
                    throw MailMCPError.network("write failed: \(String(cString: strerror(errno)))")
                }
                written += n
            }
        }
    }

    private func readRaw(maxLength: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: maxLength)
        let n = Darwin.read(fd, &buffer, maxLength)
        if n < 0 {
            throw MailMCPError.network("read failed: \(String(cString: strerror(errno)))")
        }
        if n == 0 {
            throw MailMCPError.network("connection closed")
        }
        return Data(buffer.prefix(n))
    }

    private func writeSSL(context: SSLContext, data: Data) throws {
        var offset = 0
        var tries = 0
        while offset < data.count {
            var processed = 0
            let status = data.withUnsafeBytes { buf in
                SSLWrite(context, buf.baseAddress?.advanced(by: offset), data.count - offset, &processed)
            }
            if status == errSecSuccess || (status == errSSLWouldBlock && processed > 0) {
                offset += processed
                tries = 0
                continue
            }
            if status == errSSLWouldBlock {
                tries += 1
                if tries > 80 {
                    throw MailMCPError.network("SSLWrite timed out")
                }
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            throw MailMCPError.network("SSLWrite failed (\(status))")
        }
    }

    private func readSSL(context: SSLContext, maxLength: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: maxLength)
        var tries = 0
        while tries < 80 {
            var processed = 0
            let status = SSLRead(context, &buffer, maxLength, &processed)
            if status == errSSLClosedGraceful || status == errSSLClosedNoNotify {
                throw MailMCPError.network("TLS connection closed")
            }
            if status == errSecSuccess {
                return Data(buffer.prefix(processed))
            }
            if status == errSSLWouldBlock {
                if processed > 0 {
                    return Data(buffer.prefix(processed))
                }
                tries += 1
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            throw MailMCPError.network("SSLRead failed (\(status))")
        }
        throw MailMCPError.network("TLS read timed out")
    }

    fileprivate func posixRead(_ data: UnsafeMutableRawPointer, length: Int) -> (OSStatus, Int) {
        let n = Darwin.read(fd, data, length)
        if n < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == ETIMEDOUT || errno == EINTR {
                return (errSSLWouldBlock, 0)
            }
            return (errSSLClosedAbort, 0)
        }
        if n == 0 {
            return (errSSLClosedGraceful, 0)
        }
        return (errSecSuccess, n)
    }

    fileprivate func posixWrite(_ data: UnsafeRawPointer, length: Int) -> (OSStatus, Int) {
        let n = Darwin.write(fd, data, length)
        if n < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == ETIMEDOUT || errno == EINTR {
                return (errSSLWouldBlock, 0)
            }
            return (errSSLClosedAbort, 0)
        }
        return (errSecSuccess, n)
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
