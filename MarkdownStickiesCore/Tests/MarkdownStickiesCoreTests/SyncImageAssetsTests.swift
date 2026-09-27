import CryptoKit
import Foundation
import XCTest
@testable import MarkdownStickiesCore

final class SyncImageAssetsTests: XCTestCase {
    func testRelativeImageFilenamesParsesLocalTargets() {
        let md = """
        ![a](./photo.png)
        ![b](other.jpg)
        ![c](<spaced name.webp>)
        ![d](./photos/nested.png)
        ![skip](https://example.com/x.png)
        ![skip2](../escape.png)
        """
        XCTAssertEqual(
            SyncImageAssets.relativeImageFilenames(in: md),
            ["photo.png", "other.jpg", "spaced name.webp", "nested.png"]
        )
    }

    func testSanitizedFilenameStripsDirectoriesRejectsTraversal() {
        XCTAssertEqual(SyncImageAssets.sanitizedFilename("./ok.png"), "ok.png")
        XCTAssertEqual(SyncImageAssets.sanitizedFilename("photos/shot.png"), "shot.png")
        XCTAssertEqual(SyncImageAssets.sanitizedFilename("./assets/img/x.jpeg"), "x.jpeg")
        XCTAssertNil(SyncImageAssets.sanitizedFilename("../x.png"))
        XCTAssertNil(SyncImageAssets.sanitizedFilename("https://a/b.png"))
        XCTAssertNil(SyncImageAssets.sanitizedFilename("note.md"))
    }

    func testResolveImageURLPrefersStructuredThenBasename() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ms-img-resolve-\(UUID().uuidString)", isDirectory: true)
        let nested = dir.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let structured = nested.appendingPathComponent("shot.png")
        try Data([1, 2, 3]).write(to: structured)

        let resolved = SyncImageAssets.resolveImageURL("./photos/shot.png", noteDirectory: dir)
        XCTAssertEqual(resolved?.standardizedFileURL, structured.standardizedFileURL)

        // Flat vault: only basename on disk — still opens without rewriting markdown.
        try FileManager.default.removeItem(at: structured)
        let flat = dir.appendingPathComponent("shot.png")
        try Data([4, 5, 6]).write(to: flat)
        let flatResolved = SyncImageAssets.resolveImageURL("./photos/shot.png", noteDirectory: dir)
        XCTAssertEqual(flatResolved?.standardizedFileURL, flat.standardizedFileURL)
    }

    func testMissingOffersUsesHash() {
        let id = UUID()
        let a = SyncAssetOffer(
            noteID: id,
            relativePath: "a.png",
            modifiedAt: Date(),
            sha256: "aaa",
            byteCount: 1
        )
        let bSame = SyncAssetOffer(
            noteID: id,
            relativePath: "a.png",
            modifiedAt: Date(),
            sha256: "aaa",
            byteCount: 1
        )
        let bDiff = SyncAssetOffer(
            noteID: id,
            relativePath: "a.png",
            modifiedAt: Date(),
            sha256: "bbb",
            byteCount: 1
        )
        let onlyRemote = SyncAssetOffer(
            noteID: id,
            relativePath: "b.png",
            modifiedAt: Date(),
            sha256: "ccc",
            byteCount: 2
        )
        XCTAssertTrue(SyncImageAssets.missingOffers(theirs: [a], ours: [bSame]).isEmpty)
        XCTAssertEqual(SyncImageAssets.missingOffers(theirs: [a], ours: [bDiff]).map(\.sha256), ["aaa"])
        XCTAssertEqual(SyncImageAssets.missingOffers(theirs: [onlyRemote], ours: [a]).map(\.relativePath), ["b.png"])
    }

    func testOfferLoadApplyRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ms-img-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let noteID = UUID()
        let noteURL = dir.appendingPathComponent("Hello.md")
        let body = """
        ---
        id: \(noteID.uuidString.lowercased())
        ---

        # Hello

        ![shot](./shot.png)
        """
        try body.write(to: noteURL, atomically: true, encoding: .utf8)

        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01, 0x02])
        let imageURL = dir.appendingPathComponent("shot.png")
        try png.write(to: imageURL)

        let offers = SyncImageAssets.offers(roots: [dir])
        XCTAssertEqual(offers.count, 1)
        XCTAssertEqual(offers[0].noteID, noteID)
        XCTAssertEqual(offers[0].relativePath, "shot.png")
        XCTAssertEqual(
            offers[0].sha256,
            SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        )

        let blob = try XCTUnwrap(SyncImageAssets.loadBlob(offer: offers[0], roots: [dir]))

        let peerDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ms-img-sync-peer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: peerDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: peerDir) }

        let peerNote = peerDir.appendingPathComponent("Hello.md")
        try body.write(to: peerNote, atomically: true, encoding: .utf8)

        let written = try XCTUnwrap(try SyncImageAssets.applyBlob(blob, roots: [peerDir]))
        XCTAssertEqual(try Data(contentsOf: written), png)
        XCTAssertTrue(SyncImageAssets.missingOffers(
            theirs: offers,
            ours: SyncImageAssets.offers(roots: [peerDir])
        ).isEmpty)
    }

    func testOffersReadsStructuredPathSyncsBasename() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ms-img-nested-\(UUID().uuidString)", isDirectory: true)
        let photos = dir.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let noteID = UUID()
        let noteURL = dir.appendingPathComponent("Hello.md")
        let body = """
        ---
        id: \(noteID.uuidString.lowercased())
        ---

        ![shot](./photos/shot.png)
        """
        try body.write(to: noteURL, atomically: true, encoding: .utf8)
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        try png.write(to: photos.appendingPathComponent("shot.png"))

        let offers = SyncImageAssets.offers(roots: [dir])
        XCTAssertEqual(offers.map(\.relativePath), ["shot.png"])
        let blob = try XCTUnwrap(SyncImageAssets.loadBlob(offer: offers[0], roots: [dir]))

        let peer = FileManager.default.temporaryDirectory
            .appendingPathComponent("ms-img-nested-peer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: peer, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: peer) }
        try body.write(to: peer.appendingPathComponent("Hello.md"), atomically: true, encoding: .utf8)

        let written = try XCTUnwrap(try SyncImageAssets.applyBlob(blob, roots: [peer]))
        XCTAssertEqual(written.lastPathComponent, "shot.png")
        XCTAssertEqual(written.deletingLastPathComponent().standardizedFileURL, peer.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: written), png)
    }

    func testAssetWireRoundTrip() throws {
        let offer = SyncAssetOffer(
            noteID: UUID(),
            relativePath: "x.png",
            modifiedAt: Date(timeIntervalSince1970: 100),
            sha256: "abcd",
            byteCount: 4
        )
        var wire = try SyncFrameCodec.encode(SyncWireMessage.assetOffers([offer]))
        let decoded = try SyncFrameCodec.decodeOne(&wire)
        XCTAssertEqual(decoded?.kind, .assetOffers)
        XCTAssertEqual(decoded?.assetOffers, [offer])

        let blob = SyncAssetBlob(
            noteID: offer.noteID,
            relativePath: "x.png",
            modifiedAt: offer.modifiedAt,
            sha256: "abcd",
            dataBase64: Data([1, 2, 3, 4]).base64EncodedString()
        )
        wire = try SyncFrameCodec.encode(SyncWireMessage.assetBlobs([blob]))
        let decodedBlob = try SyncFrameCodec.decodeOne(&wire)
        XCTAssertEqual(decodedBlob?.kind, .assetBlobs)
        XCTAssertEqual(decodedBlob?.assetBlobs, [blob])
    }
}
