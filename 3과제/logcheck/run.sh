#!/bin/bash
# End-to-end profiler run: starts collector, runs k6, joins data, builds profile.csv + report.
#
# Usage:
#   ./run.sh <endpoint> [profile] [namespace] [kube-context]
#     profile : short (default, ~5min) | full (~25min)
#     ns      : k8s namespace (default: app)
#     ctx     : kubectl context (default: current)
set -eu

EP="${1:?usage: ./run.sh <endpoint> [short|full] [ns] [ctx]}"
PROFILE="${2:-short}"
NS="${3:-app}"
CTX="${4:-}"

STAMP=$(date +%Y%m%d-%H%M%S)
OUT="out/$STAMP"
mkdir -p "$OUT"

echo "[run] endpoint=$EP profile=$PROFILE ns=$NS ctx=${CTX:-<current>} out=$OUT"

# 1) start collector in background
KCTX="$CTX" ./collect.sh "$NS" "$OUT/metrics.csv" 10 &
CPID=$!
trap "kill $CPID 2>/dev/null || true" EXIT

sleep 2  # give it one tick

# 2) run k6
k6 run -e BASE="$EP" -e PROFILE="$PROFILE" \
  --out json="$OUT/k6.json" \
  --summary-export "$OUT/k6_summary.json" \
  profile.js 2>&1 | tee "$OUT/k6.log"

# 3) stop collector
kill $CPID 2>/dev/null || true
wait 2>/dev/null || true

# 4) analyze
python3 analyze.py "$OUT/k6.json" "$OUT/metrics.csv" "$OUT/profile.csv" "$OUT/report.md"

echo ""
echo "[run] done. Artifacts in $OUT/"
echo "  - profile.csv   (RPS-bucketed table per app)"
echo "  - report.md     (human-readable summary)"
echo "  - k6.json/log   (raw)"
echo "  - metrics.csv   (raw kubectl polling)"
echo ""
echo "Next: cp $OUT/profile.csv profile.csv  # promote as canonical baseline"
echo "      ./recommend.py --user 300 --product 800 --stress 50"
