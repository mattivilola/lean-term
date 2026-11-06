#!/usr/bin/env python3
"""Short, automatic perf snapshot: warm launch plus idle footprint/CPU/wakeups (1 and 3 tabs).

Launches the given app bundle in an isolated benchmark session and only signals PIDs it started.
"""
import argparse
import glob
import json
import os
import platform
import plistlib
import signal
import statistics
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from sample_process import TIMEBASE, sample  # noqa: E402

LAUNCH_TRIALS, SETTLE_SECONDS, IDLE_SECONDS = 3, 5, 10
MIB = 1024 * 1024


def build_observer(directory):
    binary = directory / "window-launch"
    subprocess.run(["swiftc", "-O", str(HERE / "window_launch.swift"), "-o", str(binary)], check=True)
    return binary


def launch(observer, app, directory, label, tabs):
    result = directory / f"launch-{label}.json"
    result.unlink(missing_ok=True)  # the observer refuses to overwrite
    subprocess.run([observer, result, tempfile.gettempdir(), app, "--", "--benchmark-session",
                    "--benchmark-tabs", str(tabs), "-fontName", "Menlo"],
                   check=True, stdout=subprocess.DEVNULL)
    return json.loads(result.read_text())


def quit_app(pid):
    os.kill(pid, signal.SIGTERM)
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return
        time.sleep(0.1)
    os.kill(pid, signal.SIGKILL)
    raise RuntimeError(f"pid {pid} did not exit within 10 s of SIGTERM")


def idle_trial(observer, app, directory, tabs):
    pid = launch(observer, app, directory, f"idle-{tabs}tab", tabs)["pid"]
    try:
        time.sleep(SETTLE_SECONDS)
        readings = []
        for _ in range(IDLE_SECONDS + 1):
            readings.append(sample(pid))
            time.sleep(1)
    finally:
        quit_app(pid)
    steps = list(zip(readings, readings[1:]))
    cpu = [(b["cpu_mach_ticks"] - a["cpu_mach_ticks"]) * TIMEBASE.numer / TIMEBASE.denom / 1e9
           / (b["time"] - a["time"]) * 100 for a, b in steps]
    wakeups = [(b["interrupt_wakeups"] - a["interrupt_wakeups"]) / (b["time"] - a["time"]) for a, b in steps]
    return {"readings": readings, "summary": {
        "footprint_mib": statistics.median(r["footprint_bytes"] for r in readings) / MIB,
        "rss_mib": statistics.median(r["rss_bytes"] for r in readings) / MIB,
        "cpu_percent_one_core": statistics.median(cpu), "wakeups_per_second": statistics.median(wakeups)}}


def git_sha():
    out = subprocess.run(["git", "-C", str(HERE), "rev-parse", "--short", "HEAD"], capture_output=True, text=True)
    return out.stdout.strip() or None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    app, out = args.app.resolve(), args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    version = plistlib.loads((app / "Contents/Info.plist").read_bytes()).get("CFBundleShortVersionString")
    observer = build_observer(out)

    launches = []
    for trial in range(LAUNCH_TRIALS):
        run = launch(observer, app, out, f"trial-{trial + 1}", 1)
        quit_app(run["pid"])
        launches.append(run["seconds"])
    idle = {tabs: idle_trial(observer, app, out, tabs) for tabs in (1, 3)}

    leftovers = []
    for path in sorted(glob.glob(os.path.expanduser("~/Library/Preferences/LeanTerm.Bench.*.plist"))):
        if plistlib.loads(Path(path).read_bytes()):
            leftovers.append(path)
        else:
            os.unlink(path)  # removePersistentDomain leaves an empty shell file behind
    if leftovers:
        print("WARNING: isolated benchmark preferences left behind:\n" + "\n".join(leftovers), file=sys.stderr)

    launch_median = statistics.median(launches)
    (out / "perf-snapshot.json").write_text(json.dumps({
        "app": str(app), "app_version": version, "git_sha": git_sha(), "macos": platform.mac_ver()[0],
        "timestamp": datetime.now(timezone.utc).isoformat(), "launch_seconds": launches,
        "launch_median_seconds": launch_median, "idle": {f"{k}_tab": v for k, v in idle.items()},
        "leftover_preferences": leftovers}, indent=2) + "\n")

    rows = [("Warm launch to first window (median)", f"{launch_median:.3f} s ({', '.join(f'{s:.3f}' for s in launches)})")]
    for tabs, label in ((1, "1 tab idle"), (3, "3 tabs idle")):
        s = idle[tabs]["summary"]
        rows.append((label, f"{s['footprint_mib']:.1f} MiB footprint / {s['cpu_percent_one_core']:.2f}% CPU / "
                            f"{s['wakeups_per_second']:.1f} wakeups/s"))
    print("| Check | Value |\n| --- | --- |")
    for name, value in rows:
        print(f"| {name} | {value} |")


if __name__ == "__main__":
    main()
