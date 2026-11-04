# LeanTerm plan (v1 spec + engine study)

Draft 4 Nov 2026, rev. 2 (open source, macOS 26+) · status: for Matti's review · all numbers marked TARGET are goals, not measurements.

## 1. Summary
LeanTerm is a macOS-only, native terminal that does a few things perfectly: it is fast (latency, startup, memory), it follows macOS light/dark reliably, it clears scrollback in one keystroke without tricks, and everything (looks, shortcuts, startup tabs) is configurable from a simple GUI that writes a plain TOML file. It is part of the "Lean" family (leanvscode.com). LeanTerm is free and open source (MIT, see §7). Minimum OS: macOS 26 (Matti runs macOS 27).

Recommended stack: Swift + AppKit app shell, Metal renderer with a CoreText glyph atlas, and a terminal engine still to be chosen. The leading candidate is libghostty-vt (MIT, Zig/C API), with Rust `alacritty_terminal` second. The final choice depends on the engine study and the 1-week spike (see leanterm-plan.md §Engine study).

## 2. Goals and non-goals
Goals (v1): speed; easy visual config; reliable appearance following; in-app shortcut editor; inline system + own-process metrics; tabs + splits (2 vertical, 2 horizontal, 4-grid); reliable scrollback + clear; startup commands and tab restoration.

Non-goals (v1): Linux/Windows; AI features; built-in multiplexer/SSH manager; plugins/scripting; arbitrary nested splits; image protocols (later); ligatures (later, opt-in); sync/cloud settings.

## 3. v1 features and acceptance criteria
| # | Feature | Acceptance criteria |
|---|---|---|
| F1 | Speed | TARGET key-to-photon ≤ Terminal.app on the same Mac, measured with Typometer; TARGET cold start to usable prompt < 150 ms (Apple Silicon); TARGET idle RAM < 60 MB for 1 window/1 tab with 10k-line scrollback; TARGET 0% CPU when idle (no redraw without damage); `cat` of 100 MB file never freezes input |
| F2 | Visual config | GUI settings for font family (monospace list from CoreText), size, line height, fg/bg, selection fg/bg, cursor color/shape/blink, 16 ANSI colors, padding, opacity. Changes apply live < 100 ms and are saved to TOML; edits to TOML hot-reload |
| F3 | Theme following | Modes: System / Light / Dark. In System mode, toggling macOS appearance (incl. Auto at sunset) switches all windows within one frame, 100/100 times in a scripted test; works after sleep/wake and with the app in background |
| F4 | Shortcut editor | Table of actions; click to record a new chord; conflict detection with in-app bindings and warning on known macOS system shortcuts; reset to default per row / all; stored in TOML |
| F5 | Inline metrics | Optional status bar: system CPU %, RAM used/total, disk free (current volume), plus LeanTerm's own RSS and CPU %. Refresh every 2 s (configurable), sampling cost TARGET < 0.1% CPU; hidden = no sampling |
| F6 | Tabs + splits | Native macOS tabs; per-tab layouts: single, 2 vertical, 2 horizontal, 4-grid; keyboard focus movement; resizable dividers; closing a pane collapses layout predictably |
| F7 | Scrollback + clear | Configurable scrollback limit (lines or MB), hard memory cap; ⌘K clears screen + scrollback in one keystroke and the prompt stays intact (via OSC 133 prompt marks when shell integration is on; fallback: clear + send form feed); ⌘⇧K clears scrollback only; scroll position stable while output streams |
| F8 | Startup | Global "run on every launch" commands; "Restore tabs on launch" reopens each tab/pane in its last cwd (tracked via OSC 7); optional per-tab and per-folder startup commands; "Save current tabs as default" button |

