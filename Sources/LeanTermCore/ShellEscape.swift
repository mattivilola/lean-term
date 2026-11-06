import Foundation

public enum ShellEscape {
    private static let special = Set(" \\'\"$&;|<>()[]{}*?!#~`")

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7F
    }

    /// Escapes a path for the shell. Ordinary paths are backslash-escaped the way Terminal.app does for dropped
    /// files. A path with control characters (a newline would submit the line) uses ANSI-C `$'…'` quoting instead.
    public static func path(_ value: String) -> String {
        if value.unicodeScalars.contains(where: isControl) {
            var result = "$'"
            for scalar in value.unicodeScalars {
                switch scalar {
                case "\\": result += "\\\\"
                case "'": result += "\\'"
                case "\n": result += "\\n"
                case "\t": result += "\\t"
                case _ where isControl(scalar):
                    let hex = String(scalar.value, radix: 16, uppercase: true)
                    result += "\\x" + (hex.count < 2 ? "0" : "") + hex
                default: result.unicodeScalars.append(scalar)
                }
            }
            return result + "'"
        }
        var result = ""
        for character in value {
            if special.contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }
}
