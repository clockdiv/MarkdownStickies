import Foundation
import MarkdownStickiesCore

/// Runnable algorithm lab (no devices): diverge → Mac keep-both → merge → apply on iOS vault.
///
///   cd MarkdownStickiesCore && swift run SyncMergeHarness
@main
enum SyncMergeHarness {
    static func main() {
        var failures = 0
        failures += run("append_merge_reaches_ios_vault") { try scenarioAppendMergeReachesSatellite() }
        failures += run("same_line_merge_markers") { try scenarioSameLineNeedsMarkers() }
        failures += run("resolve_stamp_required_for_satellite_apply") { try scenarioResolveStampRequired() }
        failures += run("no_sibling_spam_on_resync") { try scenarioNoSiblingSpam() }
        failures += run("stress_append_union") { try scenarioStressAppendUnion() }
        failures += run("unstamped_merge_must_not_look_synced") { try scenarioUnstampedLooksUnsynced() }
        failures += run("wire_mac_client_merge_lands_on_ios") { try scenarioWireMacClientMergeLandsOnIOS() }
        failures += run("stale_overwrite_before_sync_fails_loud") { try scenarioStaleOverwriteBeforeSync() }
        failures += run("conflict_sibling_not_in_catalog") { try scenarioConflictSiblingNotInCatalog() }
        failures += run("mac_resurfaces_conflict_if_sibling_exists") { try scenarioMacResurfacesExistingSibling() }

        if failures == 0 {
            print("\nSyncMergeHarness: ALL PASSED")
            exit(0)
        } else {
            print("\nSyncMergeHarness: \(failures) FAILED")
            exit(1)
        }
    }

    private static func run(_ name: String, _ body: () throws -> Void) -> Int {
        do {
            try body()
            print("PASS  \(name)")
            return 0
        } catch {
            print("FAIL  \(name)\n      \(error)")
            return 1
        }
    }
}

private struct HarnessError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Scenarios

private func makePair() throws -> (mac: URL, ios: URL, root: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ms-harness-\(UUID().uuidString)", isDirectory: true)
    let mac = root.appendingPathComponent("Mac", isDirectory: true)
    let ios = root.appendingPathComponent("iOS", isDirectory: true)
    try FileManager.default.createDirectory(at: mac, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: ios, withIntermediateDirectories: true)
    return (mac, ios, root)
}

private func activeNotes(in dir: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension.lowercased() == "md" }
        .filter { !NoteFrontmatter.isTrashed(file: $0) }
}

