import Foundation
import MarkdownStickiesCore

@MainActor
final class NoteStateStore: ObservableObject {
    @Published private(set) var states: [String: NoteWindowState] = [:]
    @Published private(set) var activeSet: Int = 0
    /// Open sticky paths per set index (0…9).
    @Published private(set) var setOpenPaths: [Int: [String]] = [:]

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?
    /// `stickies-id` of a note file (set by `NoteStore`). Notes with an id are keyed by it, so
    /// their state survives renames and Finder moves; notes without one stay keyed by path.
    var resolveID: ((URL) -> UUID?)?

    init() {
        try? MarkdownStickiesConfig.ensureDirectory()
        fileURL = MarkdownStickiesConfig.noteStateURL
        migrateFromLegacyLocationsIfNeeded()
        load()
    }

    /// Prefer `~/.markdown-stickies/`; copy once from Application Support / old sandbox path.
    private func migrateFromLegacyLocationsIfNeeded() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: fileURL.path) else { return }

        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MarkdownStickies", isDirectory: true)
            .appendingPathComponent("note-state.json")
        let sandbox = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Containers/com.markdownstickies.app/Data/Library/Application Support/MarkdownStickies/note-state.json"
            )

        for legacy in [appSupport, sandbox] where fm.fileExists(atPath: legacy.path) {
            try? fm.copyItem(at: legacy, to: fileURL)
            if fm.fileExists(atPath: fileURL.path) { return }
        }
    }

    /// Persistence key: `id:<uuid>` for tracked notes, the path otherwise.
    func key(for path: URL) -> String {
        resolveID?(path).map { "id:" + $0.uuidString } ?? path.path
    }

    func state(for path: URL) -> NoteWindowState {
        storedState(for: path) ?? .default()
    }

    /// Stored window state only if this note already has an entry (e.g. was opened before).
    /// Falls back to a path-keyed entry that hasn't been migrated yet.
    func storedState(for path: URL) -> NoteWindowState? {
        states[key(for: path)] ?? states[path.path]
    }

    /// Moves path-keyed entries of notes that now have an id to their id key.
    /// Called after scans, never while a view reads state.
    func migrateLegacyKeys(for paths: [URL]) {
        var changed = false
        var layouts = setOpenPaths
        for path in paths {
            let key = key(for: path)
            guard key != path.path, let legacy = states[path.path] else { continue }
            if states[key] == nil { states[key] = legacy }
            states[path.path] = nil
            for (set, keys) in layouts {
                layouts[set] = keys.map { $0 == path.path ? key : $0 }
            }
            changed = true
        }
        if changed {
            setOpenPaths = layouts
            scheduleSave()
        }
    }

    func update(_ path: URL, mutate: (inout NoteWindowState) -> Void) {
        let key = key(for: path)
        var current = states[key] ?? states[path.path] ?? .default()
        if key != path.path { states[path.path] = nil }
        mutate(&current)
        states[key] = current
        scheduleSave()
    }

    func setActiveSet(_ index: Int) {
        let next = NoteWindowState.clampedSetIndex(index)
        guard next != activeSet else { return }
        activeSet = next
        scheduleSave()
    }

    /// Mark a note open/closed in the **active** set’s layout.
    func setOpen(_ path: URL, isOpen: Bool) {
        let key = key(for: path)
        var layouts = setOpenPaths
        var keys = Set(layouts[activeSet] ?? [])
        if isOpen {
            keys.insert(key)
            if states[key] == nil {
                states[key] = .default()
            }
        } else {
            keys.remove(key)
        }
        layouts[activeSet] = Array(keys).sorted()
        setOpenPaths = layouts
        scheduleSave()
    }

    /// Replace the open-note list for a set (used when parking before a switch).
    func replaceOpenPaths(_ paths: [URL], inSet set: Int) {
        let index = NoteWindowState.clampedSetIndex(set)
        var layouts = setOpenPaths
        layouts[index] = Array(Set(paths.map(key(for:)))).sorted()
        setOpenPaths = layouts
        scheduleSave()
    }

    func touchLastOpened(_ path: URL, at date: Date = Date()) {
        update(path) {
            $0.lastOpenedAt = date
            $0.removedFromRecentsAt = nil
        }
    }

    /// Clear the recents ranking; keep a burial marker so sort puts the note at the bottom.
    func markRemovedFromRecents(_ path: URL, at date: Date = Date()) {
        update(path) {
            $0.lastOpenedAt = nil
            $0.removedFromRecentsAt = date
            $0.floatOnTop = false
            $0.isOpen = false
        }
        let key = key(for: path)
        var layouts = setOpenPaths
        for (set, paths) in layouts {
            layouts[set] = paths.filter { $0 != key }
        }
        setOpenPaths = layouts
        scheduleSave()
    }

    func setFrame(_ path: URL, frame: CGRect) {
        update(path) { $0.frame = CGRectCodable(frame) }
    }

    /// The color now lives in the note's frontmatter.
    func clearLegacyColor(_ path: URL) {
        guard storedState(for: path)?.legacyColor != nil else { return }
        update(path) { $0.legacyColor = nil }
    }

    func setTextSize(_ path: URL, size: Double) {
        update(path) {
            $0.textSize = min(
                NoteWindowState.maxTextSize,
                max(NoteWindowState.minTextSize, size)
            )
        }
    }

    func setColumnCount(_ path: URL, count: Int) {
        update(path) { $0.columnCount = NoteWindowState.clampedColumnCount(count) }
    }

    func setFloatOnTop(_ path: URL, value: Bool) {
        update(path) { $0.floatOnTop = value }
    }

    /// Keys (see `key(for:)`) of the notes open in a set (defaults to the active set).
    func openPaths(inSet set: Int? = nil) -> [String] {
        let target = NoteWindowState.clampedSetIndex(set ?? activeSet)
        return setOpenPaths[target] ?? []
    }

    /// Only matters for path-keyed notes; id-keyed state follows the note by itself.
    func relocate(from oldPath: URL, to newPath: URL) {
        let oldKey = oldPath.path
        let newKey = key(for: newPath)
        guard oldKey != newKey else { return }
        if let existing = states.removeValue(forKey: oldKey) {
            states[newKey] = existing
        } else if states[newKey] == nil {
            states[newKey] = .default()
        }
        var layouts = setOpenPaths
        for (set, paths) in layouts {
            layouts[set] = paths.map { $0 == oldKey ? newKey : $0 }
        }
        setOpenPaths = layouts
        scheduleSave()
    }

    /// Forgets path-keyed state for a vanished file. Id-keyed state is kept: the note may
    /// just have moved, and it finds its state again by id.
    func remove(path: URL) {
        let key = path.path
        states.removeValue(forKey: key)
        var layouts = setOpenPaths
        for (set, paths) in layouts {
            layouts[set] = paths.filter { $0 != key }
        }
        setOpenPaths = layouts
        scheduleSave()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let file = try? JSONDecoder().decode(NoteStateFile.self, from: data) {
            activeSet = NoteWindowState.clampedSetIndex(file.activeSet)
            states = file.notes
            var layouts: [Int: [String]] = [:]
            for (key, paths) in file.setOpenPaths {
                guard let index = Int(key) else { continue }
                layouts[NoteWindowState.clampedSetIndex(index)] = paths
            }
            setOpenPaths = layouts
            return
        }
        if let decoded = try? JSONDecoder().decode([String: NoteWindowState].self, from: data) {
            activeSet = 0
            states = decoded
            var layouts: [Int: [String]] = [:]
            for (path, state) in decoded where state.isOpen {
                layouts[0, default: []].append(path)
            }
            setOpenPaths = layouts
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    func saveNow() {
        do {
            try MarkdownStickiesConfig.ensureDirectory()
            var encodedLayouts: [String: [String]] = [:]
            for (index, paths) in setOpenPaths {
                encodedLayouts[NoteWindowState.setKey(index)] = paths
            }
            let file = NoteStateFile(
                activeSet: activeSet,
                notes: states,
                setOpenPaths: encodedLayouts
            )
            let data = try JSONEncoder().encode(file)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // Best-effort persistence.
        }
    }
}
