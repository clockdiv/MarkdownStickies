import Foundation
import Network
import XCTest
@testable import MarkdownStickiesCore

/// The real TCP connection over loopback: framing, chunked content, and the idle timeout.
final class NWSyncConnectionTests: XCTestCase {
    private func connectedPair(idleTimeout: TimeInterval) async throws -> (NWSyncConnection, NWSyncConnection, NWListener) {
        let listener = try NWListener(using: .tcp, on: .any)
        let accepted = AsyncStream<NWConnection>.makeStream()
        listener.newConnectionHandler = { accepted.continuation.yield($0) }
        let ready = AsyncStream<NWEndpoint.Port>.makeStream()
        listener.stateUpdateHandler = { state in
            if case .ready = state, let port = listener.port { ready.continuation.yield(port) }
        }
        listener.start(queue: .global())

        var portIterator = ready.stream.makeAsyncIterator()
        let nextPort = await portIterator.next()
        let port = try XCTUnwrap(nextPort)
        let client = NWSyncConnection(endpoint: .hostPort(host: "127.0.0.1", port: port), idleTimeout: idleTimeout)
        try await client.start()

        var acceptedIterator = accepted.stream.makeAsyncIterator()
        let nextConnection = await acceptedIterator.next()
        let server = NWSyncConnection(connection: try XCTUnwrap(nextConnection), idleTimeout: idleTimeout)
        try await server.start()
        return (client, server, listener)
    }

    func testMessagesAndChunkedContentRoundTrip() async throws {
        let (client, server, listener) = try await connectedPair(idleTimeout: 5)
        defer {
            client.close()
            server.close()
            listener.cancel()
        }

        let big = Data((0..<(3 * SyncWire.chunkSize + 123)).map { UInt8($0 % 251) })
        let sender = Task {
            try await client.send(.keepalive)
            try await client.send(.fetch(.note(UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000000")!)))
            try await client.sendContent(big)
        }

        guard case .fetch(.note(let id)) = try await server.receiveSkippingKeepalives() else { return XCTFail("expected fetch") }
        XCTAssertEqual(id.uuidString, "AAAAAAAA-0000-4000-8000-000000000000")
        let received = try await server.receiveContent()
        XCTAssertEqual(received, big)
        try await sender.value
    }

    func testReceiveTimesOutWhenPeerIsSilent() async throws {
        let (client, server, listener) = try await connectedPair(idleTimeout: 0.3)
        defer {
            client.close()
            server.close()
            listener.cancel()
        }
        do {
            _ = try await server.receive()
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? SyncTransportError, .timedOut)
        }
    }

    func testFrameLimitIsEnforced() {
        let huge = SyncMessage.chunk(SyncChunk(data: Data(count: SyncWire.maxFrameBytes), isLast: true))
        XCTAssertThrowsError(try SyncFrame.encode(huge))
    }
}
