import Foundation

/// A file-system path found in terminal output, with the source location written after it, if any.
public struct DetectedPath: Equatable, Sendable {
    public let path: String
    public let line: Int?
    public let column: Int?

    public init(path: String, line: Int?, column: Int?) {
        self.path = path
        self.line = line
        self.column = column
    }
}

/// A detected path with the characters of the line it was read from, including a `:line:col` or `(l,c)` suffix.
public struct PathMatch: Equatable, Sendable {
    public let path: DetectedPath
    /// Character offsets (not terminal columns) of the whole token in the line.
    public let characters: Range<Int>

    public init(path: DetectedPath, characters: Range<Int>) {
        self.path = path
        self.characters = characters
    }
}

/// Finds paths in one line of terminal text. Pure text work: whether the path exists is decided by the caller at click time.
public enum PathDetection {
    private static let opening = Set("\"'`([{<")
    private static let closing: [Character: Character] = [")": "(", "]": "[", "}": "{", ">": "<"]
    private static let quotes = Set("\"'`")
    private static let trailingPunctuation = Set(".,;:")

    /// The path under the character at `offset` (a character index, not a terminal column; see `characterOffset`).
    public static func path(in line: String, at offset: Int) -> DetectedPath? {
        match(in: line, at: offset)?.path
    }

    /// Like `path(in:at:)`, with the character range the highlighted token covers.
    public static func match(in line: String, at offset: Int) -> PathMatch? {
        let characters = Array(line)
        guard characters.indices.contains(offset), !characters[offset].isWhitespace else { return nil }
        var start = offset
        while start > 0, !characters[start - 1].isWhitespace { start -= 1 }
        var end = offset + 1
        while end < characters.count, !characters[end].isWhitespace { end += 1 }
        let token = String(characters[start..<end])
        let rest = String(characters[end...])
        guard let parsed = parse(token: token, rest: rest) else { return nil }
        return PathMatch(path: parsed.path, characters: (start + parsed.range.lowerBound)..<(start + parsed.range.upperBound))
    }

    /// The index of the character displayed at terminal `column`, counting East Asian wide characters as two columns.
    public static func characterOffset(ofColumn column: Int, in line: String) -> Int {
        var used = 0
        for (index, character) in line.enumerated() {
            used += columns(of: character)
            if column < used { return index }
        }
        return line.count + max(0, column - used)
    }

    /// The terminal column where the character at `offset` starts, the inverse of `characterOffset`.
    public static func column(ofCharacterOffset offset: Int, in line: String) -> Int {
        var used = 0
        for (index, character) in line.enumerated() {
            if index == offset { return used }
            used += columns(of: character)
        }
        return used + max(0, offset - line.count)
    }

    /// `src/x` for `a/src/x` or `b/src/x`, as git prints in diffs.
    public static func strippingGitPrefix(_ path: String) -> String? {
        (path.hasPrefix("a/") || path.hasPrefix("b/")) && path.count > 2 ? String(path.dropFirst(2)) : nil
    }

    /// Two columns for East Asian wide and fullwidth characters and emoji, one otherwise.
    private static func columns(of character: Character) -> Int {
        guard let value = character.unicodeScalars.first?.value else { return 1 }
        switch value {
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE6F,
             0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }

    /// The path and the character range of the token (relative to `original`) that includes its location suffix.
    private static func parse(token original: String, rest: String) -> (path: DetectedPath, range: Range<Int>)? {
        var text = Substring(original)
        var line: Int?
        var column: Int?
        while let first = text.first, opening.contains(first) { text = text.dropFirst() }
        let startIndex = text.startIndex
        var locationEnd: String.Index?
        var changed = true
        while changed, let last = text.last {
            changed = false
            if quotes.contains(last) || (trailingPunctuation.contains(last) && !isPartOfDots(text, last)) {
                text = text.dropLast(); changed = true
            } else if let opener = closing[last] {
                if let match = locationInParentheses(text) {
                    locationEnd = text.endIndex
                    text = match.path; line = match.line; column = match.column
                    break
                }
                if !text.dropLast().contains(opener) { text = text.dropLast(); changed = true }
            }
        }
        if line == nil, let match = trailingLocation(text) {
            locationEnd = text.endIndex
            text = match.path; line = match.line; column = match.column
            while let last = text.last, trailingPunctuation.contains(last) || quotes.contains(last) { text = text.dropLast() }
        }
        guard isPathLike(text) else { return nil }
        if line == nil, let end = original.range(of: text)?.upperBound {
            // Python tracebacks: File "/a/b.py", line 12, in f
            let tail = original[end...] + rest
            if let match = tail.firstMatch(of: /^["']?,\s*line\s+(\d+)/), let value = Int(match.1) { line = value }
        }
        let range = original.distance(from: original.startIndex, to: startIndex)
            ..< original.distance(from: original.startIndex, to: locationEnd ?? text.endIndex)
        return (DetectedPath(path: String(text), line: line, column: column), range)
    }

    /// A trailing `.` that continues `..` or `/.` is part of the path, not punctuation.
    private static func isPartOfDots(_ text: Substring, _ last: Character) -> Bool {
        guard last == ".", text.count > 1 else { return false }
        let previous = text[text.index(text.endIndex, offsetBy: -2)]
        return previous == "." || previous == "/"
    }

    private static func locationInParentheses(_ text: Substring) -> (path: Substring, line: Int, column: Int?)? {
        guard let match = text.firstMatch(of: /^(.+?)\((\d+)(?:,\s*(\d+))?\)$/), let line = Int(match.2) else { return nil }
        return (match.1, line, match.3.flatMap { Int($0) })
    }

    private static func trailingLocation(_ text: Substring) -> (path: Substring, line: Int, column: Int?)? {
        guard let match = text.firstMatch(of: /^(.+?):(\d+)(?::(\d+))?$/), let line = Int(match.2) else { return nil }
        return (match.1, line, match.3.flatMap { Int($0) })
    }

    private static func isPathLike(_ text: Substring) -> Bool {
        guard text.count > 1, !text.contains("://"), !text.contains(where: { $0 == "\0" }) else { return false }
        if text.hasPrefix("/") || text.hasPrefix("~/") || text.hasPrefix("./") || text.hasPrefix("../") { return true }
        if text.contains("/") { return text.contains { $0.isLetter || $0.isNumber } }
        // A bare name needs an extension with a letter in it, which rules out versions and decimals.
        guard let dot = text.lastIndex(of: "."), dot != text.startIndex else { return false }
        let ext = text[text.index(after: dot)...]
        return !ext.isEmpty && ext.count <= 10 && ext.allSatisfy { $0.isLetter || $0.isNumber } && ext.contains { $0.isLetter }
    }
}
