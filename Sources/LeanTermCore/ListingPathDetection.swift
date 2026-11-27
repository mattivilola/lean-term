import Foundation

/// Resolves the text of a listing entry against the operand of the command that printed it.
@MainActor
public enum ListingPathDetection {
    private static let date = /(?:(?:\p{L}{2,}\.?\s+\d{1,2}|\d{1,2}\.?\s+\p{L}{2,}\.?)\s+(?:\d{1,2}:\d{2}|\d{4})|\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2})/
    private static let bsdMetadata = /^(?<type>[-dlcbpswD])[rwxstST-]{9}[+@.]?\s+\d+\s+\S+\s+\S+\s+(?:\d+,\s*\d+|\d+[\d.,]*[BKMGTP]?)\s+/
    private static let ezaMetadata = /^(?<type>[.dlcbps?])[rwxstST-]{9}[+@.]?\s+(?:-|\d+[\d.,]*[bBkKmMgGtTpPeE]?)\s+\S+\s+/
    private static let prompt = /^.*[>$%#❯➜][ \t]+(?:command[ \t]+)?(?:\/(?:[\w.+-]+\/)*)?(ls|eza)(?:[ \t]+(.*))?$/
    private static let shellWord = /(?:'[^']*'|"[^"$`\\]*"|\\[^\r\n]|[^\s'"`\\$;&|<>()*?\[\]{}!])+/
    private static let longOptions: Set<String> = ["--long", "--all", "--almost-all", "--color=never", "--color=always", "--color=auto"]
    private static let shortOptions = Set("alAhG")

    /// The filename field of a macOS ls or eza long row, excluding a symlink's printed destination.
    public static func longEntry(in line: String) -> PathMatch? {
        if let match = line.firstMatch(of: bsdMetadata) {
            return longEntry(in: line, metadataEnd: match.range.upperBound, symlink: match.type == "l", eza: false)
        }
        if let match = line.firstMatch(of: ezaMetadata) {
            return longEntry(in: line, metadataEnd: match.range.upperBound, symlink: match.type == "l", eza: true)
        }
        return nil
    }

    private static func longEntry(in line: String, metadataEnd: String.Index, symlink: Bool, eza: Bool) -> PathMatch? {
        guard let timestamp = line[metadataEnd...].prefixMatch(of: date),
              line.indices.contains(timestamp.range.upperBound), line[timestamp.range.upperBound] == " " else { return nil }
        let nameStart = line.index(after: timestamp.range.upperBound)
        let name = line[nameStart...]
        let arrow = /[ ](?:->|⇒)[ ]/
        let separators = symlink ? name.matches(of: arrow) : []
        guard separators.count <= 1 else { return nil }
        let printedName = name[..<(separators.first?.range.lowerBound ?? name.endIndex)]
        return filename(printedName, in: line, eza: eza)
    }

    /// Eza separates short-view columns with padding and quotes filenames containing spaces.
    public static func shortEntry(in line: String, at offset: Int) -> PathMatch? {
        let field = /(?:^| {2,}|\t)('(?:[^']*)'|"(?:[^"]*)"|\S+)(?= {2,}|\t|$)/
        return line.matches(of: field)
            .compactMap { filename($0.1, in: line, eza: true) }
            .first { $0.characters.contains(offset) }
    }

    private static func filename(_ spelling: Substring, in line: String, eza: Bool) -> PathMatch? {
        var name = spelling
        if eza, name.count > 1, let quote = name.first, quote == "'" || quote == "\"", name.last == quote {
            name = name.dropFirst().dropLast()
        }
        guard !name.isEmpty else { return nil }
        let start = line.distance(from: line.startIndex, to: name.startIndex)
        return PathMatch(path: DetectedPath(path: String(name), line: nil, column: nil), characters: start..<(start + name.count))
    }

    /// Returns a path only when the listing command identifies its base. Relative operands are safe
    /// to use with the live cwd when the listing immediately precedes the cursor's prompt.
    public static func path(for entry: PathMatch, in rows: [String], at index: Int, reachesCursor: Bool,
                            isLong: Bool) -> DetectedPath? {
        guard rows.indices.contains(index), index > 0 else { return nil }
        var commandRow = index - 1
        if isLong {
            while commandRow >= 0, isLongListingRow(rows[commandRow]) { commandRow -= 1 }
        } else {
            while commandRow >= 0, isShortListingRow(rows[commandRow]) { commandRow -= 1 }
        }
        guard commandRow >= 0, let command = command(in: rows[commandRow]), isLong || command.name == "eza" else { return nil }

        let base = command.operand ?? "."
        let filename = entry.path.path
        let absoluteBase = base.hasPrefix("/") || base == "~" || base.hasPrefix("~/")
        let path: String
        if filename.hasPrefix("/") || (filename.contains("/") && filename == base) {
            path = filename
        } else {
            path = base + "/" + filename
        }
        if !path.hasPrefix("/") && !absoluteBase {
            guard reachesCursor, rows[(index + 1)...].allSatisfy(isLong ? isLongListingRow : isShortListingRow) else { return nil }
        }
        return DetectedPath(path: path, line: nil, column: nil)
    }

    private static func isLongListingRow(_ row: String) -> Bool {
        row.prefixMatch(of: /^total\s+\d+$/) != nil || longEntry(in: row) != nil
    }

    private static func isShortListingRow(_ row: String) -> Bool {
        !row.isEmpty && row.firstMatch(of: /[>$%#❯➜][ \t]+/) == nil
            && longEntry(in: row) == nil
    }

    private static func command(in row: String) -> (name: String, operand: String?)? {
        guard let match = row.firstMatch(of: prompt) else { return nil }
        var rest = match.2 ?? ""
        var operand: String?
        var readsOptions = true
        while !rest.isEmpty {
            rest = rest.drop(while: { $0 == " " || $0 == "\t" })
            if rest.isEmpty { break }
            guard let word = rest.prefixMatch(of: shellWord) else { return nil }
            rest = rest[word.range.upperBound...]
            guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
            if readsOptions && word.0 == "--" {
                readsOptions = false
            } else if readsOptions && word.0.hasPrefix("-") {
                guard longOptions.contains(String(word.0)) || word.0.dropFirst().allSatisfy(shortOptions.contains) else { return nil }
            } else {
                guard operand == nil else { return nil }
                operand = unquote(word.0)
                guard operand != nil else { return nil }
            }
        }
        return (String(match.1), operand)
    }

    private static func unquote(_ word: Substring) -> String? {
        // Evaluate no shell expressions. Support a whole quoted operand or a simple backslash escape.
        if let quote = word.first, quote == "'" || quote == "\"" {
            let contents = word.dropFirst().dropLast()
            guard word.last == quote, !contents.isEmpty, !contents.contains(quote), !contents.hasPrefix("~") else { return nil }
            return String(contents)
        }
        guard !word.contains("'"), !word.contains("\"") else { return nil }
        var result = ""
        var escaping = false
        for character in word {
            if character == "\\" && !escaping { escaping = true; continue }
            if result.isEmpty, escaping, character == "~" { return nil }
            result.append(character)
            escaping = false
        }
        return escaping ? nil : result
    }
}
