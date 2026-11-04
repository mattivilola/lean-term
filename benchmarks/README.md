# Small macOS terminal experiment

Build with `../script/build_and_run.sh` from the repository root. The app uses
SwiftTerm's existing `LocalProcessTerminalView`, Menlo 13, 120 × 40 cells,
10,000 scrollback lines and an opaque background. Select `--renderer metal`
or `--renderer cg`. `--info /absolute/path.json` records the active renderer,
actual dimensions, display Hz and scale.

The benchmark app delegates normal input, PTY handling and drawing to SwiftTerm.
It does not contain a custom terminal emulator or renderer.

## Output and memory

Inside a task-owned terminal window, run:

```sh
/usr/bin/python3 /absolute/path/to/leanterm/benchmarks/terminal_workload.py \
  --output /tmp/leanterm-output.json --gate /tmp/leanterm-start-unique --delay 0
```

Use a fresh nonexistent gate path for each run. The workload prints
`LEAN_TERM_READY` and waits. In another shell, sample the GUI app PID (not the
child shell or Python process), then open the gate:

```sh
python3 benchmarks/sample_process.py APP_PID --seconds 60 --output /tmp/leanterm-idle.json
touch /tmp/leanterm-start-unique
```

It emits identical ASCII and ANSI/Unicode payloads of approximately 10 MiB each,
three times each, then prints `LEAN_TERM_COMPLETE` and waits for 75 seconds.
Observe the final marker and sample filled-scrollback memory during that wait.
`parent_pid` in the workload data identifies the launching parent, which may be
a shell; use the benchmark app's `--info` file to identify its GUI PID.

The recorded throughput is **writer completion through a real PTY**. Rendering
can finish later and intermediate frames may be coalesced. Report fixture hashes
and viewport/scrollback differences. Compare physical footprint with physical
footprint; RSS is recorded separately. CPU counters are Mach ticks, converted
using this machine's `mach_timebase_info` before calculating percent of one core.

## Typing latency

Use the official [Typometer 1.0.1](https://github.com/pavelfatin/typometer/releases/tag/v1.0.1)
with a short validated preflight before the tool's default 200-sample runs.
Repeat each candidate in reverse order if the first comparison informs a decision.
macOS may require
screen/input permissions and a restart. Permission-interrupted runs are invalid.

On the installed Java 21 runtime, this older tool needs
`--add-opens=java.desktop/java.awt=ALL-UNNAMED` to start. A temporary `jpackage`
app wrapper allows a stable macOS app identity for permissions and desktop
control. The downloaded tool/runtime and wrapper are ignored build artifacts.
Do not commit them or modify the bundle between permission approval and testing.

Keep the shell echo context and display settings the same. Typometer measures
synthetic input to screen-capture detection, not physical key-to-photon latency.
Save raw CSV samples and report median/p95. A failed or permission-blocked run
does not establish a latency result.

```sh
python3 benchmarks/summarize_latency.py benchmarks/results/latency.csv
```

On this Mac, starting Typometer through accessibility actions has not reliably
triggered its window-focus listener. A manual click on Benchmark followed by a
click inside the target terminal has collected complete runs. The repeats use
the tool's default 200 samples. Keep raw columns and explicit run labels; an
untitled row must be mapped from the recorded run order rather than guessed.

## Gated output runs

After building the fixture, `run_output.py` automates one bounded run in a new
task-owned window. It takes a 60-second idle sample before opening the output
gate, which prevents idle/output overlap. Labels must be unique so previous raw
readings are preserved.

```sh
python3 benchmarks/run_output.py cg --label cg-gated
python3 benchmarks/run_output.py metal --label metal-gated
```

Run these in a desktop-capable execution context, sequentially. Reference modes
`ghostty` and `terminal` reuse the same workload; Ghostty expects the isolated
configuration at `.cache/ghostty-benchmark.conf`. Terminal uses the task profile
in this directory and leaves the default profile unchanged. Record Ghostty's
byte-based scrollback cap separately from the candidates' line cap. A reused
reference process is identified and is never terminated by the helper.

## Safety and scope

Use task-owned windows and isolated reference configs. Do not close other user
terminals, change personal profiles, or publish machine serials, private window
contents or credentials. Preserve raw failures and identify invalid intervals.
No live AI request or paid API call is needed.
