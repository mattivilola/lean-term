#!/usr/bin/env python3
"""Apply the reviewed compatibility changes to the exact pinned SwiftTerm source."""
from pathlib import Path
import hashlib
import subprocess
import stat

root = Path(__file__).resolve().parents[1]
checkout = root / '.build/checkouts/SwiftTerm'
revision = subprocess.check_output(['git', '-C', str(checkout), 'rev-parse', 'HEAD'], text=True).strip()
if revision != '309adcc28bdf0e01f6403d04616323b379fb5635':
    raise SystemExit('Unexpected SwiftTerm revision; review the patches before building.')

def lifecycle(text):
    text = text.replace('public func terminate() {', 'public func terminate(signal: Int32 = SIGTERM) {')
    text = text.replace('case .terminating:\n                return nil\n            default:',
                        'case .terminating:\n                return state.reaper\n            default:')
    return text.replace('reaper?.signal(SIGTERM)\n    }', 'reaper?.signal(signal)\n    }')

PROMPT_ANCHOR = '''    public override func selectAll(_ sender: Any?)
    {
        selectAll ()
    }
'''
PROMPT_API = '''
    // Lean Term: row-level access to OSC 133 marks for prompt navigation, "Select Command Output" and
    // the command status bars. Every call is bounded by the rows asked for plus `semanticScanLimit`.

    /// How far a command lookup scans outside the rows it was asked for (up to the enclosing prompt,
    /// and down to the end of a command that continues past the range).
    public static let semanticScanLimit = 10_000

    /// A command delimited by OSC 133 prompt marks: the prompt row that opens it, its last row (the row
    /// before the next prompt) and the exit status `D;<status>` reported for it.
    public struct SemanticCommandSpan: Equatable, Sendable {
        public var promptRow: Int
        public var lastRow: Int
        /// Nil while the command runs, when the shell did not report a status, or when the command
        /// is longer than `semanticScanLimit` rows.
        public var exitCode: Int?
        /// Whether a row of the command holds output cells. Only computed for status 0 (a silent success
        /// gets no margin bar); false otherwise.
        public var hasOutput: Bool
    }

    /// Whether the normal buffer holds at least one OSC 133 prompt row.
    public var hasSemanticPrompts: Bool {
        withTerminal { terminal in
            guard !terminal.isCurrentBufferAlternate else { return false }
            let buffer = terminal.buffer
            return (0..<buffer.lines.count).contains { buffer.semanticRowOpensPrompt($0) }
        }
    }

    /// The buffer row at the top of the viewport, the viewport height and the buffer height in rows.
    /// Nil in the alternate buffer.
    public var semanticViewport: (top: Int, rows: Int, total: Int)? {
        withTerminal { terminal in
            guard !terminal.isCurrentBufferAlternate else { return nil }
            return (terminal.buffer.yDisp, terminal.rows, terminal.buffer.lines.count)
        }
    }

    /// The commands that intersect the buffer rows `rows`, in order. The command enclosing the first row
    /// is found by scanning up to `semanticScanLimit` rows upward. A command ends on the row before the
    /// next prompt (or at the cursor while none follows) and carries the status that its `D` reported.
    /// Empty in the alternate buffer.
    public func semanticCommandSpans(rows: Range<Int>) -> [SemanticCommandSpan] {
        withTerminal { terminal in
            guard !terminal.isCurrentBufferAlternate else { return [] }
            let buffer = terminal.buffer
            let count = buffer.lines.count
            let limit = Self.semanticScanLimit
            let lower = max(0, rows.lowerBound)
            let upper = min(count, rows.upperBound)
            guard lower < upper else { return [] }
            func nextPrompt(from start: Int, below end: Int) -> Int? {
                var row = start
                while row < end {
                    if buffer.semanticRowOpensPrompt(row) { return row }
                    row += 1
                }
                return nil
            }
            var prompt: Int?
            var row = lower
            while row >= max(0, lower - limit) {
                if buffer.semanticRowOpensPrompt(row) { prompt = row; break }
                row -= 1
            }
            if prompt == nil { prompt = nextPrompt(from: lower, below: upper) }
            // The last row that can hold output of a command that no prompt follows yet.
            let cursorRow = buffer.yBase + buffer.y
            let liveEnd = min(count - 1, buffer.x == 0 ? cursorRow - 1 : cursorRow)
            var spans: [SemanticCommandSpan] = []
            while let first = prompt, first < upper {
                let stop = min(count, first + 1 + limit)
                var last = max(first, liveEnd)
                var exitCode: Int? = buffer.lines[first].semanticExitCode
                if let next = nextPrompt(from: first + 1, below: stop) {
                    last = next - 1
                } else if stop < count {
                    last = stop - 1
                    exitCode = nil
                }
                var hasOutput = false
                if exitCode == 0, last > first {
                    outputScan: for outputRow in (first + 1)...min(last, count - 1) {
                        let line = buffer.lines[outputRow]
                        for column in 0..<line.count where line[column].semanticContent == .output {
                            hasOutput = true
                            break outputScan
                        }
                    }
                }
                if last >= lower { spans.append(SemanticCommandSpan(promptRow: first, lastRow: last, exitCode: exitCode, hasOutput: hasOutput)) }
                prompt = nextPrompt(from: last + 1, below: upper)
            }
            return spans
        }
    }

    /// The first to the last row of the command spanning `promptRow` through `lastRow` that holds command output (cells written after `C`), or nil.
    public func semanticOutputRows(promptRow: Int, lastRow commandLastRow: Int) -> ClosedRange<Int>? {
        withTerminal { terminal in
            guard !terminal.isCurrentBufferAlternate else { return nil }
            let buffer = terminal.buffer
            let firstRow = promptRow + 1
            let lastRow = min(commandLastRow, buffer.lines.count - 1)
            guard firstRow <= lastRow else { return nil }
            var first: Int?
            var last: Int?
            for row in firstRow...lastRow {
                let line = buffer.lines[row]
                for column in 0..<line.count where line[column].semanticContent == .output {
                    if first == nil { first = row }
                    last = row
                    break
                }
            }
            guard let first, let last else { return nil }
            return first...last
        }
    }

    /// Selects whole buffer rows, from the first column of the first row to the last column of the last.
    public func selectBufferRows(_ rows: ClosedRange<Int>) {
        withTerminal { terminal in
            selection.setSelection(start: Position(col: 0, row: rows.lowerBound),
                                   end: Position(col: max(0, terminal.cols - 1), row: rows.upperBound))
        }
    }
'''

