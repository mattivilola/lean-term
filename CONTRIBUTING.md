# Contributing

Keep Lean Term small, responsive and native to macOS. Start with a focused issue
or change; discuss substantial features before building them.

1. Install Xcode's Swift 6.2+ toolchain on macOS 26+.
2. Run `./script/build_and_run.sh --test`.
3. Run `./script/build_and_run.sh --verify` and check the behavior you changed.

The build script prepares the exact pinned SwiftTerm dependency before compiling.
Use it instead of invoking SwiftPM directly; see [the architecture notes](docs/ARCHITECTURE.md).
No signing certificate, account, API key or paid service is needed for local builds.

Use small Swift/AppKit types and reuse SwiftTerm behavior. Avoid background timers,
new frameworks and terminal abstractions unless a demonstrated need justifies them.
Include focused tests for lifecycle and data handling changes. For UI changes,
describe the native checks and include a screenshot when useful. Do not claim a
performance improvement from a build check alone.

Report bugs with your macOS version, app/source revision, reproduction steps and
expected versus actual behavior. Performance reports should include the workload,
font, window dimensions and measurement boundaries. See [benchmarks](benchmarks/README.md).

Contributions are licensed under the project's [MIT license](LICENSE).
