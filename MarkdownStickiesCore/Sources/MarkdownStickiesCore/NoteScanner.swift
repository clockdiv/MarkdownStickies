import Foundation

public enum NoteScanner {
    /// Directory names always skipped while walking (in addition to `scan.conf`).
    public static let builtinSkippedDirectories: Set<String> = [
        "node_modules",
        ".git",
        "DerivedData",
        "build",
        ".build",
        "Pods",
        "Carthage",
        "vendor",
        "target",
        "dist",
        ".swiftpm",
        "xcuserdata",
        ".hg",
        ".svn",
    ]

    public static func scan(roots: [URL], config: ScanConfig = .empty) -> [Note] {
        var notes: [Note] = []
        let fm = FileManager.default

        for root in roots {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }

            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey])
                if values?.isDirectory == true {
                    let name = url.lastPathComponent
                    if builtinSkippedDirectories.contains(name) {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                guard values?.isRegularFile == true else { continue }
                guard NoteFilename.matches(url.lastPathComponent) else { continue }

                let file = url.standardizedFileURL
                guard config.allows(fileURL: file) else { continue }

                let modified = values?.contentModificationDate ?? Date.distantPast
                if let note = NoteFilename.parse(url: file, modifiedAt: modified) {
                    notes.append(note)
                }
            }
        }

        // Overlapping roots (e.g. Desktop + Desktop/notes) can yield the same file twice.
        var unique: [String: Note] = [:]
        for note in notes {
            let key = note.path.standardizedFileURL.path
            if let existing = unique[key] {
                if note.modifiedAt > existing.modifiedAt {
                    unique[key] = note
                }
            } else {
                unique[key] = note
            }
        }

        return unique.values.sorted { lhs, rhs in
            if lhs.modifiedAt != rhs.modifiedAt {
                return lhs.modifiedAt > rhs.modifiedAt
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }
}
