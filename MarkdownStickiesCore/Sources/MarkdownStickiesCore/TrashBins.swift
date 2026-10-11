import Foundation

/// Where deleted files go. Never a hard delete.
public protocol TrashBin: Sendable {
    func moveToTrash(_ url: URL) throws
}

/// Where a file is copied before it is overwritten.
public protocol OverwriteBackup: Sendable {
    func preserveCopy(of url: URL) throws
}

/// macOS Trash (`FileManager.trashItem`). If the volume has no Trash, the move fails and
/// the caller skips the step; there is no fallback to deleting.
public struct SystemTrash: TrashBin {
    public init() {}

    public func moveToTrash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}

/// `Stickies Trash/<yyyy-mm-dd>/<path inside the vault>` on iOS. Serves as trash and as the
/// place for copies of overwritten files. Kept 30 days (`purge`).
///
/// The folder is visible on purpose: iOS "On My iPhone" folders refuse names starting with a dot,
/// and a visible folder lets you restore notes in the Files app. It's never synced or listed.
public struct FolderTrash: TrashBin, OverwriteBackup {
    public static let folderName = "Stickies Trash"
    public static let retentionDays = 30

    public let vault: URL
    private let now: @Sendable () -> Date

    public init(vault: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.vault = vault.standardizedFileURL
        self.now = now
    }

    public var directory: URL { vault.appendingPathComponent(Self.folderName, isDirectory: true) }

    public func moveToTrash(_ url: URL) throws {
        let destination = try freeDestination(for: url)
        try FileManager.default.moveItem(at: url, to: destination)
    }

    public func preserveCopy(of url: URL) throws {
        let destination = try freeDestination(for: url)
        try FileManager.default.copyItem(at: url, to: destination)
    }

    /// Removes day folders older than the retention period. This is the only real deletion,
    /// and it only touches the app's own trash folder.
    public func purge() {
        DatedFolders.purge(directory, olderThanDays: Self.retentionDays, now: now())
    }

    private func freeDestination(for url: URL) throws -> URL {
        let relative = DatedFolders.relativePath(of: url.standardizedFileURL, under: vault)
        let day = directory.appendingPathComponent(DatedFolders.dayName(now()), isDirectory: true)
        return try DatedFolders.freeURL(day.appendingPathComponent(relative))
    }
}

/// Mac copies of files overwritten by sync or merge:
/// `Backups/<yyyy-mm-dd>/<absolute path of the file>`. Kept 30 days (`purge`).
public struct BackupFolder: OverwriteBackup {
    public static let retentionDays = 30

    public let directory: URL
    private let now: @Sendable () -> Date

    public init(directory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory.standardizedFileURL
        self.now = now
    }

    public func preserveCopy(of url: URL) throws {
        let day = directory.appendingPathComponent(DatedFolders.dayName(now()), isDirectory: true)
        let path = url.standardizedFileURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let destination = try DatedFolders.freeURL(day.appendingPathComponent(path))
        try FileManager.default.copyItem(at: url, to: destination)
    }

    public func purge() {
        DatedFolders.purge(directory, olderThanDays: Self.retentionDays, now: now())
    }
}

enum DatedFolders {
    static func dayName(_ date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func date(fromDayName name: String) -> Date? {
        let parts = name.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar(identifier: .gregorian).date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func relativePath(of url: URL, under root: URL) -> String {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path.hasPrefix(rootPath) else { return url.lastPathComponent }
        return String(url.path.dropFirst(rootPath.count))
    }

    /// `url`, or `name (2).ext`, `name (3).ext`, … if taken. Creates the parent directory.
    static func freeURL(_ url: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fm.fileExists(atPath: url.path) else { return url }
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var index = 2
        while true {
            let name = ext.isEmpty ? "\(stem) (\(index))" : "\(stem) (\(index)).\(ext)"
            let candidate = url.deletingLastPathComponent().appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    static func purge(_ directory: URL, olderThanDays days: Int, now: Date) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path),
              let cutoff = Calendar(identifier: .gregorian).date(byAdding: .day, value: -days, to: now)
        else { return }
        for name in names {
            guard let day = date(fromDayName: name), day < cutoff else { continue }
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