private func scenarioAppendMergeReachesSatellite() throws {
    let pair = try makePair()
    defer { try? FileManager.default.removeItem(at: pair.root) }
    let id = UUID()
    let base = NoteFrontmatter.initialDocument(title: "Todo", id: id, createdOn: "Mac") + "- shared\n"
    let macFile = pair.mac.appendingPathComponent("todo.md")
    let iosFile = pair.ios.appendingPathComponent("todo.md")
    try base.write(to: macFile, atomically: true, encoding: .utf8)
    try base.write(to: iosFile, atomically: true, encoding: .utf8)

    try (base + "- mac line\n").write(to: macFile, atomically: true, encoding: .utf8)
    try (base + "- ios line\n").write(to: iosFile, atomically: true, encoding: .utf8)

    let iosCatalog = SyncCatalogBuilder.catalog(roots: [pair.ios])
    let macApply = try SyncCatalogBuilder.applyRemoteCatalog(
        iosCatalog,
        roots: [pair.mac],
        createDirectory: pair.mac,
        peerLabel: "tinydancer",
        conflictRole: .mergeAuthority
    )
    guard macApply.conflicts.count == 1, let conflict = macApply.conflicts.first else {
        throw HarnessError("expected 1 Mac conflict, got \(macApply.conflicts.count)")
    }

    let merged = TextMerge.mergeDocuments(
        localMarkdown: conflict.local.body,
        remoteMarkdown: conflict.remote.body,
        keepingID: id,
        remoteLabel: conflict.peerLabel
    )
    guard merged.isClean else {
        throw HarnessError("append-only merge should be clean:\n\(merged.body)")
    }

    let now = Date()
    var resolved = NoteFrontmatter.settingConflictResolved(now, in: merged.body)
    resolved = NoteFrontmatter.settingSyncID(id, in: resolved)
    let macPath = try SyncCatalogBuilder.pathIndex(roots: [pair.mac])[id]
        ?? { throw HarnessError("missing Mac path") }()
    try resolved.write(to: macPath, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: macPath.path)
    if let sibling = conflict.remoteCopyPath {
        _ = try NoteFrontmatter.moveToTrash(file: sibling, roots: [pair.mac])
    }

    // This is the step that was broken in the app when conflict_resolved was stripped on save.
    let macCatalog = SyncCatalogBuilder.catalog(roots: [pair.mac])
    let iosApply = try SyncCatalogBuilder.applyRemoteCatalog(
        macCatalog,
        roots: [pair.ios],
        createDirectory: pair.ios,
        peerLabel: "MacBook",
        conflictRole: .satellite
    )
    guard iosApply.awaitingAuthorityMerge.isEmpty else {
        throw HarnessError("iOS still awaiting Mac merge after resolve apply")
    }

    let iosAfter = try String(
        contentsOf: SyncCatalogBuilder.pathIndex(roots: [pair.ios])[id]
            ?? { throw HarnessError("missing iOS path") }(),
        encoding: .utf8
    )
    guard iosAfter.contains("- mac line"), iosAfter.contains("- ios line") else {
        throw HarnessError("iOS body missing merged lines:\n\(iosAfter)")
    }
    guard NoteFrontmatter.conflictResolvedAt(in: iosAfter) != nil else {
        throw HarnessError("iOS missing conflict_resolved after apply")
    }
    guard try activeNotes(in: pair.ios).count == 1 else {
        throw HarnessError("iOS should have exactly one active note")
    }
}

private func scenarioSameLineNeedsMarkers() throws {
    let local = "# T\n\nMac conclusion\n"
    let remote = "# T\n\niOS conclusion\n"
    let result = TextMerge.twoWay(local: local, remote: remote, remoteLabel: "iPhone")
    guard result.hasConflicts else {
        throw HarnessError("expected conflict markers for same-line rewrite")
    }
    guard result.body.contains("<<<<<<<"), result.body.contains(">>>>>>>") else {
        throw HarnessError("markers missing")
    }
}

private func scenarioResolveStampRequired() throws {
    let pair = try makePair()
    defer { try? FileManager.default.removeItem(at: pair.root) }
    let id = UUID()
    let macBody = NoteFrontmatter.initialDocument(title: "N", id: id) + "MERGED\n"
    let iosBody = NoteFrontmatter.initialDocument(title: "N", id: id) + "OLD IOS\n"
    try macBody.write(to: pair.mac.appendingPathComponent("n.md"), atomically: true, encoding: .utf8)
    try iosBody.write(to: pair.ios.appendingPathComponent("n.md"), atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 500)],
        ofItemAtPath: pair.mac.appendingPathComponent("n.md").path
    )

    // Without conflict_resolved, satellite must NOT take Mac's body.
    let noStamp = try SyncCatalogBuilder.applyRemoteCatalog(
        SyncCatalogBuilder.catalog(roots: [pair.mac]),
        roots: [pair.ios],
        createDirectory: pair.ios,
        peerLabel: "Mac",
        conflictRole: .satellite
    )
    guard noStamp.awaitingAuthorityMerge.count == 1 else {
        throw HarnessError("expected awaiting merge without resolve stamp")
    }
    let stillOld = try String(contentsOf: pair.ios.appendingPathComponent("n.md"), encoding: .utf8)
    guard stillOld.contains("OLD IOS") else {
        throw HarnessError("satellite overwrote without resolve stamp")
    }

    // With stamp + newer mtime, satellite applies.
    let stamped = NoteFrontmatter.settingConflictResolved(Date(timeIntervalSince1970: 900), in: macBody)
    try stamped.write(to: pair.mac.appendingPathComponent("n.md"), atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 900)],
        ofItemAtPath: pair.mac.appendingPathComponent("n.md").path
    )
    let withStamp = try SyncCatalogBuilder.applyRemoteCatalog(
        SyncCatalogBuilder.catalog(roots: [pair.mac]),
        roots: [pair.ios],
        createDirectory: pair.ios,
        peerLabel: "Mac",
        conflictRole: .satellite
    )
    guard withStamp.awaitingAuthorityMerge.isEmpty else {
        throw HarnessError("stamp should apply on satellite")
    }
    let after = try String(contentsOf: pair.ios.appendingPathComponent("n.md"), encoding: .utf8)
    guard after.contains("MERGED") else {
        throw HarnessError("satellite did not receive merged body")
    }
}

