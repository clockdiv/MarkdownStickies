import MarkdownStickiesCore
import XCTest

final class SyncFrameBufferTests: XCTestCase {
    func testCoalescedFramesPreserveSecondMessage() throws {
        let hello = SyncWireMessage.hello(peerID: UUID(), deviceName: "A")
        let catalog = SyncWireMessage.catalog([
            SyncNotePayload(id: UUID(), title: "T", modifiedAt: Date(timeIntervalSince1970: 1), body: "body")
        ])
        var wire = try SyncFrameCodec.encode(hello)
        wire.append(try SyncFrameCodec.encode(catalog))

        let first = try SyncFrameCodec.decodeOne(&wire)
        XCTAssertEqual(first?.kind, .hello)
        XCTAssertFalse(wire.isEmpty, "leftover catalog bytes must remain in buffer")

        let second = try SyncFrameCodec.decodeOne(&wire)
        XCTAssertEqual(second?.kind, .catalog)
        XCTAssertEqual(second?.notes?.count, 1)
        XCTAssertTrue(wire.isEmpty)
    }
}
