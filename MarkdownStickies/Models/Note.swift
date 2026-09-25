import Foundation

struct Note: Identifiable, Hashable, Sendable {
    var id: String { path.path }
    let path: URL
    let date: Date
    let title: String
    var modifiedAt: Date

    var parentDirectory: URL {
        path.deletingLastPathComponent()
    }

    /// e.g. `Desktop` or `Desktop / projects / notes` — scan root name + relative subfolders.
    static func locationLabel(for notePath: URL, scanRoots: [URL]) -> String {
        let noteDir = notePath.deletingLastPathComponent().standardizedFileURL
        let noteDirPath = noteDir.path

        let match = scanRoots
            .map(\.standardizedFileURL)
            .filter { root in
                let rootPath = root.path
                return noteDirPath == rootPath
                    || noteDirPath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
            }
            .max(by: { $0.path.count < $1.path.count })

        guard let root = match else {
            return noteDir.lastPathComponent
        }

        let rootName = root.lastPathComponent
        guard noteDirPath != root.path else { return rootName }

        let relative = String(noteDirPath.dropFirst(root.path.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !relative.isEmpty else { return rootName }

        let subfolders = relative.split(separator: "/").map(String.init)
        return ([rootName] + subfolders).joined(separator: "/")
    }

    /// Root scan-folder name and optional `sub/folders` path (no leading slash).
    static func locationParts(for notePath: URL, scanRoots: [URL]) -> (root: String, subpath: String?) {
        let label = locationLabel(for: notePath, scanRoots: scanRoots)
        if let slash = label.firstIndex(of: "/") {
            let root = String(label[..<slash])
            let sub = String(label[label.index(after: slash)...])
            return (root, sub.isEmpty ? nil : sub)
        }
        return (label, nil)
    }
}

enum NoteFilename {
    /// Optional dated prefix: `yyyy-MM-dd-title.md`
    private static let datedPattern = #"^(\d{4}-\d{2}-\d{2})-(.+)$"#
    private static let datedRegex = try! NSRegularExpression(pattern: datedPattern)

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func matches(_ filename: String) -> Bool {
        filename.lowercased().hasSuffix(".md")
    }

    static func parse(url: URL, modifiedAt: Date) -> Note? {
        let filename = url.lastPathComponent
        guard matches(filename) else { return nil }

        let stem = url.deletingPathExtension().lastPathComponent
        guard !stem.isEmpty else { return nil }

        let range = NSRange(stem.startIndex..., in: stem)
        if let match = datedRegex.firstMatch(in: stem, range: range),
           match.numberOfRanges == 3,
           let dateRange = Range(match.range(at: 1), in: stem),
           let titleRange = Range(match.range(at: 2), in: stem),
           let date = dateFormatter.date(from: String(stem[dateRange])) {
            let slug = String(stem[titleRange])
            return Note(
                path: url,
                date: date,
                title: displayTitle(from: slug),
                modifiedAt: modifiedAt
            )
        }

        return Note(
            path: url,
            date: modifiedAt,
            title: displayTitle(from: stem),
            modifiedAt: modifiedAt
        )
    }

    static func datePrefix(from url: URL) -> String? {
        let stem = url.deletingPathExtension().lastPathComponent
        let range = NSRange(stem.startIndex..., in: stem)
        guard let match = datedRegex.firstMatch(in: stem, range: range),
              match.numberOfRanges >= 2,
              let dateRange = Range(match.range(at: 1), in: stem)
        else { return nil }
        let datePart = String(stem[dateRange])
        guard dateFormatter.date(from: datePart) != nil else { return nil }
        return datePart
    }

    /// New file URL for a rename, preserving any `yyyy-MM-dd-` prefix and avoiding collisions.
    static func uniqueRenamedURL(from current: URL, newTitle: String) -> URL {
        let directory = current.deletingLastPathComponent()
        let slug = slugify(newTitle)
        let currentStandard = current.standardizedFileURL

        func candidate(slugVariant: String) -> URL {
            if let datePart = datePrefix(from: current) {
                return directory.appendingPathComponent("\(datePart)-\(slugVariant).md")
            }
            return directory.appendingPathComponent("\(slugVariant).md")
        }

        var url = candidate(slugVariant: slug)
        if url.standardizedFileURL == currentStandard {
            return current
        }
        var index = 2
        while FileManager.default.fileExists(atPath: url.path),
              url.standardizedFileURL != currentStandard {
            url = candidate(slugVariant: "\(slug)-\(index)")
            index += 1
        }
        return url
    }

    static func displayTitle(from slug: String) -> String {
        slug
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { part -> String in
                guard let first = part.first else { return String(part) }
                return String(first).uppercased() + part.dropFirst()
            }
            .joined(separator: " ")
    }

    static func slugify(_ title: String) -> String {
        let lowered = title.lowercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let filtered = lowered.unicodeScalars.map { allowed.contains($0) ? Character($0) : Character("-") }
        let collapsed = String(filtered)
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return collapsed.isEmpty ? "note" : collapsed
    }

    static func makeFilename(date: Date, title: String) -> String {
        let datePart = dateFormatter.string(from: date)
        let slug = slugify(title)
        return "\(datePart)-\(slug).md"
    }

    static func uniqueURL(in directory: URL, date: Date, title: String) -> URL {
        let baseSlug = slugify(title)
        let datePart = dateFormatter.string(from: date)
        var candidate = directory.appendingPathComponent("\(datePart)-\(baseSlug).md")
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(datePart)-\(baseSlug)-\(index).md")
            index += 1
        }
        return candidate
    }
}
