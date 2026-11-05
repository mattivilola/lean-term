# Lean Term branding

Lean Term uses an emerald CRT casing with a green pixel `>_` prompt. The artwork
originated in the companion Lean VS Code project and now identifies the terminal;
that editor uses a distinct teal braces icon.

All distributable terminal exports live in `approved/crt-family/lean-term/`.

| Use | File |
|---|---|
| macOS app | `LeanTerm.icns` and `AppIcon.iconset/` |
| Master artwork | `app-icon-1024.png` |
| Logo mark | `logo-mark.svg` |
| Full logo | `wordmark-on-light.svg`, `wordmark-on-dark.svg` and their `@2x.png` versions |
| Browser tab | `favicon.svg`, `favicon.ico`, 16 px and 32 px PNGs |
| Home screen / web metadata | `apple-touch-icon.png`, `site.webmanifest`, 192 px and 512 px PNGs |
| Flat symbol / pinned tab | `symbol.svg`, `symbol-monochrome.svg`, `safari-pinned-tab.svg` |

The CRT artwork is raster. SVG mark wrappers embed PNGs; flat symbols and outlined
wordmark lettering are vector. No font files are distributed or downloaded.
Use the light or dark wordmark for the surface behind it.

## Verify or regenerate

Ordinary app builds use these checked-in exports and need no image tooling.
Verify all 35 files against the SHA-256 and byte counts in `manifest.json`:

```sh
python3 branding/verify-assets.py
```

To deliberately regenerate derived sizes and wordmarks on macOS, install
ImageMagick (`magick` must be on PATH), then run:

```sh
swift branding/wordmark-paths.swift branding/sources
python3 branding/build-assets.py
python3 branding/verify-assets.py
```

The retained ICNS supplies the original macOS icon resolutions. The packager
updates the manifest, so review the resulting artwork and diff before committing.

## Reuse

The project artwork is covered by the repository's [MIT license](../LICENSE),
including modification and redistribution with its copyright/license notice.
Please distinguish modified forks clearly so users can identify which app they
are running. The license does not imply project endorsement.
