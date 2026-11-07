import Foundation

/// Fuzzy matching for the command palette: a case-insensitive subsequence match
/// where word starts and consecutive characters score higher.
public enum CommandMatcher {
    /// Higher is better; nil when `query` is not a subsequence of `candidate`. Whitespace in the query is ignored,
    /// and an empty query matches everything with score 0.
    public static func score(query: String, candidate: String) -> Int? {
        let needle = query.lowercased().filter { !$0.isWhitespace }.map { $0 }
        if needle.isEmpty { return 0 }
        let original = Array(candidate)
        let hay = original.map { $0.lowercased().first ?? $0 }
        guard needle.count <= hay.count else { return nil }
        func wordStart(_ index: Int) -> Bool { index == 0 || !(original[index - 1].isLetter || original[index - 1].isNumber) }
        // best[j]: best score with the current query character matched at candidate index j.
        var best = [Int?](repeating: nil, count: hay.count)
        for (offset, character) in needle.enumerated() {
            var next = [Int?](repeating: nil, count: hay.count)
            for j in hay.indices where hay[j] == character {
                var value = 1 + (wordStart(j) ? 8 : 0)
                if offset == 0 {
                    value += j == 0 ? 6 : 0
                } else {
                    var bestPrevious: Int?
                    for k in 0..<j {
                        guard let previous = best[k] else { continue }
                        let candidateScore = previous + (k == j - 1 ? 6 : -min(j - k - 1, 3))
                        if bestPrevious == nil || candidateScore > bestPrevious! { bestPrevious = candidateScore }
                    }
                    guard let bestPrevious else { continue }
                    value += bestPrevious
                }
                next[j] = value
            }
            best = next
        }
        return best.compactMap { $0 }.max()
    }
}
