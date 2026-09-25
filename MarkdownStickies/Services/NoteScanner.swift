import Foundation

enum NoteScanner {
    static func scan(roots: [URL]) -> [Note] {
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
                    if name == "node_modules" || name == ".git" || name == "DerivedData" || name == "build" {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                guard values?.isRegularFile == true else { continue }
                guard NoteFilename.matches(url.lastPathComponent) else { continue }

                let modified = values?.contentModificationDate ?? Date.distantPast
                if let note = NoteFilename.parse(url: url.standardizedFileURL, modifiedAt: modified) {
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
