#!/usr/bin/env bash
# A fixed allowlist of app launches for this local experiment; no shell evaluation.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
LATENCY="$ROOT_DIR/.cache/latency-app/LeanTermLatency.app"
BENCH="$ROOT_DIR/dist/LeanTermBench.app"
echo 'Desktop benchmark launcher ready: latency, bench, new-cg, new-metal, ghostty, new-ghostty, terminal, exit'
while IFS= read -r action; do
  case "$action" in
    latency) /usr/bin/open -a "$LATENCY" ;;
    bench) /usr/bin/open -a "$BENCH" ;;
    new-cg|new-metal)
      renderer="${action#new-}"
      ./script/build_and_run.sh run --renderer "$renderer" --info "$ROOT_DIR/.cache/$renderer-latency-info.json" ;;
    ghostty) /usr/bin/open -a /Applications/Ghostty.app ;;
    new-ghostty)
      /usr/bin/open -n /Applications/Ghostty.app --args --config-default-files=false --config-file="$ROOT_DIR/.cache/ghostty-benchmark.conf" ;;
    terminal) /usr/bin/open -a /System/Applications/Utilities/Terminal.app ;;
    exit) break ;;
    *) echo 'Unknown action; ignored.' ;;
  esac
  echo "Ready: $action"
done
