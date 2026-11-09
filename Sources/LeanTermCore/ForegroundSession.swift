import Foundation

/// The foreground process-group leader of a terminal session, as read from the kernel.
public struct ForegroundProcess: Equatable, Sendable {
    /// The leader's `p_comm`, e.g. "ssh".
    public let name: String
    /// argv including argv[0]; empty when unreadable or not needed.
    public let arguments: [String]
    public let effectiveUserID: uid_t

    public init(name: String, arguments: [String], effectiveUserID: uid_t) {
        self.name = name
        self.arguments = arguments
        self.effectiveUserID = effectiveUserID
    }
}

/// What kind of session the foreground job represents: a plain local job, one running as root, or a remote login.
public enum ForegroundSession: Equatable, Sendable {
    case local
    case root
    case remote(tool: String, host: String?)

    public static let remoteTools: Set<String> = ["ssh", "autossh", "mosh-client", "et"]
    public static let sshKeepAliveOption = "-oServerAliveInterval=30"

    /// Lean Term adds this option before the destination. This describes the SSH invocation,
    /// since a multiplexed session may reuse an existing transport with its own settings.
    public static func requestsSSHKeepAlive(_ process: ForegroundProcess?) -> Bool {
        process?.name == "ssh" && process?.arguments.dropFirst().first == sshKeepAliveOption
    }

    public init(_ process: ForegroundProcess?) {
        guard let process else { self = .local; return }
        if Self.remoteTools.contains(process.name) {
            let hasDestination = process.name == "ssh" || process.name == "autossh"
            self = .remote(tool: process.name,
                           host: hasDestination ? Self.sshDestination(arguments: process.arguments) : nil)
        } else if process.effectiveUserID == 0 {
            self = .root
        } else {
            self = .local
        }
    }

    private static let sshValueOptions = Set("BbcDEeFIiJLlmOoPpQRSWw")

    /// The destination host of an ssh or autossh command line (argv including argv[0]).
    public static func sshDestination(arguments: [String]) -> String? {
        guard let command = arguments.first else { return nil }
        let isAutossh = URL(fileURLWithPath: command).lastPathComponent == "autossh"
        let valueOptions = isAutossh ? sshValueOptions.union(["M"]) : sshValueOptions
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument == "--" {
                return index < arguments.count ? host(from: arguments[index]) : nil
            }
            guard argument.hasPrefix("-"), argument.count > 1 else { return host(from: argument) }
            let flags = argument.dropFirst()
            for (offset, flag) in zip(flags.indices, flags) where valueOptions.contains(flag) {
                if flags.index(after: offset) == flags.endIndex { index += 1 }
                break
            }
        }
        return nil
    }

    private static func host(from destination: String) -> String? {
        var value = Substring(destination)
        let isURL = value.hasPrefix("ssh://")
        if isURL { value = value.dropFirst("ssh://".count) }
        if isURL, let slash = value.firstIndex(of: "/") { value = value[..<slash] }
        if let at = value.lastIndex(of: "@") { value = value[value.index(after: at)...] }
        if value.hasPrefix("["), let close = value.firstIndex(of: "]") {
            value = value[value.index(after: value.startIndex)..<close]
        } else if isURL, let colon = value.lastIndex(of: ":") {
            value = value[..<colon]
        }
        return value.isEmpty ? nil : String(value)
    }
}
