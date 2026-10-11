import Foundation

/// Line-based diff (LCS) for the merge view.
public enum TextDiff {
    public enum Line: Equatable, Sendable {
        case same(String)
        case removed(String)
        case added(String)
    }

    public static func unified(local: String, remote: String) -> [Line] {
        let left = local.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let right = remote.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let table = lcsTable(left, right)
        var i = left.count
        var j = right.count
        var reversed: [Line] = []
        while i > 0 || j > 0 {
            if i > 0, j > 0, left[i - 1] == right[j - 1] {
                reversed.append(.same(left[i - 1]))
                i -= 1
                j -= 1
            } else if j > 0, (i == 0 || table[i][j - 1] >= table[i - 1][j]) {
                reversed.append(.added(right[j - 1]))
                j -= 1
            } else if i > 0 {
                reversed.append(.removed(left[i - 1]))
                i -= 1
            }
        }
        return reversed.reversed()
    }

    private static func lcsTable(_ a: [String], _ b: [String]) -> [[Int]] {
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 1...a.count {
            for j in 1...b.count {
                if a[i - 1] == b[j - 1] {
                    table[i][j] = table[i - 1][j - 1] + 1
                } else {
                    table[i][j] = max(table[i - 1][j], table[i][j - 1])
                }
            }
        }
        return table
    }
}