private func scenarioNoSiblingSpam() throws {
    let pair = try makePair()
    defer { try? FileManager.default.removeItem(at: pair.root) }
    let id = UUID()
    try (NoteFrontmatter.initialDocument(title: "T", id: id) + "Mac\n")
        .write(to: pair.mac.appendingPathComponent("t.md"), atomically: true, encoding: .utf8)
    try (NoteFrontmatter.initialDocument(title: "T", id: id) + "iOS\n")
        .write(to: pair.ios.appendingPathComponent("t.md"), atomically: true, encoding: .utf8)

    let iosCatalog = SyncCatalogBuilder.catalog(roots: [pair.ios])
    _ = try SyncCatalogBuilder.applyRemoteCatalog(
        iosCatalog, roots: [pair.mac], createDirectory: pair.mac,
        peerLabel: "iPhone", conflictRole: .mergeAuthority
    )
    let first = try activeNotes(in: pair.mac).count
    _ = try SyncCatalogBuilder.applyRemoteCatalog(
        iosCatalog, roots: [pair.mac], createDirectory: pair.mac,
        peerLabel: "iPhone", conflictRole: .mergeAuthority
    )
    let second = try activeNotes(in: pair.mac).count
    guard first == 2, second == 2 else {
        throw HarnessError("sibling spam: \(first) then \(second)")
    }
}

/// If Mac already kept the iOS body as a sibling, sync must still open merge — not “Synced”.
private func scenarioMacResurfacesExistingSibling() throws {
    let pair = try makePair()
    defer { try? FileManager.default.removeItem(at: pair.root) }
    let id = UUID()
    try (NoteFrontmatter.initialDocument(title: "T", id: id) + "Mac\n")
        .write(to: pair.mac.appendingPathComponent("t.md"), atomically: true, encoding: .utf8)
    try (NoteFrontmatter.initialDocument(title: "T", id: id) + "iOS\n")
        .write(to: pair.ios.appendingPathComponent("t.md"), atomically: true, encoding: .utf8)

    let iosCatalog = SyncCatalogBuilder.catalog(roots: [pair.ios])
    let first = try SyncCatalogBuilder.applyRemoteCatalog(
        iosCatalog, roots: [pair.mac], createDirectory: pair.mac,
        peerLabel: "iPhone", conflictRole: .mergeAuthority
    )
    guard first.conflicts.count == 1 else {
        throw HarnessError("first sync expected conflict")
    }
    let second = try SyncCatalogBuilder.applyRemoteCatalog(
        iosCatalog, roots: [pair.mac], createDirectory: pair.mac,
        peerLabel: "iPhone", conflictRole: .mergeAuthority
    )
    guard second.conflicts.count == 1 else {
        throw HarnessError("second sync must still surface conflict for merge UI, got \(second.conflicts.count)")
    }
    guard try activeNotes(in: pair.mac).count == 2 else {
        throw HarnessError("must not spam siblings")
    }

    let iosApply = try SyncCatalogBuilder.applyRemoteCatalog(
        SyncCatalogBuilder.catalog(roots: [pair.mac]),
        roots: [pair.ios], createDirectory: pair.ios,
        peerLabel: "Mac", conflictRole: .satellite
    )
    guard iosApply.awaitingAuthorityMerge.count == 1 else {
        throw HarnessError("iOS should still await Mac merge")
    }
}

