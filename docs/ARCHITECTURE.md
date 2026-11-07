# Architecture

## Tab names, directories and workspace reopening (0.4.0)

Tab labels use the local folder basename (or remote host) independently of
shell-supplied window titles. Custom names are trimmed and bounded. The native
tab tooltip retains the full path. Numbered shortcuts and Rename Tab use the
same configurable menu-binding system as other commands.

The local shell PID's `PROC_PIDVNODEPATHINFO` cwd is refreshed after PTY activity,
on focus and before creating/saving a tab. No shell hook or new idle timer is
needed. Remote OSC directory reports remain display metadata, never a local
directory for a new shell.

Optional workspace reopening stores one versioned, bounded UserDefaults value:
ordered window groups, ordered local folders/custom names, selected tabs and
the active group. Format version 2 adds each tab's split layout (`SavedPaneLayout`:
the pane tree with axes, divider ratios and a folder per leaf, plus the focused
pane's index); `SessionTab.directory` stays the focused pane's folder. Version 1
workspaces still load as single panes, and a missing or corrupt layout falls back
to one pane in `directory`. At most 16 panes per tab are restored. Confirmed quit saves it before shell shutdown removes windows;
Cancel leaves it alone. Empty workspaces clear the value, so manually closed
tabs are not resurrected. Disabling restoration or resetting settings clears it.
Launch restores fresh shells with explicit native tab grouping; missing folders
fall back to home. Each tab's split tree is rebuilt in the same step that creates
the tab (`TerminalWindow.restore(layout:focused:)`, reusing the normal pane
creation), the saved pane takes first responder without making the window key, and
divider ratios are applied again on the next run-loop turn once layout has settled. Existing last-window geometry is reused; commands, output,
remote connections and per-group geometry are not serialized.

Lean Term uses Swift and AppKit around SwiftTerm's existing local-process terminal
view. CoreGraphics/CoreText is explicitly selected. The app adds no renderer,
parser, PTY reader or input encoding layer. Appearance changes remain event-driven.

- `AppDelegate` owns menus, preferences, windows and aggregate quit coordination.
- `TerminalPane` owns one shell session: its SwiftTerm view, process lifecycle,
  activity tracking, working directory and per-session preferences and theme. It
  reports window-level effects (title, status, tab mark, closing) through
  `TerminalPaneHost`.
- `TerminalWindow` is the window controller of one native tab. It owns the window,
  footer, toolbar, tab mark and close confirmation, hosts a collection of panes
  (currently always one) and aggregates their state: the focused pane supplies
  title, subtitle and session mark, any pane can mark the tab busy or unseen.
  Native tabs group ordinary windows; each tab has an independent lifecycle.
- `SettingsWindow` applies small typed preferences to all sessions. macOS
  UserDefaults persists them under `com.mattivilola.leanterm` for this first version.
- `LeanTermCore` contains the testable preferences and login-shell launch values.

The last active terminal frame is saved on focus changes, the end of live resize,
close and quit. Relaunch fits that frame to an available screen, recovering a
disconnected display. Fullscreen transitions retain normal-window placement;
tab/session contents are not restored. `--reset-window` clears only saved window
geometry; `--reset-settings` also clears the app's visual preferences. Smoke mode
uses a separate preferences domain for both geometry and visual settings.

## Input conveniences

Dropping files or text onto a terminal inserts shell-escaped paths (`ShellEscape`,
as Terminal.app does) or the text through SwiftTerm's `pasteText`, so bracketed
paste is honoured and no Enter is ever sent. Secure Keyboard Entry (App menu,
off by default) holds a Carbon secure-event-input request only while the app is
active, tracked by one Bool so enable/disable stay balanced and release on quit.

`LeanTerminalView` overrides SwiftTerm's `paste(_:)`, the single entry point for
⌘V and Edit › Paste. A multi-line clipboard sent to a program that has not enabled
bracketed paste first shows a sheet with a short preview; "Don't ask again" and
Settings › Terminal turn `confirmMultilinePaste` off. Other pastes are untouched.

## Redacted copy

Opt-in (`redactCopies`, off by default, Edit menu and Settings › Terminal) because it silently changes copied
text. `LeanTerminalView` overrides `copy(_:)`: with the preference on, the selection from SwiftTerm's
`getSelection()` goes through `SensitiveDataRedactor.redact` (Core, pure) in a detached task, and the result is
written to the general pasteboard as plain text back on the main actor; a copy requested while one is running is
ignored. Edit › Copy Without Sensitive Data (⌥⌘C, in the shortcut map) always redacts. When items were removed the
window footer shows "Copied · n sensitive items removed" for 3 s, then restores the previous status text unless
it changed meanwhile.

## Clickable paths

