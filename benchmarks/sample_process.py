#!/usr/bin/env python3
"""Read macOS app footprint/RSS/CPU without sampling shell children as app RAM."""
import argparse
import ctypes
import json
from pathlib import Path
import time


class Usage(ctypes.Structure):
    # rusage_info_v2, macOS SDK sys/resource.h.
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in (
        "user_time", "system_time", "pkg_idle_wkups", "interrupt_wkups", "pageins",
        "wired_size", "resident_size", "phys_footprint", "proc_start_abstime",
        "proc_exit_abstime", "child_user_time", "child_system_time", "child_pkg_idle_wkups",
        "child_interrupt_wkups", "child_pageins", "child_elapsed_abstime",
        "diskio_bytesread", "diskio_byteswritten")]


class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


TIMEBASE = Timebase()
if ctypes.CDLL("/usr/lib/libSystem.B.dylib").mach_timebase_info(ctypes.byref(TIMEBASE)) != 0:
    raise RuntimeError("mach_timebase_info failed")


def sample(pid):
    usage = Usage()
    library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    if library.proc_pid_rusage(pid, 2, ctypes.byref(usage)) != 0:
        raise OSError(ctypes.get_errno(), "proc_pid_rusage failed")
    return {"time": time.monotonic(), "footprint_bytes": usage.phys_footprint,
            "rss_bytes": usage.resident_size,
            "process_start_mach_ticks": usage.proc_start_abstime,
            "cpu_mach_ticks": usage.user_time + usage.system_time,
            "idle_wakeups": usage.pkg_idle_wkups,
            "interrupt_wakeups": usage.interrupt_wkups}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("pid", type=int)
    parser.add_argument("--seconds", type=float, default=60)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    readings = [sample(args.pid)]
    deadline = time.monotonic() + args.seconds
    while time.monotonic() < deadline:
        time.sleep(min(1, max(0, deadline - time.monotonic())))
        readings.append(sample(args.pid))
    elapsed = readings[-1]["time"] - readings[0]["time"]
    if any(row["process_start_mach_ticks"] != readings[0]["process_start_mach_ticks"] for row in readings):
        raise RuntimeError("Process identity changed during sampling; readings are invalid")
    # rusage_info uses Mach absolute-time units, not nanoseconds on Apple Silicon.
    ticks = readings[-1]["cpu_mach_ticks"] - readings[0]["cpu_mach_ticks"]
    cpu_seconds = ticks * TIMEBASE.numer / TIMEBASE.denom / 1e9
    result = {"pid": args.pid, "seconds": elapsed, "cpu_percent_one_core": cpu_seconds / elapsed * 100,
              "timebase": {"numer": TIMEBASE.numer, "denom": TIMEBASE.denom},
              "readings": readings}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({key: value for key, value in result.items() if key != "readings"}), flush=True)


if __name__ == "__main__":
    main()
