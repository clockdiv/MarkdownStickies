import Foundation

/// Two-way line merge for divergent note bodies (no common ancestor).
///
/// Strategy (git-like hunk handling on an LCS diff):
/// - Shared lines appear once
/// - Local-only or remote-only hunks are taken automatically (both appends, one-sided edits)
/// - Hunks that replace lines on both sides become conflict markers
public enum TextMerge {
    public struct Result: Equatable, Sendable {
        /// Merged markdown body (no frontmatter).
        public var body: String
        /// True when `<<<<<<<` markers remain for the user to resolve.
        public var hasConflicts: Bool
        /// True when every hunk auto-merged (no markers).
        public var isClean: Bool { !hasConflicts }

        public init(body: String, hasConflicts: Bool) {
            self.body = body
            self.hasConflicts = hasConflicts
        }
    }

    /// Merge two note bodies (markdown after frontmatter). Labels appear in conflict markers.
    public static func twoWay(
        local: String,
        remote: String,
        localLabel: String = "This Mac",
        remoteLabel: String = "peer"
    ) -> Result {
        let left = normalizeLines(local)
        let right = normalizeLines(remote)
        if left == right {
            return Result(body: joinLines(left), hasConflicts: false)
        }

        let diff = TextDiff.unified(local: joinLines(left), remote: joinLines(right))
        let hunks = groupHunks(diff)
        let localName = displayLabel(localLabel, fallback: "This Mac")
        let remoteName = displayLabel(remoteLabel, fallback: "peer")

        var out: [String] = []
        var hasConflicts = false

        for hunk in hunks {
            switch hunk {
            case .same(let lines):
                out.append(contentsOf: lines)
            case .localOnly(let lines):
                out.append(contentsOf: lines)
            case .remoteOnly(let lines):
                out.append(contentsOf: lines)
            case .both(let localLines, let remoteLines):
                if localLines == remoteLines {
                    out.append(contentsOf: localLines)
                } else if shouldConflict(localLines: localLines, remoteLines: remoteLines) {
                    // Likely the same line(s) rewritten — ask the user.
                    hasConflicts = true
                    out.append("<<<<<<< \(localName)")
                    out.append(contentsOf: localLines)
                    out.append("=======")
                    out.append(contentsOf: remoteLines)
                    out.append(">>>>>>> \(remoteName)")
                } else {
                    // Disjoint inserts (typical both-append) — keep both, local then remote.
                    out.append(contentsOf: localLines)
                    out.append(contentsOf: remoteLines)
                }
            }
        }

        return Result(body: joinLines(out), hasConflicts: hasConflicts)
    }

    /// Merge full note documents: keep `id` (and prefer local `created_on`), merge body lines.
    public static func mergeDocuments(
        localMarkdown: String,
        remoteMarkdown: String,
        keepingID: UUID,
        localLabel: String = "This Mac",
        remoteLabel: String = "peer"
    ) -> Result {
        let localParts = NoteFrontmatter.splitDocument(localMarkdown)
        let remoteParts = NoteFrontmatter.splitDocument(remoteMarkdown)
        let merged = twoWay(
            local: localParts.body,
            remote: remoteParts.body,
            localLabel: localLabel,
            remoteLabel: remoteLabel
        )

        // Start from local frontmatter so created_on / folder stay stable, then force id.
        var doc = NoteFrontmatter.joinDocument(prefix: localParts.prefix, body: merged.body)
        if doc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            doc = NoteFrontmatter.joinDocument(prefix: remoteParts.prefix, body: merged.body)
        }
        doc = NoteFrontmatter.settingSyncID(keepingID, in: doc)
        doc = NoteFrontmatter.clearingConflictResolved(doc)
        return Result(body: doc, hasConflicts: merged.hasConflicts)
    }

    // MARK: - Hunks

    private enum Hunk: Equatable {
        case same([String])
        case localOnly([String])
        case remoteOnly([String])
        case both(local: [String], remote: [String])
    }

    private static func groupHunks(_ diff: [TextDiff.Line]) -> [Hunk] {
        var result: [Hunk] = []
        var sameBuf: [String] = []
        var localBuf: [String] = []
        var remoteBuf: [String] = []

        func flushSame() {
            guard !sameBuf.isEmpty else { return }
            result.append(.same(sameBuf))
            sameBuf = []
        }

        func flushChange() {
            defer {
                localBuf = []
                remoteBuf = []
            }
            if localBuf.isEmpty, remoteBuf.isEmpty { return }
            flushSame()
            if localBuf.isEmpty {
                result.append(.remoteOnly(remoteBuf))
            } else if remoteBuf.isEmpty {
                result.append(.localOnly(localBuf))
            } else {
                result.append(.both(local: localBuf, remote: remoteBuf))
            }
        }

        for line in diff {
            switch line {
            case .same(let s):
                flushChange()
                sameBuf.append(s)
            case .removed(let s):
                localBuf.append(s)
            case .added(let s):
                remoteBuf.append(s)
            }
        }
        flushChange()
        flushSame()
        return result
    }

    /// True when each side rewrote overlapping content (similar lines), not two independent inserts.
    private static func shouldConflict(localLines: [String], remoteLines: [String]) -> Bool {
        // Pairwise: if every local line is "close" to some remote line (or counts match and
        // aligned pairs are similar), treat as a rewrite conflict.
        if localLines.count == remoteLines.count {
            let pairs = zip(localLines, remoteLines)
            let similarPairs = pairs.filter { similar($0, $1) }.count
            if similarPairs == localLines.count { return true }
            if similarPairs > 0, similarPairs * 2 >= localLines.count { return true }
        }
        // One-vs-many still counts if the single line is similar to any opposite line.
        if localLines.count == 1, remoteLines.contains(where: { similar(localLines[0], $0) }) {
            return true
        }
        if remoteLines.count == 1, localLines.contains(where: { similar(remoteLines[0], $0) }) {
            return true
        }
        return false
    }

    /// Normalized Levenshtein similarity in (0, 1]. Near-identical rewrites → conflict.
    private static func similar(_ a: String, _ b: String) -> Bool {
        let left = a.trimmingCharacters(in: .whitespaces)
        let right = b.trimmingCharacters(in: .whitespaces)
        if left.isEmpty, right.isEmpty { return true }
        if left.isEmpty || right.isEmpty { return false }
        if left == right { return true }
        let distance = levenshtein(left, right)
        let denom = max(left.count, right.count)
        let ratio = 1.0 - (Double(distance) / Double(denom))
        // Same bullet structure with a short word swap ("Mac item" vs "iOS item") is ~0.5–0.7 —
        // treat mid similarity as independent inserts (union). High similarity = rewrite.
        return ratio >= 0.72
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }
        var prev = Array(0...bChars.count)
        var cur = Array(repeating: 0, count: bChars.count + 1)
        for i in 1...aChars.count {
            cur[0] = i
            for j in 1...bChars.count {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                cur[j] = min(
                    prev[j] + 1,
                    cur[j - 1] + 1,
                    prev[j - 1] + cost
                )
            }
            prev = cur
        }
        return prev[bChars.count]
    }

    private static func normalizeLines(_ text: String) -> [String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while lines.last == "" { lines.removeLast() }
        return lines
    }

    private static func joinLines(_ lines: [String]) -> String {
        guard !lines.isEmpty else { return "" }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func displayLabel(_ raw: String, fallback: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
