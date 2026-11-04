# LeanTerm: measure first, keep it simple

4 November 2026 · revision 5 · v1 stack and CRT branding selected by Matti.

[Revision 2](docs/archive/leanterm-plan-rev2.md) preserves the original feature details. This revision supersedes its stack ranking, custom-renderer commitment, benchmark method and estimates. The fixture measurements and their limitations are recorded in [the experiment report](benchmarks/results/2026-11-04.md). Matti accepted the v1 stack after the controlled and reverse-order typing runs.

## Direction

LeanTerm is a small, free, open-source macOS terminal for Matti, eventually available from his public GitHub account and leanterm.com.

**Visual quality is a requirement:** the app must look excellent, feel easy to use and have a clean, highly visual interface. Use careful typography, spacing, restrained color, polished light/dark themes and clear controls. Keep everyday actions discoverable and settings visual. Measure any effects before adopting them; visual polish should preserve terminal responsiveness. The benchmark window is a plain measurement fixture, not the final product design.

**Selected v1 stack: Swift + AppKit, reusing SwiftTerm's engine/view/PTY integration, with CoreGraphics + CoreText rendering.** Rust is deferred until profiling demonstrates a worthwhile benefit; no Rust implementation was benchmarked. The local results support this practical initial choice, not a universal language or terminal speed ranking.

**Selected identity: 01 — CRT family.** Lean Term inherits the emerald CRT `>_` icon; Lean VS Code receives the matching teal `{ }` icon. Final icon/logo/favicon files and source prompts are under [branding](branding/README.md). Both websites are to cross-promote the sibling app with truthful release status.

Matti confirmed: prioritize typing/TUI response, with memory and launch close behind, then bulk throughput. Reuse an existing terminal core and renderer if they perform best. Correct text and reliable macOS behavior are requirements. Simplicity breaks a performance tie; it does not justify calling a slower result the fastest.

Local inventory: MacBook Pro, M3 Max, 36 GB RAM, macOS 27.0.1. Terminal.app, Ghostty and Rio are installed. Record display/refresh settings when measuring. Proposed minimum remains macOS 26; this Mac alone cannot validate that minimum.

## Corrections to the original plan

- **libghostty-vt supplies terminal state, not a renderer.** It offers parsing, input encoding and render-state access; drawing/windowing remain the host's responsibility. Its C API explicitly warns that it is incomplete and unstable. [S1]
- **Full Ghostty reuse is different.** The full renderer uses an internal embedder API tailored to Ghostty's macOS app. Reusing it means a pinned source integration or fork, with maintenance costs; it is not a supported drop-in renderer library. [S2]
- **SwiftTerm deserves a current measurement.** It already provides an AppKit frontend, local-process support and optional Metal rendering. An older parser profile cannot establish its present performance. [S3, S4]
- Language alone does not predict terminal speed. A Rust engine is a valid later alternative, but needs integration and rendering. Rio bugs do not prove Rust cannot provide native macOS behavior.
- Remove the subjective 1–5 speed matrix and “40–60% work saved” estimate. Neither is measured evidence. Linux app benchmarks do not select the fastest stack on this Mac.
- Drawing immediately after a keypress is not sufficient: shell echo generally arrives later through the PTY. Measure the complete visible response.

## Shortlist and order

| Route | Role in the first experiment | Cost or limitation |
|---|---|---|
| Swift/AppKit + SwiftTerm's existing terminal view | First runnable LeanTerm candidate; compare its existing Metal and default renderers | Actual latency, throughput and memory need measuring |
| Existing Ghostty | Whole-app performance reference; briefly investigate reusing its integrated native implementation | A future LeanTerm fork/integration must be measured separately |
| Terminal.app | Built-in reference | Reference only |
| Rio | Optional reference for Matti's current workflow | Add only if it answers a useful question |
| Swift/AppKit + libghostty-vt or Rust `alacritty_terminal` | Later investigation if measurements reveal a specific problem | Engine-only choices require a renderer and substantial text/input integration |

Do not build both engine bridges, a generic engine framework or a custom glyph atlas now. Keep terminal-specific calls localized in the eventual app; abstraction should follow actual needs.

## Initial experiment: maximum two working days

**Day 1:** measure the installed references; build a pinned SwiftTerm macOS sample in Release; verify which renderer is active. Try the supported renderer choices without writing a renderer. Spend at most two hours checking for a buildable Ghostty-based integration path. Stop that investigation if it requires substantial changes. An unchanged Ghostty build remains a reference, not a LeanTerm candidate.

**Day 2:** repeat the useful measurements, do a short correctness check and write one results table. If a second reusable candidate is already runnable within the timebox, measure it too. Otherwise report the integration limitation and decide whether the observed gap justifies more work. Do not disguise an unfinished integration as a benchmark loss.

