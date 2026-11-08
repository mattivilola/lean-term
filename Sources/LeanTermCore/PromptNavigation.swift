import Foundation

/// A command delimited by OSC 133 marks, as the terminal derives it: the row that opens its prompt, its
/// last row, and the status `D;<status>` reported (nil while it runs or when none was reported).
public struct CommandSpan: Equatable, Sendable {
    public var promptRow: Int
    public var lastRow: Int
    public var exitCode: Int?
    /// Whether the command wrote output. Only known for status 0; see `CommandStatusLayout.bars`.
    public var hasOutput: Bool

    public init(promptRow: Int, lastRow: Int, exitCode: Int?, hasOutput: Bool = false) {
        self.promptRow = promptRow
        self.lastRow = lastRow
        self.exitCode = exitCode
        self.hasOutput = hasOutput
    }

    public var outcome: CommandOutcome? { exitCode.map(CommandOutcome.init(exitCode:)) }
}

/// Chooses which command "Select Command Output" works on.
public enum CommandOutputLocator {
    /// The commands to try, best first. When the viewport shows the live bottom that is every command,
    /// newest first (the caller takes the first one that produced output); otherwise it is only the
    /// command whose prompt is nearest at or above the top of the viewport.
    public static func candidates(spans: [CommandSpan], viewportTop: Int, atLiveBottom: Bool) -> [CommandSpan] {
        if atLiveBottom { return spans.reversed() }
        return spans.last(where: { $0.promptRow <= viewportTop }).map { [$0] } ?? []
    }
}

/// A margin bar for one finished command, in viewport rows (0 is the top row).
public struct CommandStatusBar: Equatable, Sendable {
    public var promptRow: Int
    public var firstRow: Int
    public var lastRow: Int
    public var outcome: CommandOutcome
}

public enum CommandStatusLayout {
    /// The bars to draw for `spans` in a viewport starting at buffer row `viewportTop`: finished commands
    /// only, clipped to the visible rows. A bar spans the prompt row through the last output row. A silent
    /// success (status 0, no output: an empty Enter, `cd`) gets no bar; a failure always does.
    public static func bars(spans: [CommandSpan], viewportTop: Int, visibleRows: Int) -> [CommandStatusBar] {
        spans.compactMap { span in
            guard let outcome = span.outcome, outcome.isFailure || span.hasOutput, span.lastRow >= viewportTop,
                  span.promptRow < viewportTop + visibleRows else { return nil }
            return CommandStatusBar(promptRow: span.promptRow,
                                    firstRow: max(span.promptRow, viewportTop) - viewportTop,
                                    lastRow: min(span.lastRow, viewportTop + visibleRows - 1) - viewportTop,
                                    outcome: outcome)
        }
    }
}
