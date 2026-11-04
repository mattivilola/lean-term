#!/usr/bin/env python3
"""One gated output/idle-memory run. Launches only task-owned benchmark windows."""
import argparse
import ctypes
import json
import os
from pathlib import Path
import plistlib
import shlex
import signal
import struct
import subprocess
import sys
import time
import uuid

from sample_process import sample

ROOT = Path(__file__).resolve().parent.parent
LIB = ctypes.CDLL('/usr/lib/libproc.dylib')
SYSTEM = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
SYSTEM.mach_absolute_time.restype = ctypes.c_uint64


def process_path(pid):
    buf = ctypes.create_string_buffer(4096)
    LIB.proc_pidpath(pid, buf, len(buf))
    return buf.value.decode()


def existing_app_pids(expected):
    pids = (ctypes.c_int * 65536)()
    count = LIB.proc_listallpids(pids, ctypes.sizeof(pids))
    if count <= 0:
        raise RuntimeError('Cannot safely identify pre-existing app processes')
    return {pid for pid in pids[:count] if expected in process_path(pid)}


def find_app(pid, expected):
    for _ in range(8):
        if expected in process_path(pid):
            return pid
        buf = ctypes.create_string_buffer(256)
        if LIB.proc_pidinfo(pid, 13, 0, buf, len(buf)) <= 0:
            break
        _, pid = struct.unpack_from('II', buf.raw)
        if pid <= 1:
            break
    raise RuntimeError('Could not identify the GUI parent; refusing to sample a shell as app memory')


def wait_json(path, predicate=lambda _: True, seconds=120):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            data = json.loads(path.read_text())
            if predicate(data):
                return data
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        time.sleep(0.1)
    raise TimeoutError(f'No expected phase in {path.name}')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('renderer', choices=['cg', 'metal', 'ghostty', 'terminal'])
    parser.add_argument('--label', required=True)
    parser.add_argument('--soak-seconds', type=int, default=0)
    args = parser.parse_args()
    if not args.label.replace('-', '').replace('_', '').isalnum():
        parser.error('Use a simple label with letters, numbers, hyphens or underscores')
    prefix = ROOT / 'benchmarks/results' / args.label
    if prefix.with_name(prefix.name + '-output.json').exists():
        raise FileExistsError('Keep previous readings; use a new label')
    local = ROOT / '.cache' / ('output-' + uuid.uuid4().hex[:8])
    local.mkdir(parents=True)
    output, info, gate = local / 'workload.json', local / 'info.json', local / 'start'
    command = ['/usr/bin/python3', str(ROOT / 'benchmarks/terminal_workload.py'),
               '--output', str(output), '--gate', str(gate), '--delay', '0',
               '--soak-seconds', str(args.soak_seconds)]
    if args.renderer in ['cg', 'metal']:
        app = ROOT / 'dist/LeanTermBench.app'
        launch = ['/usr/bin/open', '-n', str(app), '--args', '--renderer', args.renderer,
                  '--info', str(info), '--workload', command[1], *command[2:]]
        expected = '/LeanTermBench.app/Contents/MacOS/LeanTermBench'
    elif args.renderer == 'ghostty':
        config = ROOT / '.cache/ghostty-benchmark.conf'
        launch = ['/usr/bin/open', '-n', '/Applications/Ghostty.app', '--args',
                  '--config-default-files=false', '--config-file=' + str(config), '-e', *command]
        expected = '/Ghostty.app/Contents/MacOS/'
    else:
        profile = plistlib.loads((ROOT / 'benchmarks/terminal-profile.terminal').read_bytes())
        profile['name'] = 'LeanTerm output benchmark (temporary)'
        profile['CommandString'] = shlex.join(command)
        profile_path = local / 'Output.terminal'
        profile_path.write_bytes(plistlib.dumps(profile))
        launch = ['/usr/bin/open', '-n', '-a', '/System/Applications/Utilities/Terminal.app', str(profile_path)]
        expected = '/Terminal.app/Contents/MacOS/Terminal'
    existing = existing_app_pids(expected)
    before_launch = SYSTEM.mach_absolute_time()
    # open can wait for an app to acknowledge activation; readiness comes from
    # the task workload, not from the launcher's return time.
    log = (local / 'launch.log').open('w')
    launcher = subprocess.Popen(launch, stdout=log, stderr=log)
    ready = wait_json(output)
    pid = (wait_json(info)['pid'] if info.exists() else find_app(ready['parent_pid'], expected))
    if expected not in process_path(pid):
        raise RuntimeError('GUI process identity changed')
    time.sleep(5)
    identity = sample(pid)['process_start_mach_ticks']
    fresh = pid not in existing and identity >= before_launch
    print(f'{args.label}: GUI pid {pid}, {ready["cols"]}x{ready["rows"]}; sampling idle for 60s', flush=True)
    subprocess.run([sys.executable, str(ROOT / 'benchmarks/sample_process.py'), str(pid),
                    '--seconds', '60', '--output', str(prefix) + '-idle.json'], check=True)
    gate.touch()
    result = wait_json(output, lambda d: d['phase'] in ['filled', 'soak', 'soak_complete'])
    time.sleep(2)
    filled = sample(pid)
    if args.soak_seconds:
        subprocess.run([sys.executable, str(ROOT / 'benchmarks/sample_process.py'), str(pid),
                        '--seconds', str(args.soak_seconds), '--output', str(prefix) + '-soak.json'], check=True)
        result = wait_json(output, lambda d: d['phase'] == 'soak_complete')
    result.update({'gui_pid': pid, 'fresh_gui_process': fresh, 'filled_snapshot': filled,
                   'label': args.label, 'app': args.renderer,
                   'viewport_matches': ready['cols'] == 120 and ready['rows'] == 40,
                   'scrollback': '16 MiB byte cap' if args.renderer == 'ghostty' else '10,000 lines configured'})
    Path(str(prefix) + '-output.json').write_text(json.dumps(result, indent=2) + '\n')
    if info.exists():
        Path(str(prefix) + '-info.json').write_text(info.read_text())
    print(f'{args.label}: saved output and footprint readings', flush=True)
    # Never terminate a reused reference app that might contain other user work.
    if fresh and expected in process_path(pid) and sample(pid)['process_start_mach_ticks'] == identity:
        os.kill(pid, signal.SIGTERM)
    if launcher.poll() is None:
        launcher.terminate()  # only our /usr/bin/open helper, not a user app


if __name__ == '__main__':
    main()
