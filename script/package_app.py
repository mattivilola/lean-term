#!/usr/bin/env python3
"""Stage a local app while protecting active terminal sessions with a file lock."""
from pathlib import Path
import fcntl
import base64
import os
import re
import plistlib
import shutil
import subprocess
import sys
import time

root = Path(__file__).resolve().parents[1]
product = sys.argv[1]
if product not in ('LeanTerm', 'LeanTermBench'):
    raise SystemExit('Unknown app product')
version = (root / 'VERSION').read_text().strip()
if not re.fullmatch(r'\d+\.\d+\.\d+', version):
    raise SystemExit('VERSION must contain a three-part numeric version.')
release_build = os.environ.get('LEANTERM_RELEASE_BUILD') == '1' and product == 'LeanTerm'
public_file = root / 'release/sparkle-public-key.txt'
public_key = public_file.read_text().strip() if public_file.exists() else ''
if public_key:
    if len(base64.b64decode(public_key, validate=True)) != 32:
        raise SystemExit('The Sparkle public key must be 32 bytes.')
if release_build and not public_key:
    raise SystemExit('A release needs release/sparkle-public-key.txt; see docs/RELEASING.md.')
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
        'CFBundleShortVersionString': version, 'CFBundleVersion': version,
        'CFBundleIconFile': 'LeanTerm.icns', 'CFBundlePackageType': 'APPL',
        'LSMinimumSystemVersion': '26.0', 'NSPrincipalClass': 'NSApplication',
        'NSHighResolutionCapable': True, 'LSApplicationCategoryType': 'public.app-category.developer-tools',
        'NSHumanReadableCopyright': 'Copyright © 2026 Lean Term contributors. MIT License.'
    }
    try:
        info['LeanTermSourceRevision'] = subprocess.check_output(
            ['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True, stderr=subprocess.DEVNULL).strip()
    except subprocess.CalledProcessError:
        info['LeanTermSourceRevision'] = 'unknown'
    if product == 'LeanTerm':
        frameworks = app / 'Contents/Frameworks'
        frameworks.mkdir(exist_ok=True)
        source = root / '.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework'
        target = frameworks / 'Sparkle.framework'
        if target.is_symlink():
            raise SystemExit('Unexpected framework symlink in build output; refusing to follow it.')
        if target.exists():
            shutil.rmtree(target)  # Only this task-owned, regenerated build artifact.
        shutil.copytree(source, target, symlinks=True)
        load_commands = subprocess.check_output(['otool', '-l', str(executable)], text=True)
        if '@executable_path/../Frameworks' not in load_commands:
            subprocess.run(['install_name_tool', '-add_rpath', '@executable_path/../Frameworks', str(executable)], check=True)
        shutil.copy2(root / 'release/SPARKLE-LICENSE.txt', resources / 'SPARKLE-LICENSE.txt')
        info.update({'LeanTermReleaseBuild': release_build,
                     'SUFeedURL': 'https://github.com/mattivilola/lean-term/releases/latest/download/appcast.xml',
                     'SUEnableAutomaticChecks': release_build,
                     'SUScheduledCheckInterval': 3600,
                     'SUScheduledImpatientCheckInterval': 7200,
                     'SUAutomaticallyUpdate': release_build,
                     'SUEnableSystemProfiling': False,
                     'SUVerifyUpdateBeforeExtraction': True,
                     'SURequireSignedFeed': True})
        if public_key:
            info['SUPublicEDKey'] = public_key
    with (app / 'Contents/Info.plist').open('wb') as output:
        plistlib.dump(info, output)
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
print(app)
