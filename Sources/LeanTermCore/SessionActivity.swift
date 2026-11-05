import Foundation

public enum ActivityIndicator: Equatable, Sendable { case idle, sweeping, holding }
public enum SessionActivityEvent: Equatable, Sendable { case finishedLongCommand }

public struct SessionActivitySample: Equatable, Sendable {
    public let foregroundJobRunning: Bool
    public let alternateScreen: Bool
    public let outputCount: UInt64
    /// Monotonic seconds (`ProcessInfo.systemUptime`).
    public let time: TimeInterval

    public init(foregroundJobRunning: Bool, alternateScreen: Bool, outputCount: UInt64, time: TimeInterval) {
        self.foregroundJobRunning = foregroundJobRunning
        self.alternateScreen = alternateScreen
        self.outputCount = outputCount
        self.time = time
    }
}

/// Turns periodic samples of a session into a visual indicator and a "long command finished" event.
public struct SessionActivityModel: Equatable, Sendable {
    public static let revealDelay: TimeInterval = 0.4
    public static let quietAfter: TimeInterval = 5
    public static let longCommand: TimeInterval = 10

    public private(set) var indicator: ActivityIndicator = .idle
    /// True while another sample is needed: a job is running or output just changed.
    public private(set) var needsPolling = false

    private var running = false
    private var jobStart: TimeInterval = 0
    private var lastOutputTime: TimeInterval = 0
    private var usedAlternate = false
    private var lastOutputCount: UInt64 = 0

    public init() {}

    @discardableResult
    public mutating func record(_ sample: SessionActivitySample) -> SessionActivityEvent? {
        let outputChanged = sample.outputCount != lastOutputCount
        lastOutputCount = sample.outputCount
        var event: SessionActivityEvent?

        if sample.foregroundJobRunning {
            if !running {
                jobStart = sample.time
                lastOutputTime = sample.time
                usedAlternate = sample.alternateScreen
            } else {
                if outputChanged { lastOutputTime = sample.time }
                usedAlternate = usedAlternate || sample.alternateScreen
            }
        } else if running, sample.time - jobStart >= Self.longCommand, !usedAlternate {
            event = .finishedLongCommand
        }
        running = sample.foregroundJobRunning

        if !running || sample.alternateScreen || sample.time - jobStart < Self.revealDelay {
            indicator = .idle
        } else if sample.time - lastOutputTime < Self.quietAfter {
            indicator = .sweeping
        } else {
            indicator = .holding
        }
        needsPolling = running || outputChanged
        return event
    }

    /// For shell exit or failure: idle, no polling, and no pending job.
    public mutating func reset() {
        self = SessionActivityModel()
    }
}