/// Keep-both sibling must stay Mac-local so merge→sync of one note is Sent 1, not Sent 2.
private func scenarioConflictSiblingNotInCatalog() throws {
    let pair = try makePair()
    defer { try? FileManager.default.removeItem(at: pair.root) }
    let id = UUID()
    try (NoteFrontmatter.initialDocument(title: "T", id: id) + "Mac\n")
        .write(to: pair.mac.appendingPathComponent("t.md"), atomically: true, encoding: .utf8)
    try (NoteFrontmatter.initialDocument(title: "T", id: id) + "iOS\n")
        .write(to: pair.ios.appendingPathComponent("t.md"), atomically: true, encoding: .utf8)

    let iosCatalog = SyncCatalogBuilder.catalog(roots: [pair.ios])
    let macApply = try SyncCatalogBuilder.applyRemoteCatalog(
        iosCatalog, roots: [pair.mac], createDirectory: pair.mac,
        peerLabel: "iPhone", conflictRole: .mergeAuthority
    )
    guard macApply.conflicts.count == 1 else {
        throw HarnessError("expected conflict")
    }
    guard macApply.appliedIDs.isEmpty else {
        throw HarnessError("sibling must not be an apply ACK: \(macApply.appliedIDs)")
    }
    let onDisk = try activeNotes(in: pair.mac).count
    guard onDisk == 2 else {
        throw HarnessError("Mac should have primary + sibling on disk, got \(onDisk)")
    }
    let catalogCount = SyncCatalogBuilder.catalog(roots: [pair.mac]).count
    guard catalogCount == 1 else {
        throw HarnessError("sync catalog must omit sibling, got \(catalogCount)")
    }

    // After stamp-merge + delete sibling, Mac→iOS applies exactly one id.
    guard let conflict = macApply.conflicts.first else {
        throw HarnessError("missing conflict")
    }
    let merged = TextMerge.mergeDocuments(
        localMarkdown: conflict.local.body,
        remoteMarkdown: conflict.remote.body,
        keepingID: id,
        remoteLabel: conflict.peerLabel
    )
    var resolved = NoteFrontmatter.settingConflictResolved(Date(), in: merged.body)
    resolved = NoteFrontmatter.settingSyncID(id, in: resolved)
    let macPath = try SyncCatalogBuilder.pathIndex(roots: [pair.mac])[id]
        ?? { throw HarnessError("no mac path") }()
    try resolved.write(to: macPath, atomically: true, encoding: .utf8)
    if let sibling = conflict.remoteCopyPath {
        try FileManager.default.removeItem(at: sibling)
    }
    let iosApply = try SyncCatalogBuilder.applyRemoteCatalog(
        SyncCatalogBuilder.catalog(roots: [pair.mac]),
        roots: [pair.ios], createDirectory: pair.ios,
        peerLabel: "Mac", conflictRole: .satellite
    )
    guard iosApply.appliedIDs == [id] else {
        throw HarnessError("expected single applied id, got \(iosApply.appliedIDs)")
    }
}

private func scenarioStressAppendUnion() throws {
    var local = (0..<30).map { "shared-\($0)" }
    var remote = local
    local.append(contentsOf: (0..<20).map { "mac-\($0)" })
    remote.append(contentsOf: (0..<20).map { "ios-\($0)" })
    let result = TextMerge.twoWay(
        local: local.joined(separator: "\n") + "\n",
        remote: remote.joined(separator: "\n") + "\n"
    )
    guard result.isClean else {
        throw HarnessError("stress append should auto-merge")
    }
    for i in 0..<20 {
        guard result.body.contains("mac-\(i)"), result.body.contains("ios-\(i)") else {
            throw HarnessError("missing stress line \(i)")
        }
    }
}

