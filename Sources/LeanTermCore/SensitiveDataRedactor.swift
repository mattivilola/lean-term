import Foundation

/// Replaces credentials and personal data in copied terminal text with `[REMOVED:<kind>]` placeholders.
public enum SensitiveDataRedactor {
    public struct Result: Equatable, Sendable {
        public let text: String
        public let removed: Int
    }

    public static func redact(_ text: String) -> Result {
        var current = text as NSString
        var removed = 0
        for rule in rules where rule.applies(to: current) {
            current = rule.apply(to: current, removed: &removed)
        }
        return Result(text: current as String, removed: removed)
    }

    static func placeholder(_ kind: String) -> String { "[REMOVED:\(kind)]" }

    // MARK: Rules

    /// One precompiled pattern; `replace` returns the range to replace and its kind, or nil to leave the match alone.
    private struct Rule {
        let regex: NSRegularExpression
        let needle: String?
        let replace: @Sendable (NSTextCheckingResult, NSString) -> (range: NSRange, kind: String)?

        init(_ pattern: String, options: NSRegularExpression.Options = [], needle: String? = nil,
             replace: @escaping @Sendable (NSTextCheckingResult, NSString) -> (range: NSRange, kind: String)?) {
            // Patterns are constants covered by the tests; a failure here is a programmer error.
            self.regex = try! NSRegularExpression(pattern: pattern, options: options)
            self.needle = needle
            self.replace = replace
        }

        /// Cheap substring guard so rules anchored on a literal skip text that cannot match.
        func applies(to text: NSString) -> Bool {
            guard let needle else { return true }
            return text.range(of: needle, options: .caseInsensitive).location != NSNotFound
        }

        func apply(to ns: NSString, removed: inout Int) -> NSString {
            let out = NSMutableString()
            var cursor = 0
            var count = 0
            regex.enumerateMatches(in: ns as String, options: [], range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                guard let match, let (range, kind) = replace(match, ns), range.location >= cursor else { return }
                out.append(ns.substring(with: NSRange(location: cursor, length: range.location - cursor)))
                out.append(SensitiveDataRedactor.placeholder(kind))
                cursor = range.location + range.length
                count += 1
            }
            guard count > 0 else { return ns }
            removed += count
            out.append(ns.substring(from: cursor))
            return out
        }
    }

    private static let rules: [Rule] = [privateKey, urlCredentials, authorization, tokenFormats, keyValue, card, iban, usSSN, finnishSSN, email]

    private static let privateKey = Rule(
        #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----"#,
        needle: "PRIVATE KEY-----") { match, _ in (match.range, "private-key") }

