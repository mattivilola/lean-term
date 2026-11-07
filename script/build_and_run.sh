#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
PRODUCT=LeanTerm
if [[ "${1:-}" == "--benchmark" ]]; then PRODUCT=LeanTermBench; shift; fi
MODE="${1:-run}"
if [[ $# -gt 0 ]]; then shift; fi
case "$MODE" in
  run|--build-only|--verify|--debug|--logs|--telemetry|--test) ;;
  *) echo 'Usage: script/build_and_run.sh [--benchmark] [run|--build-only|--verify|--debug|--logs|--test] [app arguments]' >&2; exit 2 ;;
esac
mkdir -p .cache/modules .cache/spm .cache/config .cache/security
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.cache/modules"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT_DIR/.cache/modules"
SPM=(--cache-path "$ROOT_DIR/.cache/spm" --config-path "$ROOT_DIR/.cache/config" --security-path "$ROOT_DIR/.cache/security")
# Restricted hosts may prohibit nesting SwiftPM's macOS sandbox. Opt out explicitly there.
if [[ "${SWIFTPM_DISABLE_SANDBOX:-0}" == 1 ]]; then SPM+=(--disable-sandbox); fi
swift package "${SPM[@]}" resolve
python3 script/prepare_dependency.py
if [[ "$MODE" == --test ]]; then swift test "${SPM[@]}" "$@"; exit; fi
swift build "${SPM[@]}" -c release --product "$PRODUCT"
if [[ "$PRODUCT" == LeanTerm ]]; then
  APP="$ROOT_DIR/dist/Lean Term.app"
  IDENTIFIER=com.mattivilola.leanterm
  DISPLAY_NAME='Lean Term'
else
  APP="$ROOT_DIR/dist/LeanTermBench.app"
  IDENTIFIER=com.mattivilola.leanterm.bench
  DISPLAY_NAME='LeanTerm Bench'
fi
python3 script/package_app.py "$PRODUCT"
case "$MODE" in
  --build-only) ;;
  run) /usr/bin/open "$APP" --args "$@" ;;
  --verify) /usr/bin/open "$APP" --args "$@"; python3 script/package_app.py "$PRODUCT" --running ;;
  --debug) lldb -- "$APP/Contents/MacOS/$PRODUCT" "$@" ;;
  --logs|--telemetry)
    /usr/bin/open "$APP" --args "$@"
    /usr/bin/log stream --info --style compact --predicate "process == '$PRODUCT'" ;;
esac
