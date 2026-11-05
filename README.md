# Lean Term

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="branding/approved/crt-family/lean-term/wordmark-on-dark@2x.png">
  <img alt="Lean Term" src="branding/approved/crt-family/lean-term/wordmark-on-light@2x.png" width="280">
</picture>

[![macOS CI](https://github.com/mattivilola/leanterm/actions/workflows/ci.yml/badge.svg)](https://github.com/mattivilola/leanterm/actions/workflows/ci.yml)

A small, native terminal for macOS. Built for responsive typing, a clean interface
and a little less distraction. Free and open source.

[Website](https://leanterm.com) · [Build](#build-and-run) · [Contributing](CONTRIBUTING.md) · [MIT license](LICENSE)

**Development preview · 0.1.0.** The first usable v1 is being built here. Build
from source; there is no signed, notarized public Lean Term download yet.

## What it does

- Runs your normal login shell, startup files and environment.
- Native macOS windows and tabs, with independent terminal sessions.
- Unicode text, terminal applications, selection, copy/paste and built-in Find.
- Bounded 10,000-line scrollback; clear history without sending input to a program.
- System/Light/Dark appearance, Forest and Graphite palettes, font size/family,
  cursor shape and optional Option-as-Meta, in a compact visual settings window.
- Confirms closing live sessions and waits for owned shell cleanup on quit.
- Remembers the last active window's position and size, fitting it to available displays.

Swift + AppKit + [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), explicitly
using CoreGraphics/CoreText. No web runtime or app-owned idle polling. The
[initial experiment](benchmarks/results/2026-11-04.md) informed this choice; it is
not a benchmark of this app version or proof of the fastest possible terminal.
Rust was not benchmarked and remains an option if profiling justifies it.

## Build and run

Requires **macOS 26+**, Xcode's **Swift 6.2+** toolchain, Python 3 and Git.
The first build downloads pinned package dependencies. No signing certificate,
API key or account is needed.

```sh
git clone https://github.com/mattivilola/leanterm.git
cd leanterm
./script/build_and_run.sh
```

The script builds Release, prepares a locally ad-hoc-signed `dist/Lean Term.app`,
and opens it. The app uses the account's login shell and starts at home.

```sh
./script/build_and_run.sh --build-only
./script/build_and_run.sh --verify
./script/build_and_run.sh run --working-directory /path/to/project
./script/build_and_run.sh --test
```

Quit the app first, then use these recovery options if needed:

```sh
./script/build_and_run.sh run --reset-window
./script/build_and_run.sh run --reset-settings
```

`--reset-window` restores the default window placement and size while keeping
visual preferences. `--reset-settings` restores both visual preferences and
window placement. Shell configuration and history are unaffected.

Quit the development app before replacing its bundle; the script never kills
active sessions. `--debug` opens LLDB. `--logs` streams process logs
(`--telemetry` is an alias, not an analytics service).

On hosts that prohibit nesting SwiftPM's macOS build sandbox, explicitly use
`SWIFTPM_DISABLE_SANDBOX=1 ./script/build_and_run.sh …`. Ordinary local builds
and CI use SwiftPM's default sandbox. This setting affects the build process,
not the terminal application's runtime permissions.

The script applies a small, hash-checked lifecycle compatibility patch to the
pinned SwiftTerm checkout. Supported builds go through the script;
[architecture notes](docs/ARCHITECTURE.md) explain the change and shutdown behavior.

## Shortcuts

| Action | Shortcut |
|---|---|
| New window / tab | ⌘N / ⌘T |
| Close session | ⌘W |
| Find / next / previous | ⌘F / ⌘G / ⇧⌘G |
| Copy / paste / select all | ⌘C / ⌘V / ⌘A |
| Clear scrollback, keeping the visible screen | ⌘K |
| Larger / smaller / default text | ⌘+ / ⌘− / ⌘0 |
| Next / previous tab | ⇧⌘] / ⇧⌘[ |
| Settings | ⌘, |

Settings apply to all sessions and save automatically in macOS preferences.
New tabs use the last reported local working directory. Without shell directory
reporting, that may remain the starting directory. No shell hooks are installed.

## Development and scope

Run the focused core tests with `./script/build_and_run.sh --test`.
An opt-in native integration check uses isolated settings and clean test shells:

```sh
./script/build_and_run.sh run --smoke-test /tmp/leanterm-smoke.json
```

The app exits after writing its result. This exercises actual PTY output,
CoreGraphics selection, Unicode/ANSI search, resize, appearance settings, native
tabs, normal exit and forced shutdown. It does not measure typing latency or
substitute for manual IME and accessibility checks.

Splits, editable TOML configuration, hot reload, shortcut editing, metrics and
session restoration are deferred. Keep additions focused and measure their cost.
The separate [benchmark fixture](benchmarks/README.md) and raw experiment data
remain available for reproducibility.

## Branding and license

The emerald CRT prompt is Lean Term's identity. The [brand assets](branding/README.md)
include macOS icons, light/dark wordmarks and web icons. Meet its companion code
editor at [leanvscode.com](https://leanvscode.com).

Original code and project artwork are [MIT licensed](LICENSE). Dependencies retain
their licenses; see [third-party notices](THIRD_PARTY_NOTICES.md).
Security reports: [SECURITY.md](SECURITY.md).
