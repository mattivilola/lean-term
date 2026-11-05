# Development validation

## 0.1.0 preview — 5 November 2026

Validated locally on Apple Silicon with the Release app bundle. This records
functional checks, not a finished-product performance benchmark or a notarized release.

- Six Swift core tests: login-shell environment, fallback/defaults, preference
  validation/persistence, local directory URL handling, window placement across
  changed displays, and selective recovery resets.
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
- App bundle structure, canonical icon bytes and local ad-hoc signature.

The native smoke mode uses an isolated preference domain and clean test shells;
it removes its own preferences on exit. Its bounded waits run only in test mode.
Normal app operation adds no polling timer.

The development packager and running app share a file lock, so rebuilding cannot
overwrite the bundle while it contains live sessions. Quit checks observe app
exit rather than querying a closed app through UI automation.

Still needed before a production release: manual IME composition and VoiceOver
acceptance, sleep/wake and external display checks, minimum-OS runtime coverage,
and actual-app typing/startup/memory/CPU/soak measurements. The initial experiment
under `benchmarks/results/` describes a separate earlier fixture. Publish new
performance numbers only with the exact tested app version and conditions.
