import Foundation

/// One match in the buffer, in terminal columns. A match inside a soft-wrapped line may continue on further rows:
/// it runs from `startColumn` on `row` to `endColumn` (exclusive) on `endRow`.
public struct TerminalSearchMatch: Equatable, Sendable {
    public let row: Int
    public let startColumn: Int
    public let endRow: Int
    public let endColumn: Int

    public init(row: Int, startColumn: Int, endRow: Int? = nil, endColumn: Int) {
        self.row = row
        self.startColumn = startColumn
        self.endRow = endRow ?? row
        self.endColumn = endColumn
    }

    /// The same match with rows shifted, to move between snapshot and buffer row numbers.
    public func shifted(byRows delta: Int) -> TerminalSearchMatch {
        TerminalSearchMatch(row: row + delta, startColumn: startColumn, endRow: endRow + delta, endColumn: endColumn)
    }
}

public enum TerminalSearchOutcome: Equatable, Sendable {
    /// Matches in buffer order. `truncated` when more than `TerminalSearch.matchLimit` exist.
    case matches([TerminalSearchMatch], truncated: Bool)
    /// The regular expression does not compile.
    case invalidPattern
}

/// Find in the terminal buffer: a literal or regular-expression search over the text of the buffer rows.
/// Pure text work, so it can run on any thread over a snapshot of the rows.
public enum TerminalSearch {
    public static let matchLimit = 10_000

    /// Searches `rows` (the text of each buffer row). `wrapped[i]` says row `i` continues row `i - 1` (a soft
    /// wrap), so a wrapped line is searched as one string; rows that continue a following row are padded with
    /// spaces to `columns` first, as the terminal leaves them blank. Empty queries and zero-length
    /// regular-expression matches yield nothing.
    public static func search(rows: [String], wrapped: [Bool] = [], columns: Int = 0, query: String,
                              matchCase: Bool, useRegex: Bool) -> TerminalSearchOutcome {
        guard !query.isEmpty else { return .matches([], truncated: false) }
        var regex: NSRegularExpression?
        if useRegex {
            guard let compiled = try? NSRegularExpression(pattern: query, options: matchCase ? [] : [.caseInsensitive]) else {
                return .invalidPattern
            }
            regex = compiled
        }
        let literalOptions: NSString.CompareOptions = matchCase ? [.literal] : [.literal, .caseInsensitive]
        func ranges(in text: String) -> [NSRange] {
            let ns = text as NSString
            var found: [NSRange] = []
            if let regex {
                regex.enumerateMatches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) { result, _, _ in
                    if let range = result?.range, range.length > 0 { found.append(range) }
                }
            } else {
                var from = 0
                while from < ns.length {
                    let range = ns.range(of: query, options: literalOptions, range: NSRange(location: from, length: ns.length - from))
                    guard range.location != NSNotFound, range.length > 0 else { break }
                    found.append(range)
                    from = range.location + range.length
                }
            }
            return found
        }

        var matches: [TerminalSearchMatch] = []
        var index = 0
        while index < rows.count {
            var last = index
            while last + 1 < rows.count, last + 1 < wrapped.count, wrapped[last + 1] { last += 1 }
            defer { index = last + 1 }
            if last == index {
                let text = rows[index]
                guard !text.isEmpty else { continue }
                let ascii = text.utf8.count == text.utf16.count
                for range in ranges(in: text) {
                    let start = ascii ? range.location : column(ofUTF16Offset: range.location, in: text)
                    let end = ascii ? range.location + range.length : column(ofUTF16Offset: range.location + range.length, in: text)
                    guard end > start else { continue }
                    if matches.count == matchLimit { return .matches(matches, truncated: true) }
                    matches.append(TerminalSearchMatch(row: index, startColumn: start, endColumn: end))
                }
                continue
            }
            // A soft-wrapped line: search the joined text, then map each match back onto its rows.
            var parts: [String] = []
            var starts: [Int] = []
            var length = 0
            for row in index...last {
                var part = rows[row]
                if row < last, columns > 0 {
                    let used = PathDetection.column(ofCharacterOffset: part.count, in: part)
                    if used < columns { part += String(repeating: " ", count: columns - used) }
                }
                starts.append(length)
                length += part.utf16.count
                parts.append(part)
            }
            for range in ranges(in: parts.joined()) {
                let first = rowIndex(containing: range.location, in: starts)
                let final = rowIndex(containing: range.location + range.length - 1, in: starts)
                let start = column(ofUTF16Offset: range.location - starts[first], in: parts[first])
                let end = column(ofUTF16Offset: range.location + range.length - starts[final], in: parts[final])
                if matches.count == matchLimit { return .matches(matches, truncated: true) }
                matches.append(TerminalSearchMatch(row: index + first, startColumn: start, endRow: index + final, endColumn: end))
            }
        }
        return .matches(matches, truncated: false)
    }

    /// The part holding the UTF-16 `offset`: the last start at or before it.
    private static func rowIndex(containing offset: Int, in starts: [Int]) -> Int {
        var low = 0, high = starts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= offset { low = middle } else { high = middle - 1 }
        }
        return low
    }

    private static func column(ofUTF16Offset offset: Int, in row: String) -> Int {
        let index = row.utf16.index(row.utf16.startIndex, offsetBy: min(offset, row.utf16.count))
        return PathDetection.column(ofCharacterOffset: row.distance(from: row.startIndex, to: index), in: row)
    }
}
