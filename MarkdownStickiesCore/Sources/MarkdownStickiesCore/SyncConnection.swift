import Foundation
import Network

public enum SyncTransportError: Error, Equatable, Sendable {
    /// No frame arrived within the idle timeout.
    case timedOut
    case closed
    case frameTooLarge(Int)
    case malformed(String)
    case failed(String)
}

/// A message channel between the two devices. Receives fail after `SyncWire.idleTimeout`.
public protocol SyncConnection: AnyObject, Sendable {
    func send(_ message: SyncMessage) async throws
    func receive() async throws -> SyncMessage
    func close()
}

extension SyncConnection {
    /// Next message that isn't a keepalive.
    func receiveSkippingKeepalives() async throws -> SyncMessage {
        while true {
            let message = try await receive()
            if case .keepalive = message { continue }
            return message
        }
    }

    /// Sends `data` as one or more chunks (an empty file is one empty last chunk).
    func sendContent(_ data: Data) async throws {
        var offset = 0
        repeat {
            let end = min(offset + SyncWire.chunkSize, data.count)
            try await send(.chunk(SyncChunk(data: data.subdata(in: offset..<end), isLast: end == data.count)))
            offset = end
        } while offset < data.count
    }

    func receiveContent() async throws -> Data {
        var data = Data()
        while true {
            guard case .chunk(let chunk) = try await receiveSkippingKeepalives() else {
                throw SyncTransportError.malformed("expected file content")
            }
            data += chunk.data
            if chunk.isLast { return data }
        }
    }

    /// Runs `work` while sending a keepalive every few seconds, so the other side's
    /// idle timeout doesn't fire during long local work (scans, the bulk-delete dialog).
    func withKeepalive<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        let pinger = Task {
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: UInt64(SyncWire.keepaliveInterval * 1_000_000_000))
                try await send(.keepalive)
            }
        }
        defer { pinger.cancel() }
        return try await work()
    }
}

/// Length-prefixed JSON frames: 4-byte big-endian length, then the encoded message.
enum SyncFrame {
    static func encode(_ message: SyncMessage) throws -> Data {
        let body = try JSONEncoder().encode(message)
        guard body.count <= SyncWire.maxFrameBytes else { throw SyncTransportError.frameTooLarge(body.count) }
        var length = UInt32(body.count).bigEndian
        return Data(bytes: &length, count: 4) + body
    }

    static func length(fromHeader header: Data) throws -> Int {
        guard header.count == 4 else { throw SyncTransportError.malformed("short header") }
        let length = header.reduce(0) { ($0 << 8) | Int($1) }
        guard length <= SyncWire.maxFrameBytes else { throw SyncTransportError.frameTooLarge(length) }
        return length
    }

    static func decode(_ body: Data) throws -> SyncMessage {
        do {
            return try JSONDecoder().decode(SyncMessage.self, from: body)
        } catch {
            throw SyncTransportError.malformed("not a protocol \(SyncWire.protocolVersion) message")
        }
    }
}

// MARK: - Network.framework

