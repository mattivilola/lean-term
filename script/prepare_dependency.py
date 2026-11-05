#!/usr/bin/env python3
"""Apply one reviewed lifecycle compatibility change to the exact pinned source."""
from pathlib import Path
import hashlib
import subprocess
import stat

root = Path(__file__).resolve().parents[1]
checkout = root / '.build/checkouts/SwiftTerm'
revision = subprocess.check_output(['git', '-C', str(checkout), 'rev-parse', 'HEAD'], text=True).strip()
if revision != '309adcc28bdf0e01f6403d04616323b379fb5635':
    raise SystemExit('Unexpected SwiftTerm revision; review the lifecycle patch before building.')
source = checkout / 'Sources/SwiftTerm/LocalProcess.swift'
original = '7be01862b8fb9fa3c4724b3cedd98dbe3a58a1877b40171bf008680e93d58fd3'
patched = '71cf47429151843315b8875cd6ac75ac5006fe2fdcf925fdaf6861435804be52'
data = source.read_bytes()
digest = hashlib.sha256(data).hexdigest()
if digest == original:
    text = data.decode().replace('public func terminate() {', 'public func terminate(signal: Int32 = SIGTERM) {')
    text = text.replace('case .terminating:\n                return nil\n            default:',
                        'case .terminating:\n                return state.reaper\n            default:')
    text = text.replace('reaper?.signal(SIGTERM)\n    }', 'reaper?.signal(signal)\n    }')
    if hashlib.sha256(text.encode()).hexdigest() != patched:
        raise SystemExit('Lifecycle patch result did not match the reviewed hash.')
    mode = source.stat().st_mode
    source.chmod(mode | stat.S_IWUSR)
    try:
        source.write_text(text)
    finally:
        source.chmod(mode)
elif digest != patched:
    raise SystemExit('SwiftTerm source differs from the reviewed original and patch; refusing to overwrite it.')
print('SwiftTerm lifecycle compatibility patch verified.')