This can select a practical first implementation and the fastest tested usable candidate. It cannot prove how an unbuilt custom stack performs. If results leave a material question unresolved, record it and propose one focused follow-up rather than extending the spike indefinitely.

### Fixed conditions

Release/optimized builds, no debugger; one foreground terminal; 120 × 40 cells; same installed monospace font and size, display, refresh setting, screen scale and power mode. Use 10,000 scrollback lines where supported; document mismatches. Disable transparency, blur, ligatures, cursor blink and optional metrics for the comparison. Use isolated test configs, not edits to Matti's everyday settings.

Use clean `zsh -f` with a simple fixed prompt for controlled tests, then separately check Matti's real shell/TUI workflow. Keep machine load low, alternate app order and retain every run. Do not clear filesystem caches or repeatedly reboot to manufacture cold starts.

### Five simple checks

| Check | Method | Record |
|---|---|---|
| Typing response, primary | Validate Typometer with 10 samples first; if it works on this Mac, take 3 batches of 100 samples per app in the same shell echo context | Median and p95 ms per batch, raw samples and display Hz |
| Launch | Fully quit; relaunch 10 times to the same visible shell-ready marker using one external timing/capture method | Median and slowest launch-to-visible-ready time; first launch separately |
| Output + responsiveness | Replay identical pre-generated 10 MiB ASCII and 10 MiB ANSI/Unicode files, 3 times each; type/scroll during a fixed 10-second TUI-style stream | Writer time, visible final marker, stalls/corrupt text and input responsiveness |
| Memory + idle | Same macOS memory metric/tool after 60 seconds idle and after filling scrollback; observe CPU for 60 seconds | App memory, app helpers if any, idle CPU; shell/child memory separately |
| Correctness | Resize/reflow, selection/copy/paste, emoji/combining/CJK text, IME, clear, 5 light/dark switches and one representative local TUI | Pass/fail and concrete problems |

Measurement boundaries:

- Typometer observes synthetic OS input to screen-capture change, not physical key-to-photon latency. Its permissions, Java runtime and capture behavior need validation on this Mac. [S5] If unsuitable, optionally use high-frame-rate video with a valid visible input reference. Without a comparable working method, leave numerical latency undecided.
- Startup must include visible readiness. A shell marker alone or internal signposts omit part of the experience; a stopwatch cannot establish sub-150 ms startup. Repeated process launches usually retain warm filesystem caches, so label them accordingly. If only rough timing is available, report it as rough.
- `time cat` measures writer completion through the PTY, possibly before final painting. Label it an intake indicator; observe/capture final visible output separately. Do not report rendered MB/s without timing display completion. `vtebench` explicitly excludes latency and frame rate. [S6]
- The load check is initially a responsiveness smoke check. An idle typing result does not establish latency under heavy output. Use a deterministic local replay, not paid/live AI calls.
- Prefer consistent physical footprint; label RSS if used instead and never mix the two. Idle CPU should approach zero; an exact instantaneous 0.0% is not a pass criterion. Measure normal defaults separately if they enable blink or metrics.

For the likely winner, run one 10-minute mixed Unicode/output loop with capped scrollback. Record memory at minutes 1, 5 and 10 and after output stops. Look for a bounded plateau after caches warm, not exact zero growth. This is a smoke check, not proof of leak freedom; use a longer soak before release.

### Decision rule

1. Correctness first: crashes, stuck input, broken text and essential-workflow failures must be fixed before a candidate can win.
2. Prefer a repeatable typing/TUI response advantage exceeding measurement uncertainty and run-to-run variation. As a simple practical response tie threshold, use one display refresh interval: about 8.3 ms at 120 Hz or 16.7 ms at 60 Hz. This is a product choice, not a claim that smaller differences are imperceptible.
3. Within that response tie, compare startup, memory and throughput. A repeatable 10% difference is a useful initial threshold for those metrics, provided it also exceeds run variation. State tradeoffs explicitly.
4. If results are close, choose the smaller maintained integration. Do not build a renderer to chase measurement noise.

After the results are reviewed and the stack decision is made, inform the website chat with a short summary of the findings and tradeoffs that led to the decision. Do not send that decision handoff beforehand. Keep this selection evidence distinct from performance measurements of the eventual initial product version.

The old <150 ms startup and <60 MB memory numbers remain stretch goals, not established acceptance gates. Set realistic budgets after the baseline. Report “fastest among these tested candidates under these conditions,” not “fastest possible stack.”