/// If Mac loses `conflict_resolved` before sync, outboundIDs used to return [] (looked "synced")
/// while iOS kept the old body. That silent false-green is what left merges Mac-only.
private func scenarioUnstampedLooksUnsynced() throws {
    let id = UUID()
    let mac = NoteFrontmatter.initialDocument(title: "T", id: id) + "MERGED\n"
    let ios = NoteFrontmatter.initialDocument(title: "T", id: id) + "OLD IOS\n"
    let macPayload = SyncNotePayload(
        id: id, title: "T", modifiedAt: Date(timeIntervalSince1970: 900), body: mac
    )
    let iosPayload = SyncNotePayload(
        id: id, title: "T", modifiedAt: Date(timeIntervalSince1970: 800), body: ios
    )

    let unstampedOutbound = SyncMerge.outboundIDs(ours: [macPayload], theirs: [iosPayload])
    guard unstampedOutbound.isEmpty else {
        throw HarnessError("without stamp, bodies conflict — must not count as outbound (\(unstampedOutbound))")
    }

    let stamped = NoteFrontmatter.settingConflictResolved(Date(timeIntervalSince1970: 900), in: mac)
    let stampedPayload = SyncNotePayload(
        id: id, title: "T", modifiedAt: Date(timeIntervalSince1970: 900), body: stamped
    )
    let stampedOutbound = SyncMerge.outboundIDs(ours: [stampedPayload], theirs: [iosPayload])
    guard stampedOutbound == [id] else {
        throw HarnessError("stamped Mac merge must be outbound to iOS, got \(stampedOutbound)")
    }
}

/// Simulate Mac-as-client wire order: send Mac catalog → iOS server applies as satellite → reply.
private func scenarioWireMacClientMergeLandsOnIOS() throws {
    let pair = try makePair()
    defer { try? FileManager.default.removeItem(at: pair.root) }
    let id = UUID()
    let base = NoteFrontmatter.initialDocument(title: "Todo", id: id) + "- shared\n"
    try (base + "- mac\n").write(to: pair.mac.appendingPathComponent("t.md"), atomically: true, encoding: .utf8)
    try (base + "- ios\n").write(to: pair.ios.appendingPathComponent("t.md"), atomically: true, encoding: .utf8)

    // Mac keep-both + merge + stamp (authority side).
    let iosCatalog = SyncCatalogBuilder.catalog(roots: [pair.ios])
    let macApply = try SyncCatalogBuilder.applyRemoteCatalog(
        iosCatalog, roots: [pair.mac], createDirectory: pair.mac,
        peerLabel: "iPhone", conflictRole: .mergeAuthority
    )
    guard let conflict = macApply.conflicts.first else {
        throw HarnessError("expected Mac conflict")
    }
    let merged = TextMerge.mergeDocuments(
        localMarkdown: conflict.local.body,
        remoteMarkdown: conflict.remote.body,
        keepingID: id,
        remoteLabel: conflict.peerLabel
    )
    let now = Date()
    var resolved = NoteFrontmatter.settingConflictResolved(now, in: merged.body)
    resolved = NoteFrontmatter.settingSyncID(id, in: resolved)
    let macPath = try SyncCatalogBuilder.pathIndex(roots: [pair.mac])[id]
        ?? { throw HarnessError("no mac path") }()
    try resolved.write(to: macPath, atomically: true, encoding: .utf8)
    if let sibling = conflict.remoteCopyPath {
        _ = try NoteFrontmatter.moveToTrash(file: sibling, roots: [pair.mac])
    }

    // Wire: Mac client sends catalog first; iOS server applies then replies with fresh vault.
    let macCatalog = SyncCatalogBuilder.catalog(roots: [pair.mac])
    let iosServerApply = try SyncCatalogBuilder.applyRemoteCatalog(
        macCatalog, roots: [pair.ios], createDirectory: pair.ios,
        peerLabel: "MacBook", conflictRole: .satellite
    )
    guard iosServerApply.awaitingAuthorityMerge.isEmpty else {
        throw HarnessError("iOS server must apply stamped merge, still awaiting")
    }
    guard iosServerApply.appliedIDs.contains(id) else {
        throw HarnessError("iOS must ACK applied merge id")
    }
    let iosReply = SyncCatalogBuilder.catalog(roots: [pair.ios])
    let remaining = SyncMerge.outboundIDs(ours: macCatalog, theirs: iosReply)
    guard remaining.isEmpty else {
        throw HarnessError("after iOS apply, Mac remaining outbound must be empty: \(remaining)")
    }
    let iosBody = try String(
        contentsOf: SyncCatalogBuilder.pathIndex(roots: [pair.ios])[id]
            ?? { throw HarnessError("no ios path") }(),
        encoding: .utf8
    )
    guard iosBody.contains("- mac"), iosBody.contains("- ios") else {
        throw HarnessError("iOS missing merged lines:\n\(iosBody)")
    }
}

