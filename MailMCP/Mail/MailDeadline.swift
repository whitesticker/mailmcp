import Foundation

enum MailDeadline {
    static let searchDefault: TimeInterval = 20
    static let probeDefault: TimeInterval = 8
    static let accountConcurrency = 3

    static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                let ns = UInt64(max(seconds, 0.1) * 1_000_000_000)
                try await Task.sleep(nanoseconds: ns)
                throw MailMCPError.timeout("Timed out after \(Int(seconds.rounded()))s")
            }
            guard let value = try await group.next() else {
                throw MailMCPError.timeout("Timed out")
            }
            group.cancelAll()
            return value
        }
    }
}

actor MailConcurrencyGate {
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func withPermit<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        do {
            let value = try await work()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }

    private func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if !waiters.isEmpty {
            waiters.removeFirst().resume()
            return
        }
        running = max(0, running - 1)
    }
}
