import Foundation

/// How the base advances after a sync (session step 9). Pure.
///
/// Per note and image:
/// - both sides confirmed with the same hash and the same location → that becomes the base
/// - both sides confirmed gone → the base entry is removed
/// - anything else (a step was skipped, a move didn't happen, the note was skipped) → unchanged
///
/// So the base is always a state both devices really had at the same time.
public enum SyncCommit {
    public static func nextBase(
        previous: SyncBase,
        macNotes: [ManifestNote],
        iosNotes: [ManifestNote],
        macImages: [ManifestImage],
        iosImages: [ManifestImage],
        frozenNoteIDs: Set<UUID>,
        frozenImages: Set<ImageKey>
    ) -> SyncBase {
        var next = previous

        let mac = Dictionary(grouping: macNotes, by: \.id)
        let ios = Dictionary(grouping: iosNotes, by: \.id)
        var ids = Set(previous.notes.keys)
        ids.formUnion(mac.keys)
        ids.formUnion(ios.keys)

        for id in ids where !frozenNoteIDs.contains(id) {
            let m = mac[id] ?? []
            let i = ios[id] ?? []
            guard m.count <= 1, i.count <= 1 else { continue }   // duplicates: leave as is

            switch (m.first, i.first) {
            case let (m?, i?) where m.fileHash == i.fileHash && m.location == i.location:
                next.notes[id] = SyncBase.Note(
                    location: m.location,
                    fileHash: m.fileHash,
                    restHash: m.restHash,
                    color: m.color
                )
            case (nil, nil):
                next.notes[id] = nil
            default:
                break
            }
        }

        let macHashes = Dictionary(macImages.map { ($0.key, $0.hash) }, uniquingKeysWith: { first, _ in first })
        let iosHashes = Dictionary(iosImages.map { ($0.key, $0.hash) }, uniquingKeysWith: { first, _ in first })
        var keys = Set(previous.images.keys)
        keys.formUnion(macHashes.keys)
        keys.formUnion(iosHashes.keys)

        for key in keys where !frozenImages.contains(key) {
            switch (macHashes[key], iosHashes[key]) {
            case let (m?, i?) where m == i:
                next.images[key] = m
            case (nil, nil):
                next.images[key] = nil
            default:
                break
            }
        }
        return next
    }
}
