import Foundation

/// Decides what a sync does. Pure: no file access, no network, no clock (time comes from `Context`).
///
/// Inputs are the two manifests and the base; the output is an ordered list of conditional steps
/// plus the cases that were skipped. Anything Core v1 doesn't handle is skipped and reported,
/// never guessed (spec §0 "Scope").
public enum SyncPlanner {
    public struct Context {
        /// Mac root for new iOS notes (the Inbox). `nil` when the Mac has no synced root.
        public var defaultRootID: UUID?
        /// Used in conflict-copy names.
        public var peerDeviceName: String
        public var now: Date
        public var timeZone: TimeZone
        /// More trashed notes than this on one device needs the user's confirmation.
        public var bulkTrashLimit: Int
        /// Whether an iOS location is allowed on the Mac (scan.conf, skipped folders, deeper roots).
        public var macAllows: (NoteLocation) -> Bool

        public init(
            defaultRootID: UUID?,
            peerDeviceName: String,
            now: Date = Date(),
            timeZone: TimeZone = .current,
            bulkTrashLimit: Int = 10,
            macAllows: @escaping (NoteLocation) -> Bool = { _ in true }
        ) {
            self.defaultRootID = defaultRootID
            self.peerDeviceName = peerDeviceName
            self.now = now
            self.timeZone = timeZone
            self.bulkTrashLimit = bulkTrashLimit
            self.macAllows = macAllows
        }
    }

    public static func plan(
        mac: SyncManifest,
        ios: SyncManifest,
        base: SyncBase,
        context: Context
    ) -> SyncPlan {
        let macByID = Dictionary(grouping: mac.notes, by: \.id)
        let iosByID = Dictionary(grouping: ios.notes, by: \.id)
        let leftByID = Dictionary(mac.left.map { ($0.id, $0.location) }, uniquingKeysWith: { first, _ in first })

        var ids = Set(base.notes.keys)
        ids.formUnion(macByID.keys)
        ids.formUnion(iosByID.keys)
        ids.formUnion(leftByID.keys)

        var tokens = 0
        var notePlans: [NotePlan] = []
        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
            var planner = NoteDecision(
                id: id,
                mac: macByID[id] ?? [],
                ios: iosByID[id] ?? [],
                left: leftByID[id],
                base: base.notes[id],
                macUnreadable: Set(mac.unreadable),
                iosUnreadable: Set(ios.unreadable),
                macIDs: Set(macByID.keys),
                context: context,
                tokens: tokens
            )
            notePlans.append(planner.decide())
            tokens = planner.tokens
        }

        resolveCollisions(&notePlans, mac: mac, ios: ios)

        var drafts = notePlans.flatMap(\.drafts)
        var skipped: [SyncSkip] = []
        var frozenNotes: Set<UUID> = []
        var referenced: Set<ImageKey> = []
        for plan in notePlans {
            if let skip = plan.skip {
                skipped.append(SyncSkip(noteID: plan.id, reason: skip))
                frozenNotes.insert(plan.id)
                referenced.formUnion(plan.fallbackRefs)
            } else {
                referenced.formUnion(plan.refs)
            }
            skipped += plan.notices.map { SyncSkip(noteID: plan.id, reason: $0) }
        }

        let images = planImages(mac: mac, ios: ios, base: base, referenced: referenced, tokens: &tokens)
        drafts += images.drafts
        skipped += images.skipped

        var trashed: [SyncDevice: Int] = [.mac: 0, .ios: 0]
        for draft in drafts {
            if case .trashNote = draft.action { trashed[draft.device, default: 0] += 1 }
        }

