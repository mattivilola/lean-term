# Releasing Lean Term

Lean Term uses a local macOS release pipeline. It builds a Developer ID signed
app, submits it to Apple for notarization, staples and validates the ticket,
creates a ZIP and Sparkle appcast, then uploads the files to a GitHub draft.
Nothing is published until the uploaded files have been downloaded again and
their sizes and SHA-256 digests match the local artifacts.

## One-time setup

Use a Mac with the Xcode command line tools, Python 3.10 or newer, and GitHub CLI installed and
authenticated for `mattivilola/lean-term`. The signing certificate and Apple
notary credentials must already be available in Keychain. Sparkle's EdDSA
private key stays in the local Keychain under account `LeanTerm`; only its
public key belongs in `release/sparkle-public-key.txt` in the source tree.
Never export or upload the private key.

The project defaults to the Developer ID identity
`Developer ID Application: Matti Vilola (MM233FKU38)` and notary profile
`lean-vs-code`. Check local prerequisites with:

```sh
make doctor
```

The Sparkle command line tools are resolved from the pinned Swift package.
If a restricted host prevents SwiftPM from starting its sandbox, opt out for
that invocation only with `SWIFTPM_DISABLE_SANDBOX=1`.

## First signed release: 0.1.1

Before each release, update and commit `VERSION` and all intended source files,
push that commit to GitHub, and confirm the working tree is clean. The release
scripts bind staging, the `vVERSION` tag, and the GitHub release to that exact
commit SHA. A version already published cannot be replaced.

Run the local checks and stage the signed release:

```sh
make test
make doctor
make release
```

`make release` builds `Lean Term.app` with release-only Sparkle settings,
signs nested code and the app with hardened runtime and a secure timestamp,
submits the app archive using the selected Keychain profile, waits for Apple,
staples the accepted ticket, validates Gatekeeper assessment, then creates
`dist/releases/v0.1.1/Lean-Term-macos-arm64.zip`. It generates and verifies a
Sparkle appcast signed from the `LeanTerm` Keychain account. Failed notarization
receipts and staging files remain under `dist/releases/vVERSION/` so the same
source commit can be inspected and resumed.

To compile and test before invoking Keychain-backed release steps, use the
prepared-app path. Its build stays in the normal user context and keeps
SwiftPM's default sandbox:

```sh
make test
LEANTERM_RELEASE_BUILD=1 ./script/build_and_run.sh --build-only
make release-prepared
make publish
```

Prepared mode validates the app's version, release flag, Sparkle public key,
and embedded source revision against clean `HEAD` before checking signing
credentials. It refuses to reuse an existing per-version staging directory.
The direct equivalent is:

```sh
python3 script/release.py release --prepared-app --version "$(cat VERSION)"
```

Standard `make release` continues to build the app itself.

Review `dist/releases/v0.1.1/release-state.json` and the three outgoing assets:

- `Lean-Term-macos-arm64.zip`
- `appcast.xml`
- `Lean-Term-macos-arm64.zip.sha256`

Publish through a GitHub draft:

```sh
make publish
```

The command creates or resumes only the `v0.1.1` draft for the exact source
commit. It refuses unexpected assets, mismatched uploads, a different tag
target, or an already-published release. Once every asset is downloaded and
verified against the local SHA-256 and size, it marks the release published
and latest. The website's download button should link to:

```text
https://github.com/mattivilola/lean-term/releases/latest/download/Lean-Term-macos-arm64.zip
```

Install the staged notarized app at the fixed path with:

```sh
make install
```

If `/Applications` is not writable, `make install` asks macOS for administrator
authorization for the copy and rename operations and rechecks the bundle.
Installation checks the bundle identifier and signature, refuses to replace an app while its
`Build.lock` is held, and preserves the previous app as a timestamped backup.
It does not terminate a running app or modify signed resources.

## Sparkle update: 0.1.2 and later

To publish an automatic update, set `VERSION` to `0.1.2`, commit and push the
source, then repeat `make test`, `make doctor`, `make release`, and
`make publish`. The release build enables automatic update checks and downloads;
ordinary development builds keep them disabled. The appcast is uploaded as a
versioned asset while the app reads the stable feed URL:

```text
https://github.com/mattivilola/lean-term/releases/latest/download/appcast.xml
```

Do not edit a generated appcast after signing it. Any appcast change requires
regenerating it with Sparkle's official tools and signing account.

## Useful overrides

Make reads the version from the tracked `VERSION` file. Passing a different
`VERSION` is rejected so bundle metadata, release tag, and asset URLs stay in
sync. For another installed Developer ID identity or Keychain profile, pass
the setting to make without putting credentials in command-line arguments:

```sh
make doctor CODESIGN_IDENTITY='Developer ID Application: Name (TEAMID)' \
  NOTARY_KEYCHAIN_PROFILE='profile-name' SPARKLE_KEYCHAIN_ACCOUNT='LeanTerm'
```

The corresponding settings can also be supplied when running `make release`,
`make publish`, or `make install`. They name Keychain items; they are not
secrets. Do not add CI secret storage or commit private signing/notary material
for this local release workflow.
