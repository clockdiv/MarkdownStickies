import Foundation

/// `stickies-id` and color per note file, cached by modification date and size so a rescan
/// only reads files that changed. Thread-safe.
public final class NoteIDIndex: @unchecked Sendable {
    public struct Entry: Equatable, Sendable {
        public var id: UUID?
        public var color: NoteColor?
    }

    private struct Cached {
        var modified: Date?
        var size: Int?
        var entry: Entry
    }

    private let lock = NSLock()
    private var cache: [String: Cached] = [:]

    public init() {}

    /// The note's id and color, reading the file only if it changed since the last call.
    public func entry(for url: URL) -> Entry {
        let key = url.standardizedFileURL.path
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        lock.lock()
        if let cached = cache[key], cached.modified == values?.contentModificationDate, cached.size == values?.fileSize {
            lock.unlock()
            return cached.entry
        }
        lock.unlock()

        let data = (try? Data(contentsOf: url)) ?? Data()
        let entry = Entry(id: StickiesFrontmatter.id(in: data), color: StickiesFrontmatter.color(in: data))
        lock.lock()
        cache[key] = Cached(modified: values?.contentModificationDate, size: values?.fileSize, entry: entry)
        lock.unlock()
        return entry
    }

    /// Updates the cache after the app itself wrote a file.
    public func invalidate(_ url: URL) {
        lock.lock()
        cache[url.standardizedFileURL.path] = nil
        lock.unlock()
    }
}