⌘-click opens paths in visible output. Detection is click-time only: `LeanTerminalView.mouseUp` reads the clicked
row through SwiftTerm's `visibleRowsText`, maps the column to a character (wide characters count two columns) and
`PathDetection` (Core, pure text) extracts the token with an optional `:line:col`, `(line,col)` or Python
`, line N` location. Only then does `FileOpener` expand `~`, resolve against the shell's real directory and check
the file system, also trying the path without a git `a/` or `b/` prefix. Nothing scans output or touches the file
system while idle; hovering with ⌘ held checks at most once per hovered token and shows the pointing-hand cursor
for existing paths. URLs and OSC 8 links stay with SwiftTerm; the release reaches SwiftTerm without ⌘ for handled
paths so its own cwd-relative opening stays out. Remote tabs are excluded (paths live on the other machine).

An existing path under a ⌘-held pointer also gets a phosphor highlight: `PathDetection.match` returns the token's
character range and `column(ofCharacterOffset:)` maps it back to terminal columns, so `PathHighlightView` (one
lazily created, mouse-transparent, never-drawing layer view above the terminal) covers exactly the token's cells on
the hovered row. Fade, underline growth, slide to the next token and the delayed action hint are Core Animation
transactions plus one cancellable work item; Reduce Motion keeps only fades. The highlight fades out when ⌘ is
released, the pointer leaves, on click, scroll, losing key status or the pane's coalesced output notification.

Files open with Settings › Terminal › "Open files with": Lean VS Code (default, `lean-code://file<path>:<line>:<col>`;
falls back to the default app when not installed), the default app, or a chosen app, stored as
`Preferences.fileOpener`. A folder types `cd -- <escaped path>` when a local shell is at its prompt and otherwise,
or with ⌘⇧, opens a new tab there.

## macOS integration

Open requests (`application(_:open:)`) turn folders into a tab at that folder, `.command`/`.tool`
scripts into a tab at their folder that types the escaped path plus `; exit` once the shell starts,
and `ssh://` links into a tab that types `ssh [-p port] [user@]host`. Links are parsed by the strict
`SSHLink` in Core; unvalidated text never reaches a command line. Opens delivered before launch
finishes are queued: a saved workspace is restored first and the opens join its active window; otherwise they replace the default window. The Info.plist (from
`script/package_app.py`) declares folder and shell-script document types at Alternate rank, the `ssh`
scheme, and two Finder services served by `ServicesProvider`. Lean Term never claims defaults itself;
the Settings button is the only place that requests them.

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

## Prompt navigation

Opt-in and shell-driven: Lean Term never injects hooks. When the shell emits OSC 133
(`docs/SHELL_INTEGRATION.md`), SwiftTerm stores zero-width prompt marks on buffer lines and tags
cells written after `C` as output. Terminal › Previous/Next Prompt (⌘↑/⌘↓) use SwiftTerm's public
`previousSemanticPromptRow()`/`nextSemanticPromptRow()` and `scrollTo(row:)`; past the last prompt the
view returns to the live bottom. Edit › Select Command Output (⇧⌘A) asks the view for one role byte
per buffer row (prompt, output, other) and `CommandOutputLocator` (Core, pure) picks the output rows of
the command at the viewport top, or the latest one at the live bottom. Scans run only when a command
is invoked or a menu is validated (`hasSemanticPrompts`, early exit), never per frame or on output.
The items are disabled without prompt marks and in the alternate screen. Those row-level helpers and
`selectBufferRows` are the only public API SwiftTerm lacked, so `script/prepare_dependency.py` adds
them to `MacTerminalView.swift` under the same exact-hash rules as the lifecycle patch.

## Pinned compatibility patch

SwiftTerm is pinned to `309adcc28bdf0e01f6403d04616323b379fb5635`. Its public
`terminate()` supports TERM only, while its private reaper already protects signals
against PID reuse. `script/prepare_dependency.py` makes three small lifecycle changes (plus the prompt helpers
described above):

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
footprint once per second while the app is active and a terminal is visible, and
every five seconds while the app is inactive but a terminal is still visible. It
stops when disabled, all terminals are hidden/occluded/minimized, or termination
is pending. One-core CPU percentages use Mach ticks for both CPU and elapsed
time; child processes are excluded. Footer sparklines are layer-backed views with
`CAShapeLayer`s (60-sample history, zero-based scales, gaps across pauses) that
rebuild only their paths on new values, and labels are assigned only when their
text changes.

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

## Activity scanner and tab marks

A foreground job is running when `tcgetpgrp` on the PTY returns a process group
other than the shell’s. Alternate-screen programs (vim, htop) show nothing. SwiftTerm’s
supported output hook, which runs on the parse thread, only bumps an atomic counter and
arms a flag; the first output after each sample hops once to the main thread to wake the
monitor. A pure model (`SessionActivityModel`) turns samples into idle, sweeping (output
within 5 s, after a 0.4 s reveal delay) or holding, and reports a long command (10 s or
more) that finished.

The monitor’s 0.5 s timer exists only while a job is running or output just changed, so an
all-idle app has no activity timer and no wakeups. The scanner is a 2 pt layer in the
padding above the terminal, never over it. Its sweep is one Core Animation animation
capped at 30 fps and rendered by the render server, so there is no per-frame main-thread
work. It is removed for hidden windows, and replaced by a static line under Reduce Motion
or Low Power Mode. The tab accessory shows a filled dot while busy and a ring when a long
command finished in a window you were not looking at, cleared when that window becomes key.
Both use the brand phosphor colour from the icon, whatever the palette. Each sample re-adds a
sweep that Core Animation dropped, so a tab that is selected again resumes animating.

