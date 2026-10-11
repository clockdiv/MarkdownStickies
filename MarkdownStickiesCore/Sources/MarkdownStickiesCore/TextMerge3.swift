import Foundation

/// Three-way line merge (diff3), as in git: both versions are compared to their common base.
/// A change made on only one side is taken over; changes on both sides to the same lines are
/// a conflict for the user. Without a base, every difference is a conflict (two-way).
public enum TextMerge3 {
    public enum Hunk: Equatable, Sendable {
        /// Same on both sides and in the base.
        case unchanged([String])
        /// Changed only in `mine`: `base` lines were replaced by `mine` lines.
        case onlyMine(base: [String], mine: [String])
        /// Changed only in `theirs`.
        case onlyTheirs(base: [String], theirs: [String])
        /// Both sides made the same change.
        case both(base: [String], lines: [String])
        /// Both sides changed these lines differently.
        case conflict(base: [String], mine: [String], theirs: [String])
    }

    public static func merge(base: String?, mine: String, theirs: String) -> [Hunk] {
        let mineLines = lines(mine)
        let theirsLines = lines(theirs)
        guard let base else { return twoWay(mineLines, theirsLines) }
        let baseLines = lines(base)

        let toMine = matches(baseLines, mineLines)
        let toTheirs = matches(baseLines, theirsLines)

        var hunks: [Hunk] = []
        var b = 0, m = 0, t = 0
        func emitChunk(_ b1: Int, _ m1: Int, _ t1: Int) {
            let baseChunk = Array(baseLines[b..<b1])
            let mineChunk = Array(mineLines[m..<m1])
            let theirsChunk = Array(theirsLines[t..<t1])
            guard !(baseChunk.isEmpty && mineChunk.isEmpty && theirsChunk.isEmpty) else { return }
            if mineChunk == baseChunk, theirsChunk == baseChunk {
                append(.unchanged(baseChunk), to: &hunks)
            } else if mineChunk == baseChunk {
                hunks.append(.onlyTheirs(base: baseChunk, theirs: theirsChunk))
            } else if theirsChunk == baseChunk {
                hunks.append(.onlyMine(base: baseChunk, mine: mineChunk))
            } else if mineChunk == theirsChunk {
                hunks.append(.both(base: baseChunk, lines: mineChunk))
            } else {
                hunks.append(.conflict(base: baseChunk, mine: mineChunk, theirs: theirsChunk))
            }
        }

        // Sync points: base lines both sides kept unchanged.
        for i in baseLines.indices {
            guard let mi = toMine[i], let ti = toTheirs[i], mi >= m, ti >= t else { continue }
            emitChunk(i, mi, ti)
            append(.unchanged([baseLines[i]]), to: &hunks)
            b = i + 1
            m = mi + 1
            t = ti + 1
        }
        emitChunk(baseLines.count, mineLines.count, theirsLines.count)
        return hunks
    }

    /// The text when every non-conflicting change is taken and conflicts keep both sides
    /// (mine first). A starting point for the user, not a silent result.
    public static func automaticResult(_ hunks: [Hunk]) -> String {
        var out: [String] = []
        for hunk in hunks {
            switch hunk {
            case .unchanged(let lines), .both(_, let lines): out += lines
            case .onlyMine(_, let mine): out += mine
            case .onlyTheirs(_, let theirs): out += theirs
            case .conflict(_, let mine, let theirs): out += mine + theirs
            }
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Private

    static func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private static func append(_ hunk: Hunk, to hunks: inout [Hunk]) {
        if case .unchanged(let more) = hunk, case .unchanged(let previous)? = hunks.last {
            hunks[hunks.count - 1] = .unchanged(previous + more)
        } else {
            hunks.append(hunk)
        }
    }

    private static func twoWay(_ mine: [String], _ theirs: [String]) -> [Hunk] {
        let toTheirs = matches(mine, theirs)
        var hunks: [Hunk] = []
        var m = 0, t = 0
        for i in mine.indices {
            guard let ti = toTheirs[i], ti >= t else { continue }
            let mineChunk = Array(mine[m..<i])
            let theirsChunk = Array(theirs[t..<ti])
            if !mineChunk.isEmpty || !theirsChunk.isEmpty {
                hunks.append(.conflict(base: [], mine: mineChunk, theirs: theirsChunk))
            }
            append(.unchanged([mine[i]]), to: &hunks)
            m = i + 1
            t = ti + 1
        }
        let mineTail = Array(mine[m...])
        let theirsTail = Array(theirs[t...])
        if !mineTail.isEmpty || !theirsTail.isEmpty {
            hunks.append(.conflict(base: [], mine: mineTail, theirs: theirsTail))
        }
        return hunks
    }

    /// Longest common subsequence: index in `a` → matching index in `b`.
    private static func matches(_ a: [String], _ b: [String]) -> [Int: Int] {
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var result: [Int: Int] = [:]
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                result[i] = j
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return result
    }
}