| App/build + revision | Typing median/p95 | Launch median/max | Intake ASCII/mixed | Idle/full memory | Idle CPU | Correctness |
|---|---|---|---|---|---|---|
| Terminal.app reference | — | — | — | — | — | — |
| Ghostty reference | — | — | — | — | — | — |
| SwiftTerm default renderer | — | — | — | — | — | — |
| SwiftTerm Metal renderer | — | — | — | — | — | — |
| Other runnable candidate, if feasible | — | — | — | — | — | — |

Deliver one short Markdown report and raw readings. Record app versions, dependency SHAs, compiler versions, build commands, machine/display settings and fixture hashes. No dashboard or elaborate benchmark framework.

## Implementation after the decision

**First usable app:** one window/pane, local shell, resize, Unicode/IME, selection/copy/paste, bounded scrollback, clear, basic font/color settings and reliable System/Light/Dark behavior. Reuse upstream input/rendering/terminal behavior wherever possible.

Clear needs care: prompt marks do not guarantee prompt redraw, and form feed is input to the foreground application. Verify multiline prompts and running TUIs; never blindly send form feed to arbitrary programs.

Then add the requested features in small increments:

1. Expand visual settings and save them in one plain config file. TOML remains the preference; avoid layering a second format over upstream configuration unless worthwhile. Add hot reload after ordinary save/apply works.
2. Tabs, then fixed 2-vertical, 2-horizontal and 4-grid splits, with focus controls.
3. Shortcut editor and conflict checks; use revision 2's shortcut defaults initially.
4. Optional system/app metrics bar; hidden means no sampling. Measure its overhead separately.
5. Opt-in shell integration, directory/layout restoration and explicitly configured startup commands. Do not replay old commands automatically.

Revision 2 retains the detailed visual controls, config sketch and startup options as a requirements backlog, subject to validation against the chosen backend. Image protocols, ligatures, plugins, cloud sync and cross-platform support do not drive the initial release. Estimate feature work after the spike. Check text input and accessibility early instead of leaving them entirely to final polish.

### Post-implementation task: publish initial-version performance numbers on leanterm.com

After the initial app is implemented, measure that actual app build and publish its results on the site's benchmark page and home summary. Include valid typing/TUI median and p95, visible-ready startup, output responsiveness/throughput with clear measurement boundaries, idle/full-scrollback memory and corrected idle CPU. Record exact app version/revision, Mac/display/power/font/workload conditions, run counts, raw evidence, methods and limitations. Identify unavailable measurements honestly; exclude preliminary or corrected-away values. Link public source/releases when available. The current spike fixtures are not initial-version app results. Website changes are handled separately under `website/`; this task does not authorize publishing spike numbers there now.

## Open-source delivery

The public repository is [mattivilola/leanterm](https://github.com/mattivilola/leanterm). Use direct commits/pushes for this solo-owner repo. The current app is a development benchmark fixture; there is no signed Lean Term product release yet.

Use MIT for original LeanTerm code; retain upstream licenses and notices for reused code, fonts and dependencies. Pin exact revisions, document a reproducible source build and identify any Ghostty-derived implementation clearly. Contributors should be able to build locally without a signing certificate.

Add signing/notarization for public binaries after the app works. Defer Sparkle, Homebrew packaging and website work until there is a release worth distributing. Keep source-published, locally built, signed/notarized and publicly released states separate. Verify domain/publication setup when needed.

## Confirmed preferences

1. Typing/TUI response comes first; memory and launch are close behind.
2. Reusing an existing terminal core and renderer is welcome if they perform best, including a Ghostty-derived implementation subject to the integration and maintenance checks above.
3. A beautiful, clean, visual and easy-to-use interface is required alongside speed and performance.

## Sources checked for revision 3

- **S1:** [libghostty-vt header](https://github.com/ghostty-org/ghostty/blob/main/include/ghostty/vt.h) and [Ghostling README](https://github.com/ghostty-org/ghostling): engine/render-state boundary, no drawing/windowing, unstable API. Ghostling is a demo, not the proposed app base.
- **S2:** [Ghostty internal embedder header](https://github.com/ghostty-org/ghostty/blob/main/include/ghostty.h): internal consumer and API boundary.
- **S3:** [SwiftTerm README](https://github.com/migueldeicaza/SwiftTerm): AppKit frontend, local processes and optional Metal renderer.
- **S4:** [SwiftTerm performance guide](https://github.com/migueldeicaza/SwiftTerm/blob/main/PERFORMANCE.md): separate engine/render/in-app methods and Release-build requirement. Verify sample/harness commands at the pinned revision.
- **S5:** [Typometer author documentation](https://pavelfatin.com/typometer/): generated input and screen-capture measurement.
- **S6:** [vtebench README](https://github.com/alacritty/vtebench): PTY-read scope and latency/frame-rate limitations.

Main-branch sources change. Pin and record the actual source revisions when implementing and measuring.
