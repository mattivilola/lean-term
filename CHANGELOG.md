# Changelog

## Unreleased

- Remote tabs: ssh, autossh, mosh and Eternal Terminal sessions show an amber network mark and the remote host in the subtitle, without busy marks or sweeps while you type.
- Root sessions show an amber `#` mark beside the usual activity dot.
- Optional host colour rules (Settings › Hosts) tint matching remote tabs and add a steady line above the terminal.
- A bell in a tab you are not viewing shows an amber bell mark; the bell stays silent.
- Optional notifications and Dock badge for long commands that finish, and bells, while you are elsewhere.
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
