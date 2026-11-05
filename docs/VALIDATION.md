# Development validation

## 0.1.1 — 5 November 2026

Validated locally on Apple Silicon with the Release app bundle. This records
functional checks, not a finished-product performance benchmark or a notarized release.

- Seven Swift core tests: login-shell environment, fallback/defaults, preference
  validation/persistence, local directory URL handling, window placement across
  changed displays, selective recovery resets, and shortcut persistence/conflict checks.
- Benchmark regression test: all five partial-result suffixes reserve their
  label and prevent overwriting retained readings.
- All 35 brand assets: byte counts, SHA-256, SVG XML and PNG/ICNS headers.
- Native integration: actual PTY ANSI/Unicode output and Find, resize, all six
  appearance/palette combinations, font settings, clear preserving visible text,
  normal shell exit, a HUP/TERM-resistant child requiring safe forced shutdown,
  saved window position/size, independent native tabs and multi-session cleanup
  with one callback per child.
- Native UI: normal account login shell, bracketed paste, Unicode/emoji output,
  Unicode Find, dark appearance/settings layout, native tabs, Vim rendering,
  close cancellation, aggregate quit cancellation and confirmed quit.
- About credits, shortcut layout, conflict recording without executing Quit,
  binding changes/reset/cancel, and both directions of tab wrap in the native UI.
- Fourteen offline release-helper checks for metadata, source identity, signing
  order, draft publication, downgrade prevention and safe installation guards.
- App bundle structure, canonical icon bytes and local ad-hoc signature.

The native smoke mode uses an isolated preference domain and clean test shells;
it removes its own preferences on exit. Its bounded waits run only in test mode.
The activity monitor polls only while a command runs or output just arrived; no timer exists while sessions are idle.
Its detection rules are covered by `SessionActivityTests`.

Manual follow-up: compare idle CPU/wakeups and typing latency with the activity
scanner and tab marks enabled and disabled. An on/off typing benchmark is not
part of the recorded release checks below.

The development packager and running app share a file lock, so rebuilding cannot
overwrite the bundle while it contains live sessions. Quit checks observe app
exit rather than querying a closed app through UI automation.

Additional manual coverage still outstanding: manual IME composition and VoiceOver
acceptance, sleep/wake and external display checks, minimum-OS runtime coverage,
longer performance/soak tests and cold-launch/first-paint measurements. The initial experiment
under `benchmarks/results/` describes a separate earlier fixture. Publish new
performance numbers only with the exact tested app version and conditions.

## Public release verification

Version 0.1.1 was signed with Developer ID, notarized by Apple, stapled and
accepted by Gatekeeper. The published GitHub assets were downloaded and matched
against their local SHA-256 and size. The installed app successfully read its
signed public update feed and reported 0.1.1 as current. Release-only update
settings were also checked in the native UI.

An independent CryptoKit Ed25519 check accepts the release ZIP and rejects a
one-byte modification.

The real 0.1.1 → 0.1.2 in-app update passed on 5 November 2026. The installed
0.1.1 discovered the public signed feed, downloaded and prepared 0.1.2, and
asked before closing the running terminal. Cancel kept the session alive; a
second update request resumed the prepared download. After confirmation,
Sparkle installed and relaunched 0.1.2. About showed the new version, and another
feed check reported it current. All eight saved appearance/font/cursor/Meta,
shortcut and window-frame preference entries matched their pre-update values;
the installed icon matched the canonical asset byte for byte.

Both releases passed exact-source macOS CI, Developer ID signature checks,
Apple notarization and Gatekeeper. Version 0.1.2 is bound to source commit
`756dee2375af089f000b7239fc7d310465427210`. Its published ZIP is 5,250,828 bytes,
SHA-256 `8a993bd241bb6e8040ecc2a1816aa1f379a296ecd0cdb535fc12ca27b0e83647`.
This verifies an immediate manual check and update through the production feed;
future hourly checks and unattended long-running behavior have not been soaked.

## Released-app performance check

The [0.1.2 benchmark report](../benchmarks/results/2026-11-05.md) records 600
Typometer samples, separate idle/filled GUI-footprint observations, and three
warm launch-to-window trials with raw readings and reproducible calculations.
Shell medians were 24.79 / 24.92 ms; Vim insert-mode median was 25.14 ms.
GUI footprint was 58.5 / 81.2 MiB idle/filled. Warm window appearance median was
0.533 s. These endpoints and the historical comparison limits are explicit;
physical key-to-photon, first-paint/shell-ready, cold-cache and long-soak results
remain unmeasured. The installed app binary was unchanged by testing.

The benchmark marketing publication is complete: leanterm.com Site version 10,
website source `5f1fa39ba2ff5e4af39fc361b7aebd1f77aec8bb`, deployment
`appgdep_6aeca98935188191b44e4cdf5c4b8bec`. The live home and benchmarks pages
link the frozen evidence revision `5607624c7b8e534a71c649159067c8be85c189fa` and
label the tested app as 0.1.2. Later app features are not represented by that run.

## 0.1.3 — Native polish validation

All 12 core tests passed, including preference compatibility, independent exit
policies, CPU counter arithmetic and bounded resource histories. The native
integration harness passed 26 checks on the built app: actual PTY output, the
native SF Mono font API, Cmd-K screen/history/search/selection clearing, retained
alternate-screen input modes, usable shell input after clear, the resource
sampler and its disabled state, minimum-width footer layout, shell cleanup,
window restoration and wrapping tab navigation.

Four separate app launches exercised all combinations of close-on-shell-exit
and quit-after-last-session. Both quit-enabled cases observed real application
termination. A fifth launch verified that a shell exiting during the quit
confirmation preserves its window and that Cancel keeps its final output.
Every test used isolated preferences and owned test shells; no user shell files
were changed. The Release build passed. These checks establish functionality,
not new latency results: the published performance measurements remain for 0.1.2.

Version 0.1.3 was signed, notarized, stapled and published from source
`b294fc5903dbee45ddf601020b6adb027111ef9c` after exact-source macOS CI run
`42073398151` passed. Apple submission
`707a126f-5bb3-4a72-9164-28a412145f57` returned Accepted; Gatekeeper and both
Sparkle signatures passed. All three uploaded assets were downloaded and their
sizes and hashes matched before publication. The release ZIP is 5,306,718 bytes,
SHA-256 `5cd703a75e92ae437b19cbd89e9f2e76f6a7416920c051aed2ea4af84417094c`.

The installed 0.1.2 app discovered and downloaded the public 0.1.3 update.
After normal session-close confirmation, Sparkle installed and relaunched it.
About showed 0.1.3. Settings showed the explicitly selected SF Mono 13 pt and
enabled exit policies/resource graphs. The running footer displayed live CPU
and memory readings. The installed executable matched the staged executable
byte for byte and its complete code signature verified. The new default font
does not overwrite other users’ saved font choices.

## 0.2.0 — Release checks

All 22 Swift core tests passed, including the ten command-activity model tests.
All 14 release-helper tests and the benchmark-calculation test passed. The
Release app build passed, followed by 26 native integration checks using
isolated settings and clean test shells. Four additional launches passed every
combination of close-on-shell-exit and quit-after-last-session, including real
application termination when configured. A separate quit-cancellation launch
retained finished output after Cancel. All test sessions cleaned up.

This release includes the command scanner and busy/finished tab marks, emerald
activity colors across palettes, and sweep restoration when returning to a tab.
Activity detection rules have automated model coverage; the native regression
checks do not assess animation appearance. Performance figures remain the
recorded 0.1.2 measurements; no new latency or scanner on/off results are claimed.