        return SyncPlan(
            steps: numbered(drafts),
            skipped: skipped,
            trashedNoteCount: trashed,
            needsConfirmation: trashed.values.contains { $0 > context.bulkTrashLimit },
            frozenNoteIDs: frozenNotes,
            frozenImages: images.frozen
        )
    }

    // MARK: - Per-note decision

    struct Draft {
        var token: Int
        var device: SyncDevice
        var action: SyncAction
        var dependsOn: [Int]
    }

    struct NotePlan {
        var id: UUID
        var drafts: [Draft] = []
        /// Images referenced by the versions both sides will have after the plan.
        var refs: Set<ImageKey> = []
        /// Images to keep if this note ends up skipped: everything either version references.
        var fallbackRefs: Set<ImageKey> = []
        /// Set when the whole note is skipped: no steps, base frozen.
        var skip: SyncSkipReason?
        /// Reported, but the note's other steps still run.
        var notices: [SyncSkipReason] = []
        /// Locations that must be free (or already this note's) on each device.
        var macTargets: [NoteLocation] = []
        var iosTargets: [NoteLocation] = []
    }

    private struct NoteDecision {
        let id: UUID
        let mac: [ManifestNote]
        let ios: [ManifestNote]
        let left: NoteLocation?
        let base: SyncBase.Note?
        let macUnreadable: Set<NoteLocation>
        let iosUnreadable: Set<NoteLocation>
        let macIDs: Set<UUID>
        let context: Context
        var tokens: Int
        private var plan: NotePlan

        init(
            id: UUID,
            mac: [ManifestNote],
            ios: [ManifestNote],
            left: NoteLocation?,
            base: SyncBase.Note?,
            macUnreadable: Set<NoteLocation>,
            iosUnreadable: Set<NoteLocation>,
            macIDs: Set<UUID>,
            context: Context,
            tokens: Int
        ) {
            self.id = id
            self.mac = mac
            self.ios = ios
            self.left = left
            self.base = base
            self.macUnreadable = macUnreadable
            self.iosUnreadable = iosUnreadable
            self.macIDs = macIDs
            self.context = context
            self.tokens = tokens
            self.plan = NotePlan(id: id)
            self.plan.fallbackRefs = (mac + ios).reduce(into: []) { $0.formUnion(Self.refs(of: $1)) }
        }

        mutating func decide() -> NotePlan {
            if mac.count > 1 { return skipped(.duplicateID(.mac, mac.map(\.location).sorted())) }
            if ios.count > 1 { return skipped(.duplicateID(.ios, ios.map(\.location).sorted())) }
            let m = mac.first
            let i = ios.first

            // "Can't read" never means "deleted" (rule 9).
            if m == nil, left == nil, let base, macUnreadable.contains(base.location) {
                return skipped(.unreadable(.mac, base.location))
            }
            if i == nil, let base, iosUnreadable.contains(base.location) {
                return skipped(.unreadable(.ios, base.location))
            }

            // Where the iOS file belongs: Inbox notes go to the Mac's default root.
            var iosTarget: NoteLocation?
            if let i {
                if i.location.isInbox {
                    guard let root = context.defaultRootID else {
                        return skipped(.noSyncedFolderForNewNote(i.location))
                    }
                    iosTarget = NoteLocation(rootID: root, path: i.location.filename)
                } else {
                    iosTarget = i.location
                }
            }

            switch (m, i, iosTarget) {
            case let (m?, i?, target?):
                decideBoth(m, i, iosTarget: target)
            case let (m?, nil, _):
                decideMacOnly(m)
            case let (nil, i?, target?):
                if let skip = decideIOSOnly(i, iosTarget: target) { return skipped(skip) }
            default:
                break   // gone on both sides: commit forgets the base
            }
            return plan
        }

        private mutating func decideBoth(_ m: ManifestNote, _ i: ManifestNote, iosTarget: NoteLocation) {
            enum Content { case same, macToIOS, iosToMac, conflict }
            let macChanged = base.map { m.fileHash != $0.fileHash } ?? true
            let iosChanged = base.map { i.fileHash != $0.fileHash } ?? true
            let content: Content
            if m.fileHash == i.fileHash {
                content = .same
            } else if macChanged && !iosChanged {
                content = .macToIOS
            } else if iosChanged && !macChanged {
                content = .iosToMac
            } else {
                content = .conflict   // v1: field merge is later, so a color-only difference also lands here
            }

            // Path: one side moved → follow it; both moved → the Mac wins; conflicts keep the Mac's path.
            var final = m.location
            var keepIOSLocation = false
            if content != .conflict, let base, m.location == base.location, iosTarget != base.location {
                if iosTarget.collisionKey == m.location.collisionKey {
                    plan.notices.append(.capitalizationOnlyRename(from: m.location, to: iosTarget))
                    keepIOSLocation = true
                } else if !context.macAllows(iosTarget) {
                    plan.notices.append(.excludedOnMac(iosTarget))
                    keepIOSLocation = true
                } else {
                    final = iosTarget
                }
            }

            var macWrite: Int?
            var iosWrite: Int?
            switch content {
            case .same:
                break
            case .macToIOS:
                iosWrite = add(.ios, .writeNote(id: id, at: i.location, expect: .hash(i.fileHash), source: .macNote(id)))
            case .iosToMac:
                macWrite = add(.mac, .writeNote(id: id, at: m.location, expect: .hash(m.fileHash), source: .iosNote(id)))
            case .conflict:
                var after: [Int] = []
                let copyID = ConflictCopy.id(originalID: id, sourceFileHash: i.fileHash)
                if !macIDs.contains(copyID) {
                    let name = ConflictCopy.filename(
                        forOriginal: m.location.filename,
                        deviceName: context.peerDeviceName,
                        date: context.now,
                        timeZone: context.timeZone
                    )
                    let copyLocation = m.location.sibling(named: name)
                    let copy = add(.mac, .writeConflictCopy(
                        id: copyID,
                        original: id,
                        at: copyLocation,
                        source: .iosNoteAsConflictCopy(original: id, copy: copyID)
                    ))
                    _ = add(.ios, .writeNote(id: copyID, at: copyLocation, expect: .absent, source: .macNote(copyID)), after: [copy])
                    plan.macTargets.append(copyLocation)
                    plan.iosTargets.append(copyLocation)
                    after = [copy]
                }
                // The iOS version survives as the copy; only then may the iOS original be overwritten.
                iosWrite = add(.ios, .writeNote(id: id, at: i.location, expect: .hash(i.fileHash), source: .macNote(id)), after: after)
            }

            if final != m.location {
                let hash = content == .iosToMac ? i.fileHash : m.fileHash
                _ = add(.mac, .moveNote(id: id, from: m.location, to: final, expectHash: hash), after: macWrite.map { [$0] } ?? [])
                plan.macTargets.append(final)
            }
            if !keepIOSLocation, final != i.location {
                let hash = (content == .iosToMac || content == .same) ? i.fileHash : m.fileHash
                _ = add(.ios, .moveNote(id: id, from: i.location, to: final, expectHash: hash), after: iosWrite.map { [$0] } ?? [])
                plan.iosTargets.append(final)
            }

            switch content {
            case .same, .macToIOS: plan.refs = Self.refs(of: m)
            case .iosToMac: plan.refs = Self.refs(of: i)
            case .conflict: plan.refs = Self.refs(of: m).union(Self.refs(of: i))
            }
        }

        private mutating func decideMacOnly(_ m: ManifestNote) {
            if let base, m.fileHash == base.fileHash {
                // Deleted on iOS, unchanged on the Mac.
                _ = add(.mac, .trashNote(id: id, at: m.location, expectHash: m.fileHash))
                return
            }
            // New on the Mac, or edited on the Mac after iOS deleted it (edit wins).
            _ = add(.ios, .writeNote(id: id, at: m.location, expect: .absent, source: .macNote(id)))
            plan.iosTargets.append(m.location)
            plan.refs = Self.refs(of: m)
        }

        private mutating func decideIOSOnly(_ i: ManifestNote, iosTarget: NoteLocation) -> SyncSkipReason? {
            if let left, let base {
                guard i.fileHash == base.fileHash else { return .editedOnPeerButNoLongerSynced(left) }
                _ = add(.ios, .trashNote(id: id, at: i.location, expectHash: i.fileHash))
                return nil
            }
            if let base, i.fileHash == base.fileHash {
                // Deleted on the Mac, unchanged on iOS.
                _ = add(.ios, .trashNote(id: id, at: i.location, expectHash: i.fileHash))
                return nil
            }
            // New on iOS, or edited on iOS after the Mac deleted it (edit wins).
            guard context.macAllows(iosTarget) else { return .excludedOnMac(iosTarget) }
            let write = add(.mac, .writeNote(id: id, at: iosTarget, expect: .absent, source: .iosNote(id)))
            plan.macTargets.append(iosTarget)
            if i.location != iosTarget {
                _ = add(.ios, .moveNote(id: id, from: i.location, to: iosTarget, expectHash: i.fileHash), after: [write])
                plan.iosTargets.append(iosTarget)
            }
            plan.refs = Self.refs(of: i)
            return nil
        }

        private mutating func add(_ device: SyncDevice, _ action: SyncAction, after: [Int] = []) -> Int {
            tokens += 1
            plan.drafts.append(Draft(token: tokens, device: device, action: action, dependsOn: after))
            return tokens
        }

        private func skipped(_ reason: SyncSkipReason) -> NotePlan {
            var skipped = NotePlan(id: id)
            skipped.skip = reason
            skipped.fallbackRefs = plan.fallbackRefs
            return skipped
        }

        static func refs(of note: ManifestNote) -> Set<ImageKey> {
            guard let root = note.location.rootID else { return [] }
            return Set(note.imageRefs.map { ImageKey(rootID: root, path: $0) })
        }
    }

    // MARK: - Collisions

    /// A target is free when no other file uses it (case-insensitively) and no earlier note claimed it.
    /// Moving away doesn't free a location within the same plan, so swaps are skipped (later case).
    private static func resolveCollisions(_ plans: inout [NotePlan], mac: SyncManifest, ios: SyncManifest) {
        var macUsers = occupancy(notes: mac.notes, left: mac.left, unreadable: mac.unreadable)
        var iosUsers = occupancy(notes: ios.notes, left: [], unreadable: ios.unreadable)

        for index in plans.indices where plans[index].skip == nil {
            let plan = plans[index]
            let macTaken = plan.macTargets.first { isTaken($0, by: macUsers, for: plan.id) }
            let iosTaken = plan.iosTargets.first { isTaken($0, by: iosUsers, for: plan.id) }
            if let taken = macTaken ?? iosTaken {
                var skipped = NotePlan(id: plan.id)
                skipped.skip = .targetTaken(macTaken != nil ? .mac : .ios, taken)
                skipped.fallbackRefs = plan.fallbackRefs
                plans[index] = skipped
                continue
            }
            for target in plan.macTargets { macUsers[target.collisionKey] = plan.id }
            for target in plan.iosTargets { iosUsers[target.collisionKey] = plan.id }
        }
    }

    /// Collision key → the note using it, or `nil` for a file that isn't a known note.
    private static func occupancy(
        notes: [ManifestNote],
        left: [LeftNote],
        unreadable: [NoteLocation]
    ) -> [String: UUID?] {
        var users: [String: UUID?] = [:]
        for location in unreadable { users[location.collisionKey] = .some(nil) }
        for note in left { users[note.location.collisionKey] = note.id }
        for note in notes { users[note.location.collisionKey] = note.id }
        return users
    }

    private static func isTaken(_ location: NoteLocation, by users: [String: UUID?], for id: UUID) -> Bool {
        guard let user = users[location.collisionKey] else { return false }
        return user != id
    }

    // MARK: - Images

    private static func planImages(
        mac: SyncManifest,
        ios: SyncManifest,
        base: SyncBase,
        referenced: Set<ImageKey>,
        tokens: inout Int
    ) -> (drafts: [Draft], skipped: [SyncSkip], frozen: Set<ImageKey>) {
        let macImages = Dictionary(mac.images.map { ($0.key, $0.hash) }, uniquingKeysWith: { first, _ in first })
        let iosImages = Dictionary(ios.images.map { ($0.key, $0.hash) }, uniquingKeysWith: { first, _ in first })
        var keys = Set(macImages.keys)
        keys.formUnion(iosImages.keys)
        keys.formUnion(base.images.keys)

        var drafts: [Draft] = []
        var skipped: [SyncSkip] = []
        var frozen: Set<ImageKey> = []
        func add(_ device: SyncDevice, _ action: SyncAction) {
            tokens += 1
            drafts.append(Draft(token: tokens, device: device, action: action, dependsOn: []))
        }

        for key in keys.sorted() {
            let macHash = macImages[key]
            let iosHash = iosImages[key]
            guard referenced.contains(key) else {
                // No synced note uses it any more: the iOS copy goes; the Mac file is never touched.
                if let iosHash { add(.ios, .trashImage(key: key, expectHash: iosHash)) }
                continue
            }
            switch (macHash, iosHash) {
            case let (macHash?, iosHash?) where macHash == iosHash:
                break
            case (.some, nil):
                add(.ios, .writeImage(key: key, expect: .absent, source: .macImage(key)))
            case let (macHash?, iosHash?):
                if base.images[key] == macHash {
                    add(.mac, .writeImage(key: key, expect: .hash(macHash), source: .iosImage(key)))
                } else {
                    add(.ios, .writeImage(key: key, expect: .hash(iosHash), source: .macImage(key)))   // Mac wins
                }
            case let (nil, iosHash?):
                if base.images[key] != nil {
                    add(.ios, .trashImage(key: key, expectHash: iosHash))   // deleted on the Mac
                } else {
                    skipped.append(SyncSkip(noteID: nil, reason: .imageAddedOnPeer(key)))
                    frozen.insert(key)
                }
            case (nil, nil):
                break   // referenced but missing everywhere: a broken link
            }
        }
        return (drafts, skipped, frozen)
    }

    // MARK: - Ordering

    /// Mac steps first, then iOS; within a device: conflict copies, writes, moves, trash.
    /// Dependencies always point to earlier steps.
    private static func numbered(_ drafts: [Draft]) -> [SyncStep] {
        let ordered = drafts.sorted { lhs, rhs in
            if lhs.device != rhs.device { return lhs.device == .mac }
            if lhs.action.phase != rhs.action.phase { return lhs.action.phase < rhs.action.phase }
            return lhs.token < rhs.token
        }
        var idForToken: [Int: Int] = [:]
        for (offset, draft) in ordered.enumerated() { idForToken[draft.token] = offset + 1 }
        return ordered.map { draft in
            SyncStep(
                id: idForToken[draft.token]!,
                device: draft.device,
                action: draft.action,
                dependsOn: draft.dependsOn.compactMap { idForToken[$0] }
            )
        }
    }
}
