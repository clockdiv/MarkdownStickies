import Foundation

@MainActor
final class NoteStateStore: ObservableObject {
    @Published private(set) var states: [String: NoteWindowState] = [:]

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MarkdownStickies", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("note-state.json")
        migrateFromSandboxContainerIfNeeded()
        load()
    }

    /// After leaving the App Sandbox, settings lived under Containers/…
    private func migrateFromSandboxContainerIfNeeded() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: fileURL.path) else { return }
        let legacy = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.markdownstickies.app/Data/Library/Application Support/MarkdownStickies/note-state.json")
        guard fm.fileExists(atPath: legacy.path) else { return }
        try? fm.copyItem(at: legacy, to: fileURL)
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

    func setOpen(_ path: URL, isOpen: Bool) {
        update(path) { $0.isOpen = isOpen }
    }

    func touchLastOpened(_ path: URL, at date: Date = Date()) {
        update(path) { $0.lastOpenedAt = date }
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

    func openPaths() -> [String] {
        states.compactMap { key, value in value.isOpen ? key : nil }
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
        scheduleSave()
    }

    func remove(path: URL) {
        states.removeValue(forKey: path.path)
        scheduleSave()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? JSONDecoder().decode([String: NoteWindowState].self, from: data) {
            states = decoded
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
            let data = try JSONEncoder().encode(states)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // Best-effort persistence.
        }
    }
}
