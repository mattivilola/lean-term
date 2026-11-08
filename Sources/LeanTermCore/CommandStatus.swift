import Foundation

/// How a command that reported its exit code (OSC 133 `D;<code>`) ended.
public enum CommandOutcome: Equatable, Sendable {
    case succeeded
    case failed(exitCode: Int)
    /// Exit codes of 128 and above follow the shell convention `128 + signal`.
    case interrupted(signal: Int)

    public init(exitCode: Int) {
        if exitCode == 0 { self = .succeeded }
        else if exitCode >= 128 { self = .interrupted(signal: exitCode - 128) }
        else { self = .failed(exitCode: exitCode) }
    }

    /// Tooltip and accessibility text for a margin bar.
    public var summary: String {
        switch self {
        case .succeeded: "Succeeded"
        case .failed(let code): "Failed · exit \(code)"
        case .interrupted(let signal): "Interrupted · signal \(signal)"
        }
    }

    /// Whether the command should be reported as failed (tab ring, notification).
    public var isFailure: Bool { self != .succeeded }

    /// The notification text: "Finished after 12 s" or "Failed (exit 2) after 12 s".
    public static func notificationBody(exitCode: Int?, duration: String) -> String {
        guard let exitCode, exitCode != 0 else { return "Finished after \(duration)" }
        return "Failed (exit \(exitCode)) after \(duration)"
    }

    /// A short pulse along the activity scanner when a command ends in a pane that is being watched.
    public enum Pulse: Equatable, Sendable { case failure, success }

    /// Failures always pulse, successes only after a command that took `minimumSuccessDuration`.
    /// Interrupted commands (Ctrl-C and friends) are deliberate and stay quiet.
    public static let minimumSuccessDuration: TimeInterval = 10

    public func pulse(after duration: TimeInterval?) -> Pulse? {
        switch self {
        case .failed: .failure
        case .interrupted: nil
        case .succeeded: (duration ?? 0) >= Self.minimumSuccessDuration ? .success : nil
        }
    }
}

/// What an OSC 133 sequence says about the shell, for the moments the app times or reports.
public enum ShellMark: Equatable, Sendable {
    case promptStart
    case commandStart
    /// The command finished; the status is nil when the shell sent none or a non-numeric one.
    case commandEnd(exitCode: Int?)
    case other

    /// Parses the payload of `OSC 133 ; <payload>`: an action letter, then `;`-separated fields.
    public init(osc133 payload: [UInt8]) {
        let fields = payload.split(separator: UInt8(ascii: ";"), omittingEmptySubsequences: false)
        guard let action = fields.first, action.count == 1 else { self = .other; return }
        switch action.first {
        case UInt8(ascii: "A"), UInt8(ascii: "N"): self = .promptStart
        case UInt8(ascii: "C"): self = .commandStart
        case UInt8(ascii: "D"):
            let digits = fields.dropFirst().first.map(Array.init) ?? []
            let valid = !digits.isEmpty && digits.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
            self = .commandEnd(exitCode: valid ? Int(String(decoding: digits, as: UTF8.self)) : nil)
        default: self = .other
        }
    }
}
