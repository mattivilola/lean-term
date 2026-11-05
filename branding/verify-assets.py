#!/usr/bin/env python3
"""Verify the checked-in brand exports without installing image tooling."""
from pathlib import Path
import hashlib
import json
import struct
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parent
manifest = json.loads((root / 'manifest.json').read_text())
for relative, expected in manifest['files'].items():
    path = root / relative
    data = path.read_bytes()
    assert len(data) == expected['bytes'], relative
    assert hashlib.sha256(data).hexdigest() == expected['sha256'], relative
    if path.suffix == '.svg':
        ET.fromstring(data)
    elif path.suffix == '.png':
        assert data[:8] == b'\x89PNG\r\n\x1a\n', relative
        assert all(struct.unpack('>II', data[16:24])), relative
    elif path.suffix == '.icns':
        assert data[:4] == b'icns' and struct.unpack('>I', data[4:8])[0] == len(data), relative
print(f'Verified {len(manifest["files"])} Lean Term assets.')
