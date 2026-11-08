# Changelog

## Unreleased

- Quick Terminal: ⌃⌥⌘T (configurable in Settings › General) slides a terminal down from the top of the screen over any app or Space; its shell keeps running while hidden.
- Command status (with shell integration): a green, red or amber bar beside each finished command (hover for the exit code, click to select its output), a red scanner pulse when a command fails, red finished-tab rings and "Failed (exit N)" notifications.
- New Find bar: searches the whole scrollback with match-case and regular-expression options, shows "3 of 17", highlights every visible match and selects the current one.
- Rearrange split panes: drag the grip on a pane's top edge to dock it beside another pane or swap them, or use Move Pane (⌃⌥⌘arrows).
- Configurable scrollback in Settings › Terminal (1,000 to 100,000 lines), applied to open tabs immediately.
- Settings regrouped into Appearance, General, Terminal, Activity, Hosts and Updates pages.
- New Tab and New Window open in the current folder even while Lean Term is in the background.

## 0.5.2 — Path hover hints

- Holding ⌘ over a clickable path shows an animated phosphor highlight and a hint of what a click will do.
- New tabs keep their intended working directory while the shell starts.

## 0.5.1 — Split panes and command palette

- Split panes: Terminal › Split Right (⌘D) and Split Down (⇧⌘D), ⌥⌘arrows to move between panes, ⇧⌘↩ to zoom one and ⌃⌘= to equalise; ⌘W closes the focused pane, and inactive panes dim slightly (Settings › Appearance).
- Reopen windows and tabs on launch now also restores each tab's split layout and focused pane.
- Command palette (⇧⌘P): fuzzy-search every menu command and open tab.

## 0.5.0 — Mac integration and prompt navigation

- ⌘-click a path in terminal output to open it: files open in Lean VS Code at the clicked line (or the default or a chosen app, Settings › Behavior › Open files with); folders `cd` there at the prompt, ⌘⇧-click opens a new tab.
- Optional redacted copy: Edit › Remove Sensitive Data When Copying, and Copy Without Sensitive Data (⌥⌘C), mask passwords, keys, tokens, card numbers, IBANs, identity numbers and emails as `[REMOVED:…]`.
- Drop files or folders on a terminal to insert their escaped paths; Secure Keyboard Entry in the app menu; multi-line pastes into programs without bracketed paste ask first.
- Open folders, `.command`/`.tool` scripts and `ssh://` links in Lean Term; Finder services New Lean Term Tab/Window Here; Make Lean Term the Default Terminal in Settings.
- Faster, lighter idle: footer graphs drawn as layers and sampled every 5 s in the background; the updater starts after launch; saved tabs restore in stages without stealing focus.
- With shell integration (OSC 133, see docs/SHELL_INTEGRATION.md): Previous/Next Prompt (⌘↑/⌘↓) and Select Command Output (⇧⌘A).
- Developer: `benchmarks/perf_snapshot.py` short isolated perf snapshot.

## 0.4.0 — Tabs that remember

- Short folder names in tabs, full paths on hover, and Rename Tab in the toolbar and Window menu (⇧⌘R). A blank name returns to automatic labels.
- ⌘1–8 selects tabs directly; ⌘9 selects the last tab. All bindings remain configurable.
- New tabs inherit the local shell’s actual working directory, including shells without directory-reporting hooks.
- Optional Settings → Behavior → Reopen windows and tabs on launch preserves tab groups, order, selected tabs, folders and custom names across normal quit. Reopens fresh shells; commands and SSH connections are not replayed.
- Settings scroll on smaller displays. Missing saved folders fall back to home; reset settings clears the saved workspace.

## 0.3.0 — Session signals

- Remote tabs: ssh, autossh, mosh and Eternal Terminal sessions show an amber network mark and the remote host in the subtitle, without busy marks or sweeps while you type.
- Root sessions show an amber `#` mark beside the usual activity dot.
- Optional host colour rules (Settings › Hosts) tint matching remote tabs and add a steady line above the terminal.
- A bell in a tab you are not viewing shows an amber bell mark; the bell stays silent.
- Optional notifications for long commands that finish while you are elsewhere, plus a Dock badge for missed command completions and bells.
- OSC 9;4 progress bars use the brand phosphor colour.

## 0.2.0 — Command activity

- Optional running-command scanner above the terminal and tab marks for busy and finished long commands, with no idle polling and a render-server animation that pauses for hidden windows, Reduce Motion and Low Power Mode.
- Emerald CRT activity marks stay consistent across palettes; scanner sweeps resume when returning to a running tab.

## 0.1.3 — Native polish

- SF Mono Regular 13 becomes the default for new configurations; existing font choices remain.
- ⌘K clears both the visible screen and terminal scrollback, preserving input modes.
- Compact optional CPU and memory sparklines for Lean Term itself.
- Configurable automatic tab closing on shell exit and app quit after the last terminal closes.
- Compact Appearance, Behavior and Updates settings pages.
- Register sessions before starting their shells, including immediate-exit cases.

## 0.1.2 — First automatic update

- First maintenance release delivered through the built-in signed updater.
- Keeps the same native terminal behavior, branding and saved preferences.

## 0.1.1 — First public release

- Native Swift/AppKit terminal with SwiftTerm's CoreGraphics/CoreText renderer.
- Login shells, native tabs/windows, Find and bounded scrollback.
- Forest/Graphite palettes, System/Light/Dark appearance and visual font/cursor settings.
- Confirmed close/quit with asynchronous shell cleanup.
- Saved window position/size with display recovery and command-line reset options.
- Wrapping ⌘←/⌘→ tab navigation and an editable shortcut reference with conflict checks.
- Branded About window, emerald CRT icons and project credits.
- Developer ID signing, notarization, GitHub release commands and Sparkle update bootstrap.

The initial experiment describes an earlier fixture. This release makes no new
finished-app latency or fastest-terminal claims.
