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
    // Lean Term: row-level access to OSC 133 marks for prompt navigation and "Select Command Output".

    /// Whether the normal buffer holds at least one OSC 133 prompt row.
    public var hasSemanticPrompts: Bool {
        withTerminal { terminal in
            guard !terminal.isCurrentBufferAlternate else { return false }
            let buffer = terminal.buffer
            return (0..<buffer.lines.count).contains { buffer.semanticRowOpensPrompt($0) }
        }
    }

    /// One byte per buffer row (scrollback included): 1 when the row opens a prompt, 2 when a cell of
    /// the row is command output, 0 otherwise. Rows before the first prompt are never classified as
    /// output. `viewportTop` is the buffer row at the top of the viewport. Nil in the alternate buffer.
    public func semanticRowRoles() -> (roles: [UInt8], viewportTop: Int, visibleRows: Int)? {
        withTerminal { terminal in
            guard !terminal.isCurrentBufferAlternate else { return nil }
            let buffer = terminal.buffer
            var roles = [UInt8](repeating: 0, count: buffer.lines.count)
            var seenPrompt = false
            for row in 0..<roles.count {
                if buffer.semanticRowOpensPrompt(row) {
                    roles[row] = 1
                    seenPrompt = true
                } else if seenPrompt {
                    let line = buffer.lines[row]
                    for column in 0..<line.count where line[column].semanticContent == .output {
                        roles[row] = 2
                        break
                    }
                }
            }
            return (roles, buffer.yDisp, terminal.rows)
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
    if text.count(PROMPT_ANCHOR) != 1:
        raise SystemExit('Prompt navigation patch anchor not found exactly once.')
    return text.replace(PROMPT_ANCHOR, PROMPT_ANCHOR + PROMPT_API)

patches = [
    ('Sources/SwiftTerm/LocalProcess.swift', lifecycle,
     '7be01862b8fb9fa3c4724b3cedd98dbe3a58a1877b40171bf008680e93d58fd3',
     '71cf47429151843315b8875cd6ac75ac5006fe2fdcf925fdaf6861435804be52'),
    ('Sources/SwiftTerm/Mac/MacTerminalView.swift', prompts,
     '1c0a7c55bc5bd8bada43ebb1645c769f0495a0eed6ad8cef880d4164afb0fd92',
     'e90d23a6ee563e760e7f35f1e63aec95b0a62ad98c23089a5f172d0e9764aaf4'),
]

for relative, transform, original, patched in patches:
    source = checkout / relative
    data = source.read_bytes()
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
