#!/usr/bin/env python3
"""Deterministic PTY-intake benchmark; does NOT measure final screen painting.

Creates no user files outside the explicit output path. It remains alive after
the work so the GUI process can be sampled and inspected without a shell race.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys
import termios
import time
import tty

SIZE = 10 * 1024 * 1024


def payload(kind, size=SIZE):
    line = (b"LeanTerm benchmark 0123456789 abcdefghijklmnopqrstuvwxyz " * 2 + b"\r\n") if kind == "ascii" else (
        "\x1b[38;2;90;180;230mLeanTerm\x1b[0m café e\u0301 中文 日本語 🧑🏽‍💻 🇫🇮 0123456789\r\n".encode()
    )
    # Repeat whole lines; never cut a UTF-8 code point or escape sequence.
    return line * (size // len(line))


def emit(data):
    view = memoryview(data)
    while view:
        count = os.write(sys.stdout.fileno(), view)
        view = view[count:]


def save(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(data, indent=2) + "\n")
    temporary.replace(path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--delay", type=float, default=65)
    parser.add_argument("--hold", type=float, default=75)
    parser.add_argument("--gate", type=Path, help="Wait for this task-owned file before output; prevents idle/output overlap")
    parser.add_argument("--soak-seconds", type=float, default=0)
    args = parser.parse_args()
    # OPOST can change bytes and CPU cost. Use identical PTY mode in all apps.
    previous_mode = termios.tcgetattr(sys.stdout.fileno())
    import atexit
    atexit.register(termios.tcsetattr, sys.stdout.fileno(), termios.TCSANOW, previous_mode)
    tty.setraw(sys.stdout.fileno())
    size = os.get_terminal_size()
    data = {"child_pid": os.getpid(), "parent_pid": os.getppid(),
            "cols": size.columns, "rows": size.lines,
            "metric": "PTY writer completion, excludes final screen painting",
            "runs": [], "phase": "idle"}
    save(args.output, data)
    emit(b"\x1b[2J\x1b[HLEAN_TERM_READY\r\n")
    if args.gate:
        deadline = time.monotonic() + 300
        while not args.gate.exists():
            if time.monotonic() > deadline:
                raise TimeoutError("Workload start gate not opened within 5 minutes")
            time.sleep(0.1)
    time.sleep(args.delay)
    fixtures = {name: payload(name) for name in ("ascii", "mixed")}
    data["fixtures"] = {name: {"bytes": len(value), "sha256": hashlib.sha256(value).hexdigest()} for name, value in fixtures.items()}
    for repeat in range(3):
        for name in ("ascii", "mixed"):
            emit(b"\x1b[2J\x1b[H")
            start = time.perf_counter()
            emit(fixtures[name])
            elapsed = time.perf_counter() - start
            data["runs"].append({"fixture": name, "repeat": repeat + 1,
                                 "seconds": elapsed,
                                 "mib_per_second": len(fixtures[name]) / 1048576 / elapsed})
            data["phase"] = "output"
            save(args.output, data)
            emit(("\r\nLEAN_TERM_DONE " + name + "\r\n").encode())
            time.sleep(1)
    data["phase"] = "filled"
    save(args.output, data)
    emit("\r\nLEAN_TERM_COMPLETE — café é 中文 🧑🏽‍💻\r\n".encode())
    if args.soak_seconds > 0:
        data["phase"] = "soak"
        data["soak_seconds"] = args.soak_seconds
        data["soak_chunk_bytes"] = len(payload("mixed", 1024 * 1024))
        data["soak_interval_seconds"] = 2
        save(args.output, data)
        deadline = time.monotonic() + args.soak_seconds
        while time.monotonic() < deadline:
            emit(payload("mixed", 1024 * 1024))
            time.sleep(2)
        data["phase"] = "soak_complete"
        save(args.output, data)
        emit(b"\r\nLEAN_TERM_SOAK_COMPLETE\r\n")
    time.sleep(args.hold)


if __name__ == "__main__":
    main()
