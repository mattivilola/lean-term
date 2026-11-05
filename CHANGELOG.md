# Changelog

## Unreleased

- Optional running-command scanner above the terminal and tab marks for busy and finished long commands, with no idle polling and a render-server animation that pauses for hidden windows, Reduce Motion and Low Power Mode.

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