def prompts(text):
    return once(text, PROMPT_ANCHOR, PROMPT_ANCHOR + PROMPT_API, 'Prompt navigation')

def once(text, old, new, what):
    if text.count(old) != 1:
        raise SystemExit(f'{what} patch anchor not found exactly once.')
    return text.replace(old, new)

def bufferline(text):
    text = once(text, '''    var semanticHardContinuationGroup: UInt64? {
        get { semanticHardContinuationGroupValue }
        set {
            guard newValue != semanticHardContinuationGroupValue else { return }
            semanticHardContinuationGroupValue = newValue
            bumpRenderOnly()
        }
    }
''', '''    var semanticHardContinuationGroup: UInt64? {
        get { semanticHardContinuationGroupValue }
        set {
            guard newValue != semanticHardContinuationGroupValue else { return }
            semanticHardContinuationGroupValue = newValue
            bumpRenderOnly()
        }
    }
    /// Lean Term: the exit status of OSC 133 `D;<status>` for the command whose prompt opens on this line.
    /// Like the continuation epoch it belongs to the line object, travels with a full-width copy and is
    /// dropped when the line is recycled. It is not drawn, so it never bumps the render generation.
    var semanticExitCode: Int? = nil
''', 'Exit code storage')
    text = once(text, '''        semanticHardContinuationGroupValue = other.semanticHardContinuationGroupValue
''', '''        semanticHardContinuationGroupValue = other.semanticHardContinuationGroupValue
        semanticExitCode = other.semanticExitCode
''', 'Exit code clone')
    text = once(text, '''        semanticHardContinuationGroupValue = nil
        isWrappedValue = isWrapped
''', '''        semanticHardContinuationGroupValue = nil
        semanticExitCode = nil
        isWrappedValue = isWrapped
''', 'Exit code recycle')
    text = once(text, '''        guard !semanticMarksValue.isEmpty || semanticHardContinuationGroupValue != nil else {
            return
        }
        if !semanticMarksValue.isEmpty {
            semanticMarksValue.removeAll(keepingCapacity: true)
        }
        semanticHardContinuationGroupValue = nil
''', '''        guard !semanticMarksValue.isEmpty || semanticHardContinuationGroupValue != nil || semanticExitCode != nil else {
            return
        }
        if !semanticMarksValue.isEmpty {
            semanticMarksValue.removeAll(keepingCapacity: true)
        }
        semanticHardContinuationGroupValue = nil
        semanticExitCode = nil
''', 'Exit code destroy')
    text = once(text, '''        semanticHardContinuationGroup = line.semanticHardContinuationGroup
        bidiState = line.bidiState
''', '''        semanticHardContinuationGroup = line.semanticHardContinuationGroup
        semanticExitCode = line.semanticExitCode
        bidiState = line.bidiState
''', 'Exit code line copy')
    text = once(text, '''        let movedSemanticHardContinuationGroup = src.semanticHardContinuationGroup
''', '''        let movedSemanticHardContinuationGroup = src.semanticHardContinuationGroup
        let movedSemanticExitCode = src.semanticExitCode
''', 'Exit code range copy')
    return once(text, '''            semanticHardContinuationGroup = movedSemanticHardContinuationGroup
            if src !== self {
                src.semanticHardContinuationGroup = nil
            }
''', '''            semanticHardContinuationGroup = movedSemanticHardContinuationGroup
            semanticExitCode = movedSemanticExitCode
            if src !== self {
                src.semanticHardContinuationGroup = nil
                src.semanticExitCode = nil
            }
''', 'Exit code range move')

