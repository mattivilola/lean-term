# Approved Lean CRT family

Matti selected **01 — CRT family** on 4 November 2026 and authorized the complete
icon/logo/favicon pack, a new Lean VS Code app release, and updates to both sites.

| Product | App icon | Meaning |
|---|---|---|
| Lean Term | Emerald CRT, green `>_` | Terminal |
| Lean VS Code | Teal CRT, mint `{ }` | Code editor |

Lean Term inherits the exact former Lean VS Code ICNS artwork. The new editor
artwork was generated with the built-in imagegen tool from the approved board.
The original installed app was read for reference and has not been modified.

## Canonical files

The frozen delivery pack is `approved/crt-family/`. `manifest.json` records the
SHA-256 and byte count of every file. Consumers should copy the appropriate
product folder and verify the manifest before integrating it.

| Use | File in each product folder |
|---|---|
| macOS application | `LeanTerm.icns` / `LeanVSCode.icns` |
| Editable icon resolutions | `AppIcon.iconset/` |
| Full-size artwork | `app-icon-1024.png` |
| Header/footer mark | `logo-mark.svg` |
| Full logo on a light surface | `wordmark-on-light.svg`, `wordmark-on-light@2x.png` |
| Full logo on a dark surface | `wordmark-on-dark.svg`, `wordmark-on-dark@2x.png` |
| Flat/vector symbol | `symbol.svg`, `symbol-monochrome.svg` |
| Browser tab | `favicon.svg`, `favicon.ico`, `favicon-16x16.png`, `favicon-32x32.png` |
| Apple home screen | `apple-touch-icon.png` |
| Web app metadata | `site.webmanifest`, `icon-192.png`, `icon-512.png` |
| Safari pinned tab | `safari-pinned-tab.svg` |

PNG sizes 16, 32, 48, 64, 128, 180, 192, 256 and 512 are also included.
The CRT artwork is raster imagery; the SVG mark wrappers embed small PNGs for
portable use. The flat symbols and outlined wordmark lettering are vector.
Wordmarks do not require a font download. Use the light/dark versions according
to the surface behind them.

## Integration

- Lean Term owns the emerald prompt icon from now on. Lean VS Code uses the teal
  braces. Do not use the prompt as the editor's product logo after migration.
- Keep existing bundle identifiers, storage and update identities.
- Rebuild/sign/notarize Lean VS Code through its release workflow. Do not patch
  icon resources inside the installed signed app.
- Replace active product branding surfaces, not third-party extension logos or
  generic programming-language/file icons.
- Preserve both Sites project IDs and audiences. Update header/footer logos,
  favicons, touch icons and existing brand-bearing metadata/images as appropriate.
- Both sites should include a small Lean-family cross-promotion section linking
  the sibling app with its approved icon and a short factual description.
- Lean Term remains in development. Its source, local fixture, signed release,
  and downloadable product are separate delivery states.

## Sources and reproducibility

`review/` preserves the three review boards; only option 01 was selected.
`sources/imagegen-prompts.json` records all prompts and the built-in mode.
`sources/lean-vs-code-crt-master.png` preserves the editor generator output.
`wordmark-paths.swift` exports outlined system-rendered lettering without
redistributing font files; `build-assets.py` packages sizes/formats from the
approved art. Native ICNS encoding needs a desktop-capable context on this Mac.
`--skip-icns` regenerates web derivatives while retaining validated ICNS files.

The pack has been checked for exact sizes, alpha, valid SVG XML, ICNS decode,
ICO frames and manifest hashes. Small-size previews are technical derivatives
of the actual exports, not imagegen approximations.