Remote and root sessions are classified once per foreground job, not per tick: when the
foreground group changes, `ForegroundProcessReader` reads the leader’s name, effective uid
and (only for remote tools) argv through `sysctl`. `ssh`, `autossh`, `mosh-client` and `et`
make the session remote, and the ssh destination is parsed from argv for the tab tooltip and
subtitle. A remote session shows an amber `network` symbol and no busy dot or sweep, and polls
only while output changes, so typing over ssh does not animate; a root leader shows `number`
beside the normal dot. The remote working directory comes from OSC 7 with a non-local host and
only feeds the subtitle; it never changes the local directory or the represented URL. Limitation:
ssh started inside a local tmux or screen is not visible, since the foreground job is the multiplexer.

OSC 9;4 progress reports use SwiftTerm's own 3 pt bar at the top of the terminal; Lean Term
only tints it with the brand phosphor colour. SwiftTerm keeps the error and paused colours.

The bell is observed through SwiftTerm’s open `bell` hook (`LeanTerminalView`), coalesced to
one main-thread hop per burst. It stays silent and only puts an amber bell in the tab of a
session that is not being viewed, cleared when its window becomes key.

Notifications are opt-in (`notifyInBackground`, off by default). The permission is requested
only when the preference is turned on, and nothing touches the notification centre while it
is off or in smoke mode. A long command that finishes in a tab you are not viewing posts one
notification, replaced per tab and cleared when the tab is viewed or closed; clicking it
brings that tab forward. The Dock badge counts tabs with an unseen finished command or bell.

Host colour rules are stored as JSON in UserDefaults, none by default. Each is matched with
`fnmatch` (case-insensitive) against the remote host, OSC 7 host first, and colours the tab
symbol and draws a steady scanner line while the session is remote.

## Launch path

Sparkle's updater controller is created at launch so the menu item and settings exist, but the updater starts (and its first background check runs) once, five seconds after launch, or earlier if Check for Updates is chosen. Workspace restore opens every saved window with its selected tab immediately and adds the remaining tabs one per run-loop turn at their saved positions, starting each shell as its tab is created.

## Split panes

A tab (`TerminalWindow`) arranges its `TerminalPane`s with `PaneLayout`
(`LeanTermCore`), a pure, Codable binary tree: leaves are pane ids, splits have an
axis (`horizontal` = side by side, `vertical` = stacked), a divider ratio and two
children. Splitting, removing (the sibling takes the parent's place), neighbour
lookup by geometry in a unit square, equalising and ratio updates are value
operations on that tree.

The window renders the tree as nested thin `NSSplitView`s (`PaneSplitView`) whose
leaves are the panes' own views. A structural change rebuilds only the split views
and reparents the existing pane views; panes and their shells are never recreated.
Divider drags write their ratio back into the layout through
`NSSplitViewDelegate`, and the delegate keeps every pane at least about 20 columns
by 4 rows. The footer stays one per window and shows the focused pane's status and
size; title, subtitle, tab label and session mark follow the focused pane, while
the tab's busy, unseen and bell marks aggregate all panes.

The focused pane follows the window's first responder (observed once per window).
Inactive panes are drawn at 0.8 alpha when `dimInactivePanes` is on and the tab has
more than one visible pane. Zoom shows only the focused pane's view in the pane area
(the others keep running, detached from the view tree) and ends on split, close,
pane selection or a second toggle. Split Right and Split Down start the new shell in
the focused pane's current folder.

File › Close closes the focused pane when a tab has several (with a confirmation if
its shell is live) and otherwise the tab as before; the window's close button always
closes the whole tab. A pane whose shell exits closes itself under the close-on-exit
preference, and the last pane closes the tab. Workspace saving records each tab's
layout (shape, axes, ratios, every pane's folder, focused pane) so reopening on
launch restores the splits with fresh shells; zoom is not persisted.

## Command palette

Terminal › Command Palette… (⇧⌘P, in the shortcut map) opens `CommandPalette`, a borderless
`NSPanel` (menu-material `NSVisualEffectView`) attached as a child window near the top of the key
terminal window. It is built on open and released on close, so nothing runs while it is closed.
Entries are gathered at open time: every enabled, actionable item of `NSApp.mainMenu` (menus are
`update()`d first so validation applies; separators, hidden items, submenu parents, Services, Open Recent,
window-list items, Quit and the palette itself are skipped), plus a "Go to Tab: <label>" entry for each tab
of every terminal window. Running an entry closes the palette, makes the terminal window key again, then
invokes `NSApp.sendAction(item.action, to: item.target, from: item)` so first-responder actions reach the
focused pane. `CommandMatcher.score` (Core) is a case-insensitive subsequence match with bonuses for word
starts and consecutive characters; an empty query lists the last 8 run titles (memory only) and then menu order.