/// Mimic the sticky debounce race: stamp on disk, then a stale unstamped write wins — satellite must not apply.
private func scenarioStaleOverwriteBeforeSync() throws {
    let pair = try makePair()
    defer { try? FileManager.default.removeItem(at: pair.root) }
    let id = UUID()
    let macFile = pair.mac.appendingPathComponent("t.md")
    let iosFile = pair.ios.appendingPathComponent("t.md")
    let merged = NoteFrontmatter.initialDocument(title: "T", id: id) + "MERGED\n"
    let stale = NoteFrontmatter.initialDocument(title: "T", id: id) + "OLD MAC\n"
    let ios = NoteFrontmatter.initialDocument(title: "T", id: id) + "OLD IOS\n"
    try ios.write(to: iosFile, atomically: true, encoding: .utf8)

    let stamped = NoteFrontmatter.settingConflictResolved(Date(), in: merged)
    try stamped.write(to: macFile, atomically: true, encoding: .utf8)
    // Stale editor save (the bug): overwrite without stamp.
    try stale.write(to: macFile, atomically: true, encoding: .utf8)

    let apply = try SyncCatalogBuilder.applyRemoteCatalog(
        SyncCatalogBuilder.catalog(roots: [pair.mac]),
        roots: [pair.ios],
        createDirectory: pair.ios,
        peerLabel: "Mac",
        conflictRole: .satellite
    )
    guard apply.awaitingAuthorityMerge.count == 1 else {
        throw HarnessError("stale unstamped Mac must leave iOS awaiting, got \(apply.awaitingAuthorityMerge.count)")
    }
    let still = try String(contentsOf: iosFile, encoding: .utf8)
    guard still.contains("OLD IOS") else {
        throw HarnessError("iOS must keep old body when Mac stamp was wiped")
    }
    // Recovery: re-stamp and sync again (what mergeConflict now does before syncNow).
    try stamped.write(to: macFile, atomically: true, encoding: .utf8)
    let recovered = try SyncCatalogBuilder.applyRemoteCatalog(
        SyncCatalogBuilder.catalog(roots: [pair.mac]),
        roots: [pair.ios],
        createDirectory: pair.ios,
        peerLabel: "Mac",
        conflictRole: .satellite
    )
    guard recovered.awaitingAuthorityMerge.isEmpty else {
        throw HarnessError("re-stamp must apply on iOS")
    }
    let after = try String(contentsOf: iosFile, encoding: .utf8)
    guard after.contains("MERGED") else {
        throw HarnessError("iOS missing recovered merge")
    }
}
