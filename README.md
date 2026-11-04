# LeanTerm

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="branding/approved/crt-family/lean-term/wordmark-on-dark@2x.png">
  <img alt="Lean Term" src="branding/approved/crt-family/lean-term/wordmark-on-light@2x.png" width="280">
</picture>

A fast, beautiful native terminal for macOS. Free and open source.

**Early benchmark experiment.** This repository currently contains a small
measurement app and the product plan. The finished interface and a public app
release are still ahead.

The priorities are responsive typing and terminal applications, low memory and
quick launch, and an excellent-looking, clean, easy-to-use interface. Reuse an
existing terminal core and renderer where measurements support it.

The selected v1 stack is **Swift + AppKit + SwiftTerm, using CoreGraphics/CoreText**.
The [local experiment](benchmarks/results/2026-11-04.md) informed this choice;
it does not establish that Swift is faster than Rust or that the finished app
is the world's fastest terminal. Rust remains an option for a demonstrated need.

## Run the benchmark window

Requires macOS 26+, Xcode's Swift toolchain (Swift 6.2+) and Git. No developer
certificate is required for a local build.

```sh
./script/build_and_run.sh run --renderer metal
./script/build_and_run.sh run --renderer cg
```

The script builds in Release, stages `dist/LeanTermBench.app`, and opens a local
shell in the selected renderer. It stops only the previous `LeanTermBench`
process. This is a measurement fixture; its interface is not the final design.

`--build-only` builds without opening a window. `--verify`, `--debug`, `--logs`
and `--telemetry` support local development. SwiftTerm is pinned to an exact
commit in `Package.swift`; transitive versions are in `Package.resolved`.

## Benchmark method and results

See [the plan](leanterm-plan.md) and [benchmark instructions](benchmarks/README.md).
The [experiment report](benchmarks/results/2026-11-04.md) includes raw readings,
the v1 decision and the checks still needed for the actual initial product.
Bulk PTY intake is not a measurement of typing latency or final screen painting.

The approved [CRT family branding pack](branding/README.md) includes both apps'
icons, logos and favicons. Meet the companion code editor at
[leanvscode.com](https://leanvscode.com).

## License

Original LeanTerm code is MIT licensed. SwiftTerm and other dependencies retain
their own notices; see [third-party notices](THIRD_PARTY_NOTICES.md).
