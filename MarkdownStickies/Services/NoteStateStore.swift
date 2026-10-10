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

    func state(for path: URL) -> NoteWindowState {
        states[path.path] ?? .default()
    }

    /// Stored window state only if this note already has an entry (e.g. was opened before).
    func storedState(for path: URL) -> NoteWindowState? {
        states[path.path]
    }

    func update(_ path: URL, mutate: (inout NoteWindowState) -> Void) {
        var current = state(for: path)
        mutate(&current)
        states[path.path] = current
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
        var layouts = setOpenPaths
        var paths = Set(layouts[activeSet] ?? [])
        if isOpen {
            paths.insert(path.path)
            if states[path.path] == nil {
                states[path.path] = .default()
            }
        } else {
            paths.remove(path.path)
        }
        layouts[activeSet] = Array(paths).sorted()
        setOpenPaths = layouts
        scheduleSave()
    }

    /// Replace the open-path list for a set (used when parking before a switch).
    func replaceOpenPaths(_ paths: [String], inSet set: Int) {
        let index = NoteWindowState.clampedSetIndex(set)
        var layouts = setOpenPaths
        layouts[index] = Array(Set(paths)).sorted()
        setOpenPaths = layouts
        scheduleSave()
    }

    func touchLastOpened(_ path: URL, at date: Date = Date()) {
        update(path) {
            $0.lastOpenedAt = date
            $0.removedFromRecentsAt = nil
        }
    }

    /// Clear recents ranking + color; keep a burial marker so sort puts the note at the bottom.
    func markRemovedFromRecents(_ path: URL, at date: Date = Date()) {
        update(path) {
            $0.lastOpenedAt = nil
            $0.removedFromRecentsAt = date
            $0.color = .default
            $0.floatOnTop = false
            $0.isOpen = false
        }
        let key = path.path
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

    func setColor(_ path: URL, color: NoteColor) {
        update(path) { $0.color = color }
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

    /// Paths open in a given set (defaults to the active set).
    func openPaths(inSet set: Int? = nil) -> [String] {
        let target = NoteWindowState.clampedSetIndex(set ?? activeSet)
        return setOpenPaths[target] ?? []
    }

    func relocate(from oldPath: URL, to newPath: URL) {
        let oldKey = oldPath.path
        let newKey = newPath.path
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
