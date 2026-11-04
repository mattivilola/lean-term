#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
MODE="${1:-run}"
if [[ $# -gt 0 ]]; then shift; fi
mkdir -p .cache/modules .cache/spm .cache/config .cache/security
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.cache/modules"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT_DIR/.cache/modules"
swift build --disable-sandbox -c release --cache-path "$ROOT_DIR/.cache/spm" --config-path "$ROOT_DIR/.cache/config" --security-path "$ROOT_DIR/.cache/security"
APP="$ROOT_DIR/dist/LeanTermBench.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/LeanTermBench "$APP/Contents/MacOS/LeanTermBench"
cp "$ROOT_DIR/branding/approved/crt-family/lean-term/LeanTerm.icns" "$APP/Contents/Resources/LeanTerm.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LeanTermBench</string>
<key>CFBundleIdentifier</key><string>com.mattivilola.leanterm.bench</string>
<key>CFBundleName</key><string>LeanTerm Bench</string>
<key>CFBundleIconFile</key><string>LeanTerm.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
if [[ "$MODE" == "--build-only" ]]; then exit 0; fi
# Stop only our task-owned benchmark app, never a user's other terminal.
pkill -x LeanTermBench >/dev/null 2>&1 || true
case "$MODE" in
  run) /usr/bin/open -n "$APP" --args "$@" ;;
  --verify) /usr/bin/open -n "$APP" --args "$@"; sleep 1; pgrep -x LeanTermBench >/dev/null ;;
  --debug) lldb -- "$APP/Contents/MacOS/LeanTermBench" "$@" ;;
  --logs|--telemetry)
    /usr/bin/open -n "$APP" --args "$@"
    /usr/bin/log stream --info --style compact --predicate 'process == "LeanTermBench"' ;;
  *) echo 'Usage: script/build_and_run.sh [run|--build-only|--verify|--debug|--logs|--telemetry] [app arguments]' >&2; exit 2 ;;
esac