/// TCP connection with framing and idle timeouts.
public final class NWSyncConnection: SyncConnection, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "MarkdownStickies.sync.connection")
    private let idleTimeout: TimeInterval

    public init(connection: NWConnection, idleTimeout: TimeInterval = SyncWire.idleTimeout) {
        self.connection = connection
        self.idleTimeout = idleTimeout
    }

    public convenience init(endpoint: NWEndpoint, idleTimeout: TimeInterval = SyncWire.idleTimeout) {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        self.init(connection: NWConnection(to: endpoint, using: parameters), idleTimeout: idleTimeout)
    }

    /// Starts the connection and waits until it's ready (or fails, or times out).
    public func start() async throws {
        let once = Once()
        try await withTimeout {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        once.run { continuation.resume() }
                    case .failed(let error), .waiting(let error):
                        once.run { continuation.resume(throwing: SyncTransportError.failed(error.localizedDescription)) }
                    case .cancelled:
                        once.run { continuation.resume(throwing: SyncTransportError.closed) }
                    default:
                        break
                    }
                }
                self.connection.start(queue: self.queue)
            }
        }
    }

    public func send(_ message: SyncMessage) async throws {
        let frame = try SyncFrame.encode(message)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: SyncTransportError.failed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func receive() async throws -> SyncMessage {
        let header = try await withTimeout { try await self.receiveExactly(4) }
        let length = try SyncFrame.length(fromHeader: header)
        let body = try await withTimeout { try await self.receiveExactly(length) }
        return try SyncFrame.decode(body)
    }

    public func close() {
        connection.cancel()
    }

    private func receiveExactly(_ count: Int) async throws -> Data {
        var data = Data()
        while data.count < count {
            data += try await receiveSome(maximum: count - data.count)
        }
        return data
    }

    /// One NWConnection receive. Its completion runs exactly once; cancelling the connection
    /// (timeout or Cancel) makes it complete with an error.
    private func receiveSome(maximum: Int) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { content, _, isComplete, error in
                    if let content, !content.isEmpty {
                        continuation.resume(returning: content)
                    } else if let error {
                        continuation.resume(throwing: SyncTransportError.failed(error.localizedDescription))
                    } else if isComplete {
                        continuation.resume(throwing: SyncTransportError.closed)
                    } else {
                        continuation.resume(returning: Data())
                    }
                }
            }
        } onCancel: {
            self.connection.cancel()
        }
    }

    /// Fails with `.timedOut` (and closes the connection) when `operation` takes too long.
    private func withTimeout<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let seconds = idleTimeout
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw SyncTransportError.timedOut
            }
            do {
                let result = try await group.next()!
                group.cancelAll()
                return result
            } catch {
                // Cancel the connection first: a pending receive only finishes once it's cancelled.
                connection.cancel()
                group.cancelAll()
                throw error
            }
        }
    }
}

/// Runs a closure at most once (for continuations resumed from repeated callbacks).
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}

// MARK: - In memory (tests)

/// A connected pair of in-memory connections with the same timeout behavior as the real one.
/// Messages go through the real frame encoding, so size limits apply.
public final class InMemorySyncConnection: SyncConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var inbox: [Data] = []
    private var waiter: CheckedContinuation<Data, Error>?
    private var isClosed = false
    private weak var peer: InMemorySyncConnection?
    private let idleTimeout: TimeInterval

    /// Called before each send with the message; return false to drop the connection instead.
    public var sendFilter: (@Sendable (SyncMessage) -> Bool)?

    init(idleTimeout: TimeInterval) {
        self.idleTimeout = idleTimeout
    }

    public static func pair(idleTimeout: TimeInterval = SyncWire.idleTimeout) -> (InMemorySyncConnection, InMemorySyncConnection) {
        let a = InMemorySyncConnection(idleTimeout: idleTimeout)
        let b = InMemorySyncConnection(idleTimeout: idleTimeout)
        a.peer = b
        b.peer = a
        return (a, b)
    }

    public func send(_ message: SyncMessage) async throws {
        if let filter = sendFilter, !filter(message) {
            close()
            throw SyncTransportError.closed
        }
        let frame = try SyncFrame.encode(message)
        guard !closedState(), let peer else { throw SyncTransportError.closed }
        peer.deliver(frame.dropFirst(4))
    }

    public func receive() async throws -> SyncMessage {
        let seconds = idleTimeout
        let body: Data = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await self.nextFrame() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw SyncTransportError.timedOut
            }
            do {
                let result = try await group.next()!
                group.cancelAll()
                return result
            } catch {
                self.close()
                group.cancelAll()
                throw error
            }
        }
        return try SyncFrame.decode(body)
    }

    public func close() {
        lock.lock()
        let pending = waiter
        waiter = nil
        let wasClosed = isClosed
        isClosed = true
        lock.unlock()
        pending?.resume(throwing: SyncTransportError.closed)
        if !wasClosed { peer?.close() }
    }

    private func closedState() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isClosed
    }

    private func deliver(_ frame: Data) {
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: Data(frame))
            return
        }
        inbox.append(Data(frame))
        lock.unlock()
    }

    private func nextFrame() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !inbox.isEmpty {
                let frame = inbox.removeFirst()
                lock.unlock()
                continuation.resume(returning: frame)
            } else if isClosed {
                lock.unlock()
                continuation.resume(throwing: SyncTransportError.closed)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }
}
