import Foundation

/// The one place that writes, moves or trashes notes and images on a device (spec §3.9).
///
/// Every operation states what it expects to find (a hash, or "must not exist") and fails
/// cleanly when that isn't true. It never hard-deletes and never overwrites without a copy:
/// - trash goes through `TrashBin` (macOS Trash, or `.stickies-trash/` on iOS)
/// - an overwritten file is copied through `OverwriteBackup` first (`Backups/` or `.stickies-trash/`)
///
/// Sync operations also refuse notes that have unsaved edits in an open editor.
public actor NoteWriter {
    public enum Origin: Sendable {
        /// A sync step: refused while the note has unsaved edits.
        case sync
        /// The app itself (editor save, merge, color change, rename).
        case app
    }

    public enum Failure: Error, Equatable, Sendable {
        /// The file isn't what the step expected (edited meanwhile).
        case changedOnDisk(expected: String, found: String)
        /// The step expected a file, but there is none.
        case missing
        /// The target exists (compared ignoring case).
        case alreadyExists
        /// The note has unsaved edits in an open editor.
        case unsavedEdits
        case io(String)
    }

    private let trashBin: TrashBin
    private let backup: OverwriteBackup
    private let editors: EditorRegistry
    public nonisolated let recentWrites: RecentWrites

    public init(
        trash: TrashBin,
        backup: OverwriteBackup,
        editors: EditorRegistry,
        recentWrites: RecentWrites = RecentWrites()
    ) {
        self.trashBin = trash
        self.backup = backup
        self.editors = editors
        self.recentWrites = recentWrites
    }

    /// Writes `data` to `url`. Returns the new file hash.
    @discardableResult
    public func write(_ data: Data, to url: URL, expect: SyncExpectation, origin: Origin) throws -> String {
        let url = url.standardizedFileURL
        try checkEditor(url, origin: origin)
        switch expect {
        case .absent:
            guard !Self.existsIgnoringCase(url) else { throw Failure.alreadyExists }
        case .hash(let expected):
            try checkHash(url, expected: expected)
        }

        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).stickies-tmp-\(Self.shortToken())")
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: temp)
            switch expect {
            case .absent:
                try fm.moveItem(at: temp, to: url)   // fails if something appeared meanwhile
            case .hash:
                try backup.preserveCopy(of: url)
                _ = try fm.replaceItemAt(url, withItemAt: temp)
            }
        } catch let failure as Failure {
            try? fm.removeItem(at: temp)
            throw failure
        } catch {
            try? fm.removeItem(at: temp)
            throw Failure.io(error.localizedDescription)
        }
        recentWrites.record(url)
        return NoteHashing.fileHash(data)
    }

    /// Moves a file. The target must be free; a rename that only changes capitalization
    /// goes through a temporary visible name so it works on case-insensitive volumes.
    public func move(from source: URL, to target: URL, expectHash: String, origin: Origin) throws {
        let source = source.standardizedFileURL
        let target = target.standardizedFileURL
        guard source.path != target.path else { return }
        try checkEditor(source, origin: origin)
        try checkHash(source, expected: expectHash)

        let fm = FileManager.default
        let caseOnly = PathRules.collisionKey(source.path) == PathRules.collisionKey(target.path)
        if caseOnly {
            if fm.fileExists(atPath: target.path), !Self.isSameFile(source, target) {
                throw Failure.alreadyExists   // a case-sensitive volume with both names
            }
        } else if Self.existsIgnoringCase(target) {
            throw Failure.alreadyExists
        }

        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if caseOnly {
                let stem = (source.lastPathComponent as NSString).deletingPathExtension
                let temp = source.deletingLastPathComponent()
                    .appendingPathComponent("\(stem).stickies-move-\(Self.shortToken()).md")
                try fm.moveItem(at: source, to: temp)
                try fm.moveItem(at: temp, to: target)
            } else {
                try fm.moveItem(at: source, to: target)
            }
        } catch {
            throw Failure.io(error.localizedDescription)
        }
        recentWrites.record(source)
        recentWrites.record(target)
    }

    /// Moves a file to the trash after checking its hash.
    public func trash(_ url: URL, expectHash: String, origin: Origin) throws {
        let url = url.standardizedFileURL
        try checkEditor(url, origin: origin)
        try checkHash(url, expected: expectHash)
        do {
            try trashBin.moveToTrash(url)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.io(error.localizedDescription)
        }
        recentWrites.record(url)
    }

    // MARK: - Helpers

    /// Hash of the file's current bytes, or `nil` if it can't be read.
    public static func currentHash(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return NoteHashing.fileHash(data)
    }

    /// True if `url` exists, or a sibling whose name differs only in case or Unicode form.
    public static func existsIgnoringCase(_ url: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { return true }
        guard let names = try? fm.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) else {
            return false
        }
        let key = PathRules.collisionKey(url.lastPathComponent)
        return names.contains { PathRules.collisionKey($0) == key }
    }

    private func checkEditor(_ url: URL, origin: Origin) throws {
        if origin == .sync, editors.hasUnsavedEdits(url) { throw Failure.unsavedEdits }
    }

    private func checkHash(_ url: URL, expected: String) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw Failure.missing }
        guard let found = Self.currentHash(of: url) else { throw Failure.io("Couldn't read \(url.lastPathComponent)") }
        guard found == expected else { throw Failure.changedOnDisk(expected: expected, found: found) }
    }

    private static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        let key: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let left = try? a.resourceValues(forKeys: key).fileResourceIdentifier,
              let right = try? b.resourceValues(forKeys: key).fileResourceIdentifier
        else { return false }
        return left.isEqual(right)
    }

    private static func shortToken() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }
}

/// Which notes have unsaved edits in an open editor. Editors report here; the writer checks it.
public final class EditorRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var unsaved: Set<String> = []

    public init() {}

    public func setUnsavedEdits(_ hasEdits: Bool, for url: URL) {
        let key = url.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        if hasEdits {
            unsaved.insert(key)
        } else {
            unsaved.remove(key)
        }
    }

    public func hasUnsavedEdits(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return unsaved.contains(url.standardizedFileURL.path)
    }
}

/// Files the app wrote itself, so the folder watcher can ignore the events they cause.
public final class RecentWrites: @unchecked Sendable {
    private let lock = NSLock()
    private var written: [String: Date] = [:]
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public func record(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        written[url.standardizedFileURL.path] = now()
    }

    /// True if the app wrote `url` within the last `seconds`.
    public func contains(_ url: URL, within seconds: TimeInterval = 1.5) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let cutoff = now().addingTimeInterval(-seconds)
        written = written.filter { $0.value >= cutoff }
        return written[url.standardizedFileURL.path] != nil
    }
}
