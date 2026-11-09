import Foundation

/// A strictly validated `ssh://[user@]host[:port]` link. Only validated parts can reach a command line.
public struct SSHLink: Equatable, Sendable {
    public let user: String?
    public let host: String
    public let port: Int?

    /// Returns nil for anything other than a plain ssh URL with a safe user, host and port.
    public init?(_ url: URL) {
        let text = url.absoluteString
        guard let range = text.range(of: "ssh://", options: [.anchored, .caseInsensitive]) else { return nil }
        var authority = text[range.upperBound...]
        if let end = authority.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            guard authority[end...] == "/" else { return nil }
            authority = authority[..<end]
        }
        var hostPort = authority
        var user: String?
        let parts = authority.split(separator: "@", maxSplits: 2, omittingEmptySubsequences: false)
        if parts.count == 2 { user = String(parts[0]); hostPort = parts[1] }
        else if parts.count != 1 { return nil }
        if let user {
            guard Self.matches(user, 64, { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }),
                  !user.hasPrefix("-") else { return nil }
        }
        var host: Substring
        var portText: Substring?
        if hostPort.hasPrefix("[") {
            guard let close = hostPort.firstIndex(of: "]") else { return nil }
            host = hostPort[hostPort.index(after: hostPort.startIndex)..<close]
            let rest = hostPort[hostPort.index(after: close)...]
            if !rest.isEmpty { guard rest.hasPrefix(":") else { return nil }; portText = rest.dropFirst() }
            guard host.contains(":"), Self.matches(String(host), 45, { $0.isHexDigit || $0 == ":" || $0 == "." }) else { return nil }
        } else {
            let pieces = hostPort.split(separator: ":", omittingEmptySubsequences: false)
            guard pieces.count <= 2 else { return nil }
            host = pieces[0]
            if pieces.count == 2 { portText = pieces[1] }
            guard Self.matches(String(host), 253, { $0.isASCII && ($0.isLetter || $0.isNumber || ".-".contains($0)) }),
                  !host.hasPrefix("-") else { return nil }
        }
        var port: Int?
        if let portText {
            guard portText.count <= 5, portText.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(portText), (1...65535).contains(value) else { return nil }
            port = value
        }
        self.user = user; self.host = String(host); self.port = port
    }

    private static func matches(_ value: String, _ limit: Int, _ allowed: (Character) -> Bool) -> Bool {
        !value.isEmpty && value.count <= limit && value.allSatisfy(allowed)
    }

    public var command: String {
        command(keepAlive: false)
    }

    public func command(keepAlive: Bool) -> String {
        let client = keepAlive ? "/usr/bin/ssh \(ForegroundSession.sshKeepAliveOption)" : "ssh"
        return client + (port.map { " -p \($0)" } ?? "") + " " + (user.map { $0 + "@" } ?? "") + host
    }
}
