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
Normal app operation adds no polling timer.

The development packager and running app share a file lock, so rebuilding cannot
overwrite the bundle while it contains live sessions. Quit checks observe app
exit rather than querying a closed app through UI automation.

Additional manual coverage still outstanding: manual IME composition and VoiceOver
acceptance, sleep/wake and external display checks, minimum-OS runtime coverage,
and actual-app typing/startup/memory/CPU/soak measurements. The initial experiment
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
