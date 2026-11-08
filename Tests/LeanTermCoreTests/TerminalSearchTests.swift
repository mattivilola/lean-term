import Testing
@testable import LeanTermCore

@Test func terminalSearchFindsLiteralAndRegexMatchesWithWideColumns() {
    let rows = ["Foo foo FOO", "日本 foo", "", "a.b a+b"]
    #expect(TerminalSearch.search(rows: rows, query: "foo", matchCase: false, useRegex: false)
        == .matches([.init(row: 0, startColumn: 0, endColumn: 3), .init(row: 0, startColumn: 4, endColumn: 7),
                     .init(row: 0, startColumn: 8, endColumn: 11), .init(row: 1, startColumn: 5, endColumn: 8)], truncated: false))
    #expect(TerminalSearch.search(rows: rows, query: "foo", matchCase: true, useRegex: false)
        == .matches([.init(row: 0, startColumn: 4, endColumn: 7), .init(row: 1, startColumn: 5, endColumn: 8)], truncated: false))
    #expect(TerminalSearch.search(rows: rows, query: "a.b", matchCase: true, useRegex: false)
        == .matches([.init(row: 3, startColumn: 0, endColumn: 3)], truncated: false))
    #expect(TerminalSearch.search(rows: rows, query: "a.b", matchCase: true, useRegex: true)
        == .matches([.init(row: 3, startColumn: 0, endColumn: 3), .init(row: 3, startColumn: 4, endColumn: 7)], truncated: false))
    #expect(TerminalSearch.search(rows: rows, query: "本", matchCase: true, useRegex: false)
        == .matches([.init(row: 1, startColumn: 2, endColumn: 4)], truncated: false))
    #expect(TerminalSearch.search(rows: rows, query: "(", matchCase: false, useRegex: true) == .invalidPattern)
    #expect(TerminalSearch.search(rows: rows, query: "x*", matchCase: false, useRegex: true) == .matches([], truncated: false))
    #expect(TerminalSearch.search(rows: rows, query: "", matchCase: false, useRegex: false) == .matches([], truncated: false))
    // "foo bar baz" soft-wrapped at 4 columns: the trailing spaces of the first two rows are trimmed.
    let wrapped = ["foo", "bar", "baz", "x"]
    #expect(TerminalSearch.search(rows: wrapped, wrapped: [false, true, true, false], columns: 4, query: "o ba", matchCase: true, useRegex: false)
        == .matches([.init(row: 0, startColumn: 2, endRow: 1, endColumn: 2)], truncated: false))
    #expect(TerminalSearch.search(rows: wrapped, wrapped: [false, true, true, false], columns: 4, query: "r b.z", matchCase: true, useRegex: true)
        == .matches([.init(row: 1, startColumn: 2, endRow: 2, endColumn: 3)], truncated: false))
    #expect(TerminalSearch.search(rows: wrapped, columns: 4, query: "r b", matchCase: true, useRegex: false) == .matches([], truncated: false))
    let many = Array(repeating: "ab ab", count: TerminalSearch.matchLimit)
    guard case .matches(let capped, let truncated) = TerminalSearch.search(rows: many, query: "ab", matchCase: true, useRegex: false) else {
        Issue.record("Expected matches"); return
    }
    #expect(capped.count == TerminalSearch.matchLimit && truncated)
}
