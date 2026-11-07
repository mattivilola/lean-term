import Foundation

/// Finds the output of a command in the row roles that the terminal derives from OSC 133 marks:
/// 1 for a row that opens a prompt, 2 for a row holding command output, 0 for anything else.
public enum CommandOutputLocator {
    /// The rows from the first to the last output row of one command, or nil when there is none.
    ///
    /// When the viewport shows the live bottom this is the most recent command that produced output;
    /// otherwise it is the command whose prompt is nearest at or above the top of the viewport.
    public static func outputRows(roles: [UInt8], viewportTop: Int, visibleRows: Int) -> ClosedRange<Int>? {
        let prompts = roles.indices.filter { roles[$0] == 1 }
        guard !prompts.isEmpty else { return nil }
        if viewportTop + visibleRows >= roles.count {
            for (index, prompt) in prompts.enumerated().reversed() {
                let end = index + 1 < prompts.count ? prompts[index + 1] : roles.count
                if let rows = output(in: roles, after: prompt, before: end) { return rows }
            }
            return nil
        }
        guard let index = prompts.lastIndex(where: { $0 <= viewportTop }) else { return nil }
        let end = index + 1 < prompts.count ? prompts[index + 1] : roles.count
        return output(in: roles, after: prompts[index], before: end)
    }

    private static func output(in roles: [UInt8], after prompt: Int, before end: Int) -> ClosedRange<Int>? {
        guard prompt + 1 < end,
              let first = (prompt + 1..<end).first(where: { roles[$0] == 2 }),
              let last = (prompt + 1..<end).last(where: { roles[$0] == 2 }) else { return nil }
        return first...last
    }
}
