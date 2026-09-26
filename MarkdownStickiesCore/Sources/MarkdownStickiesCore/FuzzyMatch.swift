import Foundation

/// Lightweight fuzzy matcher for note titles / paths.
/// Query characters must appear in order; contiguous and word-boundary hits score higher.
public enum FuzzyMatch {
    /// Default when callers don’t pass an override (Settings slider owns the live value).
    public static let defaultMinimumScore = 300

    public struct Breakdown: Equatable {
        public let total: Int
        public let field: String
        public let weight: Int
        public let raw: Int
        public let lines: [String]
        public let minimumScore: Int

        public init(total: Int, field: String, weight: Int, raw: Int, lines: [String], minimumScore: Int) {
            self.total = total
            self.field = field
            self.weight = weight
            self.raw = raw
            self.lines = lines
            self.minimumScore = minimumScore
        }

        /// Multi-line debug blurb for hover.
        public var detailText: String {
            ([
                "total \(total) = raw \(raw) × \(field) weight \(weight)",
                "minimumScore \(minimumScore)",
            ] + lines).joined(separator: "\n")
        }
    }

    /// Higher is better. `nil` = no match.
    public static func score(query: String, in text: String) -> Int? {
        explain(query: query, in: text)?.score
    }

    /// Best weighted score across haystacks, with a calculation breakdown for debug UI.
    public static func bestBreakdown(
        query: String,
        in candidates: [(name: String, text: String, weight: Int)],
        minimumScore: Int = defaultMinimumScore
    ) -> Breakdown? {
        var best: Breakdown?
        for candidate in candidates {
            guard let explained = explain(query: query, in: candidate.text) else { continue }
            let weighted = explained.score * candidate.weight
            let breakdown = Breakdown(
                total: weighted,
                field: candidate.name,
                weight: candidate.weight,
                raw: explained.score,
                lines: explained.lines,
                minimumScore: minimumScore
            )
            if best == nil || breakdown.total > best!.total {
                best = breakdown
            }
        }
        guard let best, best.total >= minimumScore else { return nil }
        return best
    }

    /// Best score across several haystacks. `nil` when nothing clears `minimumScore`.
    public static func bestScore(
        query: String,
        in candidates: [(text: String, weight: Int)],
        minimumScore: Int = defaultMinimumScore
    ) -> Int? {
        bestBreakdown(
            query: query,
            in: candidates.map { ("?", $0.text, $0.weight) },
            minimumScore: minimumScore
        )?.total
    }

    // MARK: - Private

    private struct ExplainedScore {
        let score: Int
        let lines: [String]
    }

    private static func fold(_ string: String) -> String {
        string
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
    }

    private static func explain(query: String, in text: String) -> ExplainedScore? {
        let foldedQuery = fold(query)
        let foldedText = fold(text)
        guard !foldedQuery.isEmpty else {
            return ExplainedScore(score: 0, lines: ["empty query → 0"])
        }
        guard !foldedText.isEmpty else { return nil }

        let tokens = foldedQuery.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else {
            return ExplainedScore(score: 0, lines: ["empty tokens → 0"])
        }

        var total = 0
        var lines: [String] = []
        for token in tokens {
            guard let part = scoreToken(token, in: foldedText) else { return nil }
            total += part.score
            lines.append(contentsOf: part.lines.map { "token \"\(token)\": \($0)" })
        }
        if tokens.count > 1 {
            lines.append("sum tokens → raw \(total)")
        }
        return ExplainedScore(score: total, lines: lines)
    }

    private static func scoreToken(_ token: String, in text: String) -> ExplainedScore? {
        if token.count <= 2 {
            return scoreShortToken(token, in: text)
        }

        if let range = text.range(of: token) {
            var score = 120 + token.count * 8
            var lines = [
                "substring hit",
                "base 120 + len×8 (\(token.count)×8) → \(120 + token.count * 8)",
            ]
            if range.lowerBound == text.startIndex {
                score += 40
                lines.append("start-of-string +40")
            } else {
                let before = text[text.index(before: range.lowerBound)]
                if isBoundary(before) {
                    score += 25
                    lines.append("word-boundary +25")
                }
            }
            let penalty = max(0, text.count - token.count) / 6
            score -= penalty
            if penalty > 0 {
                lines.append("length penalty −\(penalty)")
            }
            lines.append("raw \(score)")
            return ExplainedScore(score: score, lines: lines)
        }

        let queryChars = Array(token)
        let textChars = Array(text)
        var score = 0
        var consecutive = 0
        var textIndex = 0
        var boundaryBonus = 0
        var startBonus = 0
        var charPoints = 0

        for queryChar in queryChars {
            var matched = false
            while textIndex < textChars.count {
                let atStart = textIndex == 0
                let previous = textIndex > 0 ? textChars[textIndex - 1] : nil
                let textChar = textChars[textIndex]
                textIndex += 1

                guard textChar == queryChar else {
                    consecutive = 0
                    continue
                }

                consecutive += 1
                let step = 10 + consecutive * 6
                charPoints += step
                score += step
                if atStart {
                    score += 18
                    startBonus += 18
                } else if let previous, isBoundary(previous) {
                    score += 12
                    boundaryBonus += 12
                }
                matched = true
                break
            }
            if !matched { return nil }
        }

        let penalty = textChars.count / 5
        score -= penalty
        let finalScore = max(score, 1)
        var lines = [
            "fuzzy subsequence",
            "char/consecutive → \(charPoints)",
        ]
        if startBonus > 0 { lines.append("start bonuses +\(startBonus)") }
        if boundaryBonus > 0 { lines.append("boundary bonuses +\(boundaryBonus)") }
        if penalty > 0 { lines.append("length penalty −\(penalty)") }
        lines.append("raw \(finalScore)")
        return ExplainedScore(score: finalScore, lines: lines)
    }

    private static func scoreShortToken(_ token: String, in text: String) -> ExplainedScore? {
        let chars = Array(text)
        let needle = Array(token)
        var best: ExplainedScore?

        var i = 0
        while i <= chars.count - needle.count {
            let slice = Array(chars[i..<(i + needle.count)])
            if slice == needle {
                let atStart = i == 0
                let beforeOK = atStart || isBoundary(chars[i - 1])
                let afterIndex = i + needle.count
                let afterOK = afterIndex >= chars.count || isBoundary(chars[afterIndex])
                if beforeOK {
                    var score = afterOK ? 200 : 110
                    var lines = [
                        "short token (≤2), boundary-anchored",
                        afterOK ? "standalone base 200" : "prefix-at-boundary base 110",
                    ]
                    if atStart {
                        score += 40
                        lines.append("start-of-string +40")
                    }
                    let lenBonus = token.count * 10
                    score += lenBonus
                    lines.append("len×10 +\(lenBonus)")
                    let penalty = text.count / 8
                    score -= penalty
                    if penalty > 0 {
                        lines.append("length penalty −\(penalty)")
                    }
                    lines.append("raw \(score)")
                    let explained = ExplainedScore(score: score, lines: lines)
                    if best == nil || explained.score > best!.score {
                        best = explained
                    }
                }
            }
            i += 1
        }
        return best
    }

    private static func isBoundary(_ character: Character) -> Bool {
        character.isWhitespace || character.isPunctuation || "-_/.".contains(character)
    }
}
