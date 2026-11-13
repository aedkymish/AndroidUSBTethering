import Foundation
import TetheringCore

/// Thin async wrapper over the privileged XPC connection.
final class HelperConnection {
    private var connection: NSXPCConnection?

    private func proxy(onError: @escaping (Error) -> Void) -> TetheringHelperProtocol? {
        if connection == nil {
            let connection = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: TetheringHelperProtocol.self)
            connection.invalidationHandler = { [weak self] in self?.connection = nil }
            connection.resume()
            self.connection = connection
        }
        return connection?.remoteObjectProxyWithErrorHandler(onError) as? TetheringHelperProtocol
    }

    func fetchStatus() async throws -> HelperStatus {
        let data: Data = try await call { helper, once in
            helper.fetchStatus { once.resume(returning: $0) }
        }
        return try HelperStatus.decode(data)
    }

    func connect(deviceID: UInt64) async throws -> String? {
        try await call { helper, once in
            helper.connect(deviceID: deviceID) { once.resume(returning: $0) }
        }
    }

    func disconnect() async throws {
        try await call { helper, once in
            helper.disconnect { once.resume(returning: ()) }
        }
    }

    func update(options: TetheringOptions, autoConnect: Bool) async throws {
        let json = try JSONEncoder().encode(options)
        try await call { helper, once in
            helper.update(optionsJSON: json, autoConnect: autoConnect) { once.resume(returning: ()) }
        }
    }

    /// Bridges one XPC request/reply to async/await; XPC errors resume the continuation exactly once.
    private func call<T>(_ body: @escaping (TetheringHelperProtocol, Once<T>) -> Void) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let once = Once(continuation)
            guard let helper = proxy(onError: { once.resume(throwing: $0) }) else {
                return once.resume(throwing: CocoaError(.xpcConnectionInterrupted))
            }
            body(helper, once)
        }
    }

    func helperVersion() async throws -> String {
        try await call { helper, once in
            helper.helperVersion { once.resume(returning: $0) }
        }
    }

    func invalidate() {
        connection?.invalidate()
        connection = nil
    }
}

/// Guards a continuation against being resumed twice (reply + error handler race).
private final class Once<T> {
    private var continuation: CheckedContinuation<T, Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        take()?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<T, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let current = continuation
        continuation = nil
        return current
    }
}