    private static let urlCredentials = Rule(
        #"(://[^\s:/@?#]{1,100}:)([^\s/@]{1,200})@"#, needle: "://") { match, _ in (match.range(at: 2), "url-credentials") }

    private static let authorization = Rule(
        #"Authorization["']?[ \t]*[:=][ \t]*["']?(?:Bearer|Basic|Token)[ \t]+([^\s'",;]+)"#,
        options: .caseInsensitive, needle: "Authorization") { match, _ in (match.range(at: 1), "bearer-token") }

    private static let tokenFormats = Rule(
        #"\b(?:(?:AKIA|ASIA)[0-9A-Z]{16}\b|(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36,}\b|github_pat_[A-Za-z0-9_]{22,}\b"#
        + #"|xox[abprs]-[A-Za-z0-9-]{10,}\b|sk-[A-Za-z0-9_-]{20,}|AIza[0-9A-Za-z_-]{35}\b|(?:sk|pk|rk)_(?:live|test)_[0-9A-Za-z]{16,}\b"#
        + #"|glpat-[0-9A-Za-z_-]{20,}\b|npm_[A-Za-z0-9]{36}\b|eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b)"#) { match, ns in
        let token = ns.substring(with: match.range)
        let kind: String
        if token.hasPrefix("AKIA") || token.hasPrefix("ASIA") { kind = "aws-key" }
        else if token.hasPrefix("gh") { kind = "github-token" }
        else if token.hasPrefix("xox") { kind = "slack-token" }
        else if token.hasPrefix("eyJ") { kind = "jwt" }
        else { kind = "api-key" }
        return (match.range, kind)
    }

    /// Label suffixes and bare values that mark configuration rather than a secret (`token_count`, `password=false`).
    private static let inertSuffixes: Set<String> = ["count", "type", "len", "length", "limit", "size", "name", "file", "path", "url",
                                                    "uri", "endpoint", "id", "ttl", "expiry", "expires"]
    private static let inertValues: Set<String> = ["true", "false", "null", "nil", "none"]

    /// Label (whole word, `_`/`-` affixes allowed), separator, then a quoted or bare value. Groups: 1 label, 2 affix suffix, 3-5 value.
    private static let keyValue = Rule(
        #"(?<![A-Za-z0-9])(passphrase|password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key)"#
        + #"((?:[_-][A-Za-z0-9]{1,30}){0,3})["']?[ \t]?(?:=>|[=:])[ \t]?"#
        + #"(?:"([^"\n]*)"|'([^'\n]*)'|([^\s,;&"'][^\s,;&]*))"#,
        options: .caseInsensitive) { match, ns in
        let label = ns.substring(with: match.range(at: 1)).lowercased()
        guard let value = (3...5).map({ match.range(at: $0) }).first(where: { $0.location != NSNotFound }), value.length > 0 else { return nil }
        let suffix = ns.substring(with: match.range(at: 2)).lowercased()
        if suffix.split(whereSeparator: { $0 == "_" || $0 == "-" }).contains(where: { inertSuffixes.contains(String($0)) }) { return nil }
        let text = ns.substring(with: value)
        if text.contains("[REMOVED:") || text.contains("(") || text.count < 6 { return nil }
        if text.allSatisfy(\.isASCII) && text.allSatisfy(\.isNumber) || inertValues.contains(text.lowercased()) { return nil }
        if label == "pwd", text.hasPrefix("/") || text.hasPrefix("~") { return nil }
        let kind: String
        switch label {
        case "passphrase", "password", "passwd", "pwd": kind = "password"
        case "secret": kind = "secret"
        case "token": kind = "token"
        default: kind = "api-key"
        }
        return (value, kind)
    }

    /// 13-19 digits, contiguous or in consistent space/dash groups. A first digit of 0/1/7/9 is never a card network, which spares epoch timestamps.
    private static let card = Rule(#"(?<!\d)[2-68]\d{2}[\d -]{9,21}\d(?!\d)"#) { match, ns in
        var digits: [Int] = []
        var separator: unichar = 0
        var groups = 1
        var groupLength = 0
        for index in match.range.location..<(match.range.location + match.range.length) {
            let unit = ns.character(at: index)
            if unit >= 0x30, unit <= 0x39 {
                digits.append(Int(unit - 0x30))
                groupLength += 1
            } else {
                guard groupLength > 0, groupLength <= 7, separator == 0 || separator == unit else { return nil }
                separator = unit
                groups += 1
                groupLength = 0
            }
        }
        guard (13...19).contains(digits.count), groups == 1 || (3...5).contains(groups), groupLength <= 7 || groups == 1,
              luhnValid(digits) else { return nil }
        return (match.range, "card-number")
    }

    private static let iban = Rule(
        #"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){2,7}(?: ?[A-Z0-9]{1,3})?(?![A-Za-z0-9])"#) { match, ns in
        let compact = ns.substring(with: match.range).replacingOccurrences(of: " ", with: "")
        guard (15...34).contains(compact.count), ibanValid(compact) else { return nil }
        return (match.range, "iban")
    }

    private static let usSSN = Rule(#"\b(?!000|666|9\d\d)\d{3}-(?!00)\d{2}-(?!0000)\d{4}\b"#) { match, _ in (match.range, "ssn") }

    private static let finnishSSN = Rule(#"\b\d{6}[-+A-FU-Y]\d{3}[0-9A-FHJ-NPR-Y]\b"#) { match, ns in
        guard finnishSSNValid(Array(ns.substring(with: match.range))) else { return nil }
        return (match.range, "finnish-ssn")
    }

    /// Matches the domain (not followed by `:`) from its `@` (cheap literal anchor), then extends left over the local part in code to keep the scan linear.
    private static let email = Rule(
        #"@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,24}"#, needle: "@") { match, ns in
        // `user@host:path` is an scp/ssh remote, not an address.
        let end = match.range.location + match.range.length
        if end < ns.length, ns.character(at: end) == 0x3A { return nil }
        func isLocal(_ unit: unichar) -> Bool {
            switch unit {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2E, 0x5F, 0x25, 0x2B, 0x2D: return true
            default: return false
            }
        }
        var start = match.range.location
        while start > 0, isLocal(ns.character(at: start - 1)) { start -= 1 }
        let length = match.range.location - start
        guard (1...64).contains(length) else { return nil }
        return (NSRange(location: start, length: match.range.length + length), "email")
    }

    // MARK: Validators

    static func luhnValid(_ digits: [Int]) -> Bool {
        var sum = 0
        for (index, digit) in digits.reversed().enumerated() {
            if index % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }

    static func ibanValid(_ iban: String) -> Bool {
        let rearranged = iban.dropFirst(4) + iban.prefix(4)
        var remainder = 0
        for character in rearranged {
            guard let ascii = character.asciiValue else { return false }
            switch ascii {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): remainder = (remainder * 10 + Int(ascii - UInt8(ascii: "0"))) % 97
            case UInt8(ascii: "A")...UInt8(ascii: "Z"): remainder = (remainder * 100 + Int(ascii - UInt8(ascii: "A")) + 10) % 97
            default: return false
            }
        }
        return remainder == 1
    }

    /// `DDMMYY`, century sign, three-digit individual number, check character.
    static func finnishSSNValid(_ chars: [Character]) -> Bool {
        guard chars.count == 11, let day = Int(String(chars[0...1])), let month = Int(String(chars[2...3])),
              let year = Int(String(chars[4...5])), let individual = Int(String(chars[7...9])) else { return false }
        let fullYear: Int
        switch chars[6] {
        case "+": fullYear = 1800 + year
        case "-", "U", "V", "W", "X", "Y": fullYear = 1900 + year
        default: fullYear = 2000 + year
        }
        let leap = fullYear % 4 == 0 && (fullYear % 100 != 0 || fullYear % 400 == 0)
        let monthLengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...12).contains(month), (1...monthLengths[month - 1]).contains(day) else { return false }
        let number = (day * 10_000 + month * 100 + year) * 1000 + individual
        let checks = Array("0123456789ABCDEFHJKLMNPRSTUVWXY")
        return chars[10] == checks[number % 31]
    }
}
