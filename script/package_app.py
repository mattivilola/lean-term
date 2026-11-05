#!/usr/bin/env python3
"""Stage a local app while protecting active terminal sessions with a file lock."""
from pathlib import Path
import fcntl
import plistlib
import shutil
import subprocess
import sys
import time

root = Path(__file__).resolve().parents[1]
product = sys.argv[1]
if product not in ('LeanTerm', 'LeanTermBench'):
    raise SystemExit('Unknown app product')
name = 'Lean Term' if product == 'LeanTerm' else 'LeanTerm Bench'
app = root / 'dist' / ('Lean Term.app' if product == 'LeanTerm' else 'LeanTermBench.app')
resources = app / 'Contents/Resources'
resources.mkdir(parents=True, exist_ok=True)
# App instances hold a shared lock for their lifetime. Packaging requires exclusive
# access, without process enumeration, PID races or terminating anyone's shell.
with (resources / 'Build.lock').open('a+b') as lock:
    if '--running' in sys.argv:
        for _ in range(30):
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                fcntl.flock(lock, fcntl.LOCK_UN)
            except BlockingIOError:
                print(f'{name} is running.')
                raise SystemExit(0)
            time.sleep(0.1)
        raise SystemExit('The app did not stay running after launch.')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise SystemExit(f'{name} is running. Quit it when ready before replacing its development bundle.')
    executable = app / 'Contents/MacOS' / product
    executable.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(root / '.build/release' / product, executable)
    shutil.copy2(root / 'branding/approved/crt-family/lean-term/LeanTerm.icns', resources / 'LeanTerm.icns')
    shutil.copy2(root / 'LICENSE', resources / 'LICENSE.txt')
    shutil.copy2(root / 'THIRD_PARTY_NOTICES.md', resources / 'THIRD_PARTY_NOTICES.txt')
    identifier = 'com.mattivilola.leanterm' + ('.bench' if product == 'LeanTermBench' else '')
    info = {
        'CFBundleExecutable': product, 'CFBundleIdentifier': identifier,
        'CFBundleName': name, 'CFBundleDisplayName': name,
        'CFBundleShortVersionString': '0.1.0', 'CFBundleVersion': '1',
        'CFBundleIconFile': 'LeanTerm.icns', 'CFBundlePackageType': 'APPL',
        'LSMinimumSystemVersion': '26.0', 'NSPrincipalClass': 'NSApplication',
        'NSHighResolutionCapable': True, 'LSApplicationCategoryType': 'public.app-category.developer-tools',
        'NSHumanReadableCopyright': 'Copyright © 2026 Lean Term contributors. MIT License.'
    }
    with (app / 'Contents/Info.plist').open('wb') as output:
        plistlib.dump(info, output)
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
print(app)