def terminal(text):
    text = once(text, '''        case "C", "D":
            buffer.semanticContent = .output
''', '''        case "C", "D":
            if action == "D" { recordSemanticCommandEnd(fields.dropFirst()) }
            buffer.semanticContent = .output
''', 'OSC 133 D')
    return once(text, '''    private func markCurrentSemanticPrompt(kind: SemanticPromptKind) {
''', '''    /// Lean Term: stores the decimal status of `D;<status>` on the row that opened the prompt of the command
    /// it ends (the active prompt group's origin, so a `D` before any prompt is ignored). That row is not
    /// reset by the prompt redraw that follows a resize. An absent or non-numeric status is ignored.
    private func recordSemanticCommandEnd(_ fields: ArraySlice<Substring>) {
        guard let field = fields.first, !field.isEmpty, field.allSatisfy({ $0.isASCII && $0.isNumber }),
              let code = Int(field) else { return }
        guard let row = buffer.semanticPromptStartRow, row < buffer.lines.count else { return }
        buffer.lines[row].semanticExitCode = code
    }

    private func markCurrentSemanticPrompt(kind: SemanticPromptKind) {
''', 'OSC 133 D storage')

# Reviewed patched hashes of earlier versions of a patch: restored from git, then patched again.
patches = [
    ('Sources/SwiftTerm/LocalProcess.swift', lifecycle,
     '7be01862b8fb9fa3c4724b3cedd98dbe3a58a1877b40171bf008680e93d58fd3',
     '71cf47429151843315b8875cd6ac75ac5006fe2fdcf925fdaf6861435804be52', ()),
    ('Sources/SwiftTerm/Mac/MacTerminalView.swift', prompts,
     '1c0a7c55bc5bd8bada43ebb1645c769f0495a0eed6ad8cef880d4164afb0fd92',
     '714ce3bd2c1e30649e6c4e7d5444b7759b9b33b855489d6c91b464ddc9cd2daf', ('e90d23a6ee563e760e7f35f1e63aec95b0a62ad98c23089a5f172d0e9764aaf4',)),
    ('Sources/SwiftTerm/BufferLine.swift', bufferline,
     '206860afb27a442f7fac621d6961ad92e433686e8334b09ee742680104639d2c',
     'e3c63bec7d4c29112a48e9ff76aa366e485c5be830c9b7ee3b09783b6ea95b76', ()),
    ('Sources/SwiftTerm/Terminal.swift', terminal,
     '768c45171631c780715ba31861f503f8320720e6d5d4332295daeeb65d73d233',
     '20ba488640f4618e6d34a04fa6c658c4999146e216dd002cfb8e6b18e32bbcb6', ()),
]

for relative, transform, original, patched, superseded in patches:
    source = checkout / relative
    data = source.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    if digest in superseded:
        data = subprocess.check_output(['git', '-C', str(checkout), 'show', f'HEAD:{relative}'])
        digest = hashlib.sha256(data).hexdigest()
    if digest == original:
        text = transform(data.decode())
        if hashlib.sha256(text.encode()).hexdigest() != patched:
            raise SystemExit(f'Patch result for {relative} did not match the reviewed hash.')
        mode = source.stat().st_mode
        source.chmod(mode | stat.S_IWUSR)
        try:
            source.write_text(text)
        finally:
            source.chmod(mode)
    elif digest != patched:
        raise SystemExit(f'{relative} differs from the reviewed original and patch; refusing to overwrite it.')
print('SwiftTerm compatibility patches verified.')