## 4. Config schema example (~/.config/leanterm/config.toml)
```toml
[appearance]
mode = "system"            # system | light | dark
font_family = "JetBrains Mono"
font_size = 13
line_height = 1.15
padding = 6

[theme.light]
foreground = "#1d1f21"
background = "#ffffff"
selection_fg = "#000000"
selection_bg = "#b4d5fe"
cursor = "#1d1f21"

[theme.dark]
foreground = "#e6e6e6"
background = "#1a1b1e"
selection_fg = "#ffffff"
selection_bg = "#3a4a66"
cursor = "#e6e6e6"

[cursor]
shape = "block"            # block | bar | underline
blink = false

[scrollback]
lines = 10000
max_memory_mb = 64

[status_bar]
enabled = true
items = ["cpu", "ram", "disk", "app_mem", "app_cpu"]
interval_s = 2

[startup]
restore_tabs = true
commands = ["echo 'hello'"]

[[startup.folder]]
path = "~/code/leanvscode"
commands = ["git status"]

[keys]
"cmd+t" = "new_tab"
"cmd+d" = "split_vertical"
"cmd+k" = "clear_all"
```

## 5. Default shortcuts
| Action | Shortcut |
|---|---|
| New tab / close pane | ⌘T / ⌘W |
| Split vertical / horizontal | ⌘D / ⌘⇧D |
| 4-grid layout | ⌘⌥G |
| Move focus between panes | ⌘⌥ + arrows |
| Next / previous tab | ⌘⇧] / ⌘⇧[ |
| Clear screen + scrollback | ⌘K |
| Clear scrollback only | ⌘⇧K |
| Font bigger / smaller / reset | ⌘+ / ⌘− / ⌘0 |
| Toggle status bar | ⌘⌥M |
| Settings / shortcut editor | ⌘, |
| Find in scrollback | ⌘F |

## 6. Architecture
```
 ┌──────────────── LeanTerm.app (Swift, AppKit) ────────────────┐
 │ NSWindow (native tabbing) ── SplitLayout (1 | 2V | 2H | 4)   │
 │      │                                                        │
 │  TerminalView (NSView + CAMetalLayer) ×N panes               │
 │      │ keys/mouse → engine key encoder → PTY write           │
 │      ▼                                                        │
 │  Renderer (Metal): glyph atlas (CoreText) + dirty rows only, │
 │  paced by NSView.displayLink; draw immediately after keypress     │
 │      ▲ render state snapshot                                  │
 │  Engine (libghostty-vt via C API, pinned commit)             │
 │      ▲ bytes                                                  │
 │  PTY reader thread per pane (forkpty/posix_spawn, kqueue)    │
 │                                                               │
 │  Services: ConfigStore (TOML, file watcher) · Appearance     │
 │  observer (KVO effectiveAppearance) · Metrics sampler        │
 │  (host_statistics64, statfs, proc_pid_rusage) · Session      │
 │  store (tabs + cwd via OSC 7) · Shortcut registry            │
 └───────────────────────────────────────────────────────────────┘
```
Key implementation notes:
- Rendering: one CAMetalLayer per pane; instanced quads per cell; glyphs rasterized once by CoreText into an atlas; only rows the engine marks dirty are re-uploaded. No timer-driven redraw: idle = zero frames. Frame pacing uses `NSView.displayLink(target:selector:)` (macOS 14.0+, Apple docs). It is always available on the macOS 26 minimum, so there is no CVDisplayLink fallback.
- PTY: `forkpty` (or `posix_openpt` + `posix_spawn`) per pane; dedicated read thread; coalesce output until next frame.
- Theme: observe `NSApp.effectiveAppearance` via KVO and re-resolve colors on every change; also re-check on `NSWorkspace.didWakeNotification` (the case where others fail). Engine colors are swapped, not reloaded from disk.
- Metrics: `host_statistics64` (CPU ticks, VM stats), `sysctl hw.memsize`, `statfs` for disk, `proc_pid_rusage`/`task_info` for own RSS/CPU. All are cheap syscalls; sample on a 2 s timer only while visible.
- Shell integration: ship small zsh/bash/fish snippets emitting OSC 7 (cwd) and OSC 133 (prompt marks); optionally auto-inject the zsh snippet (opt-out setting). Enables tab restoration and clean clear.
- Config: TOML (Swift: TOMLKit or similar); GUI writes the same file; DispatchSource file watcher hot-reloads. Shortcuts live in `[keys]`.
- State restoration: own session JSON (tabs, layouts, cwd per pane), not NSWindow restoration alone, so startup commands can run per pane.
- Distribution (free, open source): Developer ID signing + notarization (Apple Developer Program: 99 USD per membership year, local pricing may vary), Sparkle 2 for updates, Homebrew cask, DMG on leanterm.com.

## 7. Stack recommendation and alternatives
Recommended (provisional, pending the spike): Swift/AppKit/Metal shell + libghostty-vt engine.
- Why: libghostty-vt is extracted from Ghostty's core, MIT, zero dependencies, SIMD-optimized parser, scrollback, reflow, key encoding and an incremental render-state API, on by default in JetBrains IDEs' reworked terminal from 2026.3 (JetBrains blog). It removes the hardest 40–60% (estimate) of the work: correct VT emulation.
- Caveat: its C API is explicitly unstable ("breaking changes are expected"); pin a commit and wrap it in one Swift module, as Paneflow does (pins exact Ghostty commit; raw C ABI isolated in one -sys crate).

Alternative A: Rust core with `alacritty_terminal` (Apache-2.0) + `vte` (Apache-2.0 OR MIT), exposed to Swift via a C FFI (cbindgen / swift-bridge). Mature crate; Zed's terminal depends on it (Zed pins its own fork, per its Cargo.toml); Matti likes Rust. Cost: a Rust↔Swift bridge and two toolchains.

Alternative B: all-Swift engine. Most native, but writing a correct VT emulator from scratch is the slowest path to quality.

Not recommended: Rust for the UI layer (winit/objc2 is where Rust terminals feel non-native, e.g. Rio's split/resize bugs), Electron/web (Hyper ~40 ms avg latency in beuke.org Typometer test).

Rust verdict: Rust is a good, safe choice for the engine, but it is not "faster" than Zig, C or Swift in any way users will feel. Runtime speed comes from architecture: damage-only rendering, a glyph atlas, a separate IO thread, and no idle frames. The fastest option to *ship* and run is libghostty (already tuned) under a native Swift shell; Rust (`alacritty_terminal`) is the fallback if the libghostty API churn becomes painful.

### License recommendation
MIT. It matches libghostty-vt (MIT) and SwiftTerm, and it is compatible with `alacritty_terminal` (Apache-2.0) and `vte` (Apache-2.0 OR MIT). It is the shortest permissive license, so it is the easiest for people to contribute to and reuse. Apache-2.0 is the alternative if an explicit patent grant matters (inference: for a solo terminal project this is low-risk either way).

## 8. Milestones (ESTIMATE: one experienced dev + AI coding agents, part-time-ish ~20 h/week would roughly double these)
| M | Scope | Est. full-time |
|---|---|---|
| M0 | Engine spike: both top candidates behind the same Swift/Metal shell, measured on Matti's Mac (see plan) | 1 week |
| M1 | Core terminal: PTY, input, selection/copy, scrollback, ⌘K clear, resize | 2 weeks |
| M2 | Tabs, splits (2V/2H/4), focus | 1 week |
| M3 | Config: TOML, settings GUI, themes, appearance following, hot reload | 1.5 weeks |
| M4 | Shortcut editor + status bar metrics | 1 week |
| M5 | Shell integration, session restore, startup commands | 1 week |
| M6 | Polish: IME, emoji, accessibility basics, perf pass, sign/notarize, Sparkle, cask | 1.5 weeks |
| | Total | ~9 weeks full-time (estimate) |

## 9. Risks
- Font rendering/ligatures: CoreText shaping per run is costly; v1 ships without ligatures (later, opt-in). Must match macOS font smoothing so text doesn't look "off".
- Unicode/emoji/IME: grapheme clusters, wide chars, and Japanese/Chinese IME (NSTextInputClient) are where terminals break. Ghostty's biggest leak came from grapheme-heavy scrollback (Claude Code); mitigate with a hard scrollback memory cap and a soak test feeding emoji-heavy output for hours.
- libghostty API churn: pin + wrap; keep the engine behind a protocol so `alacritty_terminal` can be swapped in.
- tmux/vim compatibility: rely on the engine's emulation; test tmux, vim/neovim, htop, less, Claude Code; correct TERM/terminfo.
- Accessibility: VoiceOver over a Metal view needs an NSAccessibility text model; v1 = basic (read current line/selection), full later.
- Sustainability: free and open source, built for Matti first; the only recurring cost is the Apple Developer Program fee.

## 10. Open decisions
1. Engine: pending the study and spike (libghostty-vt vs Rust `alacritty_terminal`).
2. Domain: leanterm.com confirmed?
3. Minimum OS: 26 or 27.
4. Ship ligatures and image protocols in v1.x or never?

## 11. Sources
- SwiftTerm PERFORMANCE.md (parser-bound, ARC overhead): https://github.com/migueldeicaza/SwiftTerm/blob/main/PERFORMANCE.md
- Rio adaptive-theme bugs: https://github.com/raphamorim/rio/issues/660 · https://github.com/raphamorim/rio/commit/b8a4e9c55193570aaae688ac9b791331fd47ecc8
- NSGlassEffectView (WWDC25 AppKit): https://developer.apple.com/videos/play/wwdc2025/310/ · Ghostty glass PRs: https://github.com/ghostty-org/ghostty/pull/8801 · https://github.com/ghostty-org/ghostty/pull/10046
- libghostty-vt C header (unstable API warning, feature list): https://github.com/ghostty-org/ghostty/blob/main/include/ghostty/vt.h
- Ghostling (minimal libghostty terminal, MIT): https://github.com/ghostty-org/ghostling
- Ghostty README (architecture: read/write/render threads, Metal + CoreText, SIMD parser): https://github.com/ghostty-org/ghostty
- JetBrains terminal on libghostty (2026.3): https://blog.jetbrains.com/platform/2026/10/jetbrains-terminal-now-uses-ghostty/
- Paneflow pinning/wrapping libghostty-vt: https://paneflow.dev/blog/libghostty-linux
- alacritty_terminal (Apache-2.0): https://crates.io/crates/alacritty_terminal · vte (Apache-2.0 OR MIT): https://crates.io/crates/vte
- Ghostty memory leak post-mortem: https://mitchellh.com/writing/ghostty-memory-leak-fix
- Typometer latency tests: https://beuke.org/terminal-latency/ · https://news.ycombinator.com/item?id=45253927
- Rio complaints (splits/resize/glyphs): https://news.ycombinator.com/item?id=45432977
- Apple CADisplayLink (NSView.displayLink, macOS 14+): https://developer.apple.com/documentation/appkit/nsview/displaylink(target:selector:)
- Apple CAMetalLayer: https://developer.apple.com/documentation/quartzcore/cametallayer
- Apple effectiveAppearance: https://developer.apple.com/documentation/appkit/nsapplication/effectiveappearance
- Apple window tabbing: https://developer.apple.com/documentation/appkit/nswindow/tabbingmode
- Apple notarization: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
- Apple Developer Program fee (99 USD/membership year): https://developer.apple.com/programs/enroll/ · https://developer.apple.com/programs/whats-included/
- Sparkle (software update framework for macOS): https://sparkle-project.org/
- Zed terminal crate depends on alacritty_terminal (Zed fork): https://github.com/zed-industries/zed/blob/main/crates/terminal/Cargo.toml · https://github.com/zed-industries/zed/blob/main/Cargo.toml
- OSC 133 semantic prompt marks (A–D, FinalTerm origin): https://control-codes.page/osc/prompt/
- iTerm2 proprietary escape codes (OSC 1337 CurrentDir, ClearScrollback): https://iterm2.com/documentation-escape-codes.html
- Kitty performance & benchmark methodology: https://sw.kovidgoyal.net/kitty/performance/

## Engine study (4 Nov 2026): which engine is fastest and most native on macOS 26+?

Labels: **[S]** = sourced fact, **[I]** = my inference, **[T]** = target, not a measurement.

### Candidates
A. libghostty-vt (Zig core, C API) + Swift/AppKit/Metal
B. Rust `alacritty_terminal`/`vte` + Swift/AppKit/Metal via C FFI
C. Pure Swift engine (SwiftTerm) + AppKit/Metal
D. Full-Rust app (objc2/winit + wgpu/Metal, the Rio approach)

### Evidence
- **[S] libghostty-vt** is extracted from Ghostty's core. It has a SIMD-optimized parser, scrollback/reflow, key/mouse encoding and an incremental render-state API, and it is MIT licensed ([Ghostling](https://github.com/ghostty-org/ghostling), [vt.h](https://github.com/ghostty-org/ghostty/blob/main/include/ghostty/vt.h)). Its C API is "not yet stable… breaking changes are expected" (vt.h). JetBrains turned it on by default in its 2026.3 terminal ([blog](https://blog.jetbrains.com/platform/2026/10/jetbrains-terminal-now-uses-ghostty/)). Paneflow switched its Linux builds from Alacritty to it, pins one exact commit, and keeps Alacritty on macOS ([blog](https://paneflow.dev/blog/libghostty-linux)). Ghostty's worst memory leak (37 GB+) was in scrollback page pruning and is fixed in 1.3 ([post-mortem](https://mitchellh.com/writing/ghostty-memory-leak-fix)).
- **[S] Ghostty's own claim** is that it and Alacritty are "usually within a few percentage points" on benchmarks, both far faster than Terminal.app/iTerm ([README](https://github.com/ghostty-org/ghostty)). This is maintainer-stated, with no published method.
- **[S] Third-party latency tests (all Linux, none on macOS):**
  - Typometer on i3/X11, Ghostty 1.2.0 13.0 ms vs Alacritty 4.2 ms average ([HN](https://news.ycombinator.com/item?id=45253927))
  - Typometer on X11 with no compositor, 18.8 vs 11.1 ms ([HN](https://news.ycombinator.com/item?id=48102562))
  - high-speed camera on Hyprland, 38.3 vs 16.7 ms ([moktavizen](https://github.com/moktavizen/terminal-benchmark))
  - **[I]** These measure whole apps (renderer and frame pacing), not engines. They don't show that libghostty-vt's parser is slower.
- **[S] alacritty_terminal** is Apache-2.0 and `vte` is Apache-2.0 OR MIT (crates.io). Zed's terminal depends on a pinned Zed fork of it ([Zed Cargo.toml](https://github.com/zed-industries/zed/blob/main/Cargo.toml)). Alacritty itself has the lowest whole-app latency in the Linux tests above. Kitty's own benchmark (Linux, `kitten __benchmark__`, parser-only) puts alacritty 0.13.1 at 54 MB/s on average vs kitty 134.6 MB/s ([kitty docs](https://sw.kovidgoyal.net/kitty/performance/)); kitty's maintainer ran it.
- **[S] SwiftTerm** (pure Swift, MIT-style license). Its maintainer's own trace says the parse thread "used approximately 98% of one CPU core… parse cost set the throughput limit". 71.2% of parse CPU went to ARC retain/release, Swift exclusivity checks and row clears ([PERFORMANCE.md](https://github.com/migueldeicaza/SwiftTerm/blob/main/PERFORMANCE.md)). The maintainer said the earlier Metal backend was "way too complex and the performance was not great" and was restarted ([issue #202](https://github.com/migueldeicaza/SwiftTerm/issues/202)). The new Metal backend adds dirty-row caching ([commit](https://github.com/migueldeicaza/SwiftTerm/commit/3c45fdcfcf4395c72d2a4ee23c0bce79017b5391)). A third-party iOS user saw ~30 fps with CoreText vs ~55 fps with Metal on a full-screen TUI ([issue #512](https://github.com/migueldeicaza/SwiftTerm/issues/512)).
- **[S] Full-Rust app (Rio):** Rio's macOS light/dark following has broken more than once. Issue #660 (broken "since 0.1.10") and commit b8a4e9c both rely on winit's `window.theme()` ([#660](https://github.com/raphamorim/rio/issues/660), [b8a4e9c](https://github.com/raphamorim/rio/commit/b8a4e9c55193570aaae688ac9b791331fd47ecc8)). HN users also report split and resize bugs ([HN](https://news.ycombinator.com/item?id=45432977)). `objc2-app-kit` gives full AppKit bindings (crates.io, v0.3.2). **[I]** Matti's #1 pain (theme switching) sits exactly in the cross-platform windowing layer that a native AppKit shell avoids.
- **[S] macOS 26 APIs:** Liquid Glass via `NSGlassEffectView`, with content placed as its `contentView` and not behind it as a sibling ([WWDC25 session 310](https://developer.apple.com/videos/play/wwdc2025/310/)). Ghostty added optional glass backgrounds this way, off by default, and had to move the view after layout bugs ([PR #8801](https://github.com/ghostty-org/ghostty/pull/8801), [PR #10046](https://github.com/ghostty-org/ghostty/pull/10046)). `NSView.displayLink` exists from macOS 14 (Apple docs). **[I]** These APIs come for free in Swift/AppKit and are awkward from Rust/winit. Glass should stay opt-in (behind the terminal text) because it costs GPU time and readability. I found no macOS 26/27-specific Metal or text API that changes terminal rendering (not exhaustively checked).

### Decision matrix ([I] = my scoring from the evidence above, 1 = worst, 5 = best)
| Criterion | A libghostty-vt + Swift | B Rust core + Swift | C SwiftTerm | D Full Rust |
|---|---|---|---|---|
| Parser throughput | 5 (SIMD, Ghostty-proven) | 4 | 2 (maintainer: ARC-bound) | 4 |
| Input latency potential* | 5 | 5 | 4 | 4 |
| Memory control | 4 (page-based; fixed leak history) | 4 | 3 | 4 |
| Native macOS 26 feel (theme, tabs, glass) | 5 | 5 | 5 | 2 |
| API stability | 2 (unstable C API, pin it) | 4 | 4 | 4 |
| Time to ship v1 | 4 | 3 (FFI + 2 toolchains) | 4 | 2 |
| Matti likes Rust | – | ✓ | – | ✓ |
\*Latency is decided by the shell (frame pacing, drawing right after a keypress), which A, B and C share. [I]

### Recommendation
Build the app as Swift + AppKit + Metal on macOS 26+, and make the engine a swappable module. Spike **A (libghostty-vt)** and **B (Rust alacritty_terminal)** behind the same shell, and pick whichever measures better on Matti's Mac. A is the favourite: faster parser, used in production by Ghostty and JetBrains, and MIT. Its weak spot is an unstable API, which a pinned commit and a thin wrapper contain. Drop C (Swift is parser-bound by its maintainer's own numbers) and D (it puts the theme and window layer, Matti's main pain, in cross-platform code).

### 1-week spike (on Matti's Mac, macOS 27)
- **Days 1–2:** minimal Swift/AppKit window with one CAMetalLayer, a CoreText glyph atlas, NSView.displayLink, a PTY via forkpty, and an `Engine` protocol. Implement adapter A.
- **Day 3:** adapter B (alacritty_terminal via a cbindgen C header, a static lib built with cargo).
- **Day 4, measure each build, Terminal.app and Rio, with the same font, size, window and shell:**
  - typing latency: Typometer (pavelfatin.com/typometer), 200 samples, report min/avg/max/SD; optionally a 240 fps phone camera on a key LED as a cross-check
  - throughput: `vtebench` (alacritty/vtebench) plus `time cat` of a 100 MB file
  - startup: time from launch to first frame with a prompt, via `os_signpost` and Instruments, 20 cold + 20 warm runs
  - memory: idle RSS (`footprint`/Activity Monitor) after 1 min; RSS after 1 h feeding Claude Code-style emoji/grapheme output with a 10k-line cap (leak check)
  - CPU when idle: 0% expected [T]
- **Day 5:** write up the results table and decide.
- **Pass bar [T]:** latency ≤ Terminal.app, idle RSS < 60 MB, cold start < 150 ms, no RSS growth over the 1 h soak.

> Note: the Google Doc 'LeanTerm v1 spec' (Drive, 4 Nov, rev. 1) is now older than this plan; this markdown is the current version.
