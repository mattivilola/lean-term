# Architecture

Lean Term uses Swift and AppKit around SwiftTerm's existing local-process terminal
view. CoreGraphics/CoreText is explicitly selected. The app adds no renderer,
parser, PTY reader or input encoding layer. Appearance changes remain event-driven.

- `AppDelegate` owns menus, preferences, windows and aggregate quit coordination.
- `TerminalWindow` owns one SwiftTerm view and its shell. Native tabs group ordinary
  windows; each tab has an independent session and lifecycle.
- `SettingsWindow` applies small typed preferences to all sessions. macOS
  UserDefaults persists them under `com.mattivilola.leanterm` for this first version.
- `LeanTermCore` contains the testable preferences and login-shell launch values.

The last active terminal frame is saved on focus changes, the end of live resize,
close and quit. Relaunch fits that frame to an available screen, recovering a
disconnected display. Fullscreen transitions retain normal-window placement;
tab/session contents are not restored. `--reset-window` clears only saved window
geometry; `--reset-settings` also clears the app's visual preferences. Smoke mode
uses a separate preferences domain for both geometry and visual settings.

## Shells and shutdown

The account's login shell starts at home, or an explicitly supplied directory,
with its ordinary startup files. Account identity and terminal capabilities are
set explicitly; inherited PATH and locale are preserved. OSC 7 updates are used
only for existing local directories. No shell hooks are installed or commands
replayed. New sessions inherit the known directory, which may remain home if the
shell does not report directory changes.

Closing a live session asks for confirmation. The app sends HUP, keeps the view
alive, and uses one cancellable KILL fallback after 750 ms. SwiftTerm owns the
race-safe child signal, reap and output drain. App quit waits asynchronously for
all owned sessions; ordinary shell exit retains final output in its window.
Normal shell/PTY hangup semantics apply to descendants. This is not a process-tree
manager and does not promise to stop deliberately detached jobs.

## Pinned compatibility patch

SwiftTerm is pinned to `309adcc28bdf0e01f6403d04616323b379fb5635`. Its public
`terminate()` supports TERM only, while its private reaper already protects signals
against PID reuse. `script/prepare_dependency.py` makes three small changes:

1. Expose `terminate(signal: Int32 = SIGTERM)`.
2. Permit a later signal while the session is already terminating.
3. Forward the requested signal to that existing safe reaper.

The renderer, parser and I/O pipeline are unchanged. The script verifies the
revision and exact original or patched source SHA-256, refuses any other contents,
and changes only the task-owned SwiftPM checkout. Synchronous main-actor startup
finishes before the app requests shutdown; concurrent startup/shutdown would need
an additional upstream pending-signal change. Keep this patch small and review it
when updating the dependency. Upstream's license is retained in
[third-party notices](../THIRD_PARTY_NOTICES.md).

## Scope

This first usable v1 includes local shells, native windows/tabs, Find, bounded
scrollback, copy/paste, font/palette/cursor settings and System/Light/Dark following.
Splits, editable TOML configuration, hot reload, metrics,
restoration and startup commands remain roadmap items. No telemetry, AI service,
web runtime or plugin system is added.

## Shortcuts and updates

A typed shortcut map drives the menus and the reference/editor window. The
recorder consumes key events only while active, checks existing bindings through
an inert native menu, and saves overrides in UserDefaults. Fixed native editing
and alternate tab shortcuts remain available.

Sparkle 2.10.1 owns release update scheduling, signed-feed/archive verification,
downloading and installation. Development and smoke builds do not start it.
Sparkle's quit request passes through the same asynchronous session confirmation
and cleanup path as ordinary quit. Private signing keys stay in Keychain; release
scripts publish only verified, signed and notarized artifacts.

## Resource footer and session exit preferences (0.1.3)

One app-owned process sampler reads this GUI process’s CPU counters and physical
footprint once per second while a terminal is visible. It stops when disabled,
all terminals are hidden/occluded/minimized, or termination is pending. One-core
CPU percentages use Mach ticks for both CPU and elapsed time; child processes
are excluded. Footer views render only their own small, unanimated 60-sample
sparklines, with zero-based scales and gaps across pauses.

Close-on-shell-exit and quit-after-last-session are independent opt-in settings;
missing values retain the existing keep-open behavior. Launch failures remain
visible. Sessions are registered before starting the shell. Natural exit closes
a configured tab only after reap/output drain, while an outstanding confirmation
sheet keeps its window. Cancel retains output from a shell that finished during
the quit prompt. Last-session quit is queued once, rechecks for newly opened
sessions, and uses normal NSApplication termination so updater behavior is kept.

Cmd-K feeds local erase-display/cursor-home operations and discards normal
scrollback through SwiftTerm’s supported APIs. It never sends a key or command
to the child process, never resets terminal modes, and clears stale selection.
