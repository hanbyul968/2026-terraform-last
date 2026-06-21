#!/usr/bin/env bash
# Grader-style load test, config-driven.
# Reads the API list / SLOs / load shape from config.env, so the SAME script
# works for whatever application you get on competition day — just edit config.
#
# Usage: ./loadtest.sh <endpoint> [duration e.g. 180s] [label]
# Scores each API like the contest: availability (2xx within 5s) and
# performance (response-time <= per-API SLO), plus a node-count timeline.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
source "$HERE/config.env"
export PATH="$HOME/bin:$PATH"   # CloudShell: hey/kubectl live in ~/bin
EP=${1:?endpoint}; DUR=${2:-180s}; LABEL=${3:-run}
OUT=/tmp/tune-$LABEL; mkdir -p "$OUT"
export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}
command -v hey >/dev/null     || { echo "ERROR: hey 없음 — 먼저 ./cloudshell-setup.sh <cluster> <region> 실행"; exit 1; }
command -v kubectl >/dev/null || echo "WARN: kubectl 없음 — 노드 샘플링 생략(가용성/성능은 정상 측정)"

# --- node/pod sampler (5s interval) ---
(
  while true; do
    N=$(kubectl get nodes --no-headers 2>/dev/null | grep -c Ready || true)
    P=$(kubectl -n "$NS" get pods --no-headers 2>/dev/null | grep -c Running || true)
    echo "$(date +%s),$N,$P"
    sleep 5
  done
) > "$OUT/nodes.csv" &
SAMPLER=$!
trap 'kill $SAMPLER 2>/dev/null || true' EXIT

# --- seed records (idempotent) ---
for s in "${SEEDS[@]}"; do
  IFS='|' read -r m path body <<<"$s"
  if [ "$m" = GET ]; then
    curl -s -o /dev/null "$EP$path" || true
  else
    curl -s -o /dev/null -X "$m" "$EP$path" -H 'Content-Type: application/json' -d "$body" || true
  fi
done

# --- load: every API in parallel ---
for a in "${APIS[@]}"; do
  IFS='|' read -r name slo conc qps method path body <<<"$a"
  if [ "$method" = GET ]; then
    hey -z "$DUR" -c "$conc" -q "$qps" -o csv "$EP$path" \
      > "$OUT/$name.csv" 2>"$OUT/$name.err" &
  else
    hey -z "$DUR" -c "$conc" -q "$qps" -m "$method" -T application/json -d "$body" -o csv \
      "$EP$path" > "$OUT/$name.csv" 2>"$OUT/$name.err" &
  fi
done
wait $(jobs -p | grep -v "$SAMPLER") 2>/dev/null || true
kill $SAMPLER 2>/dev/null || true

# --- score (SLOs come from config via APIS) ---
SLOS=$(for a in "${APIS[@]}"; do IFS='|' read -r n s _ <<<"$a"; echo "$n=$s"; done | paste -sd, -)
python3 - "$OUT" "$LABEL" "$SLOS" <<'EOF'
import csv, sys, statistics
out, label, slos = sys.argv[1], sys.argv[2], sys.argv[3]
slo = {kv.split("=")[0]: float(kv.split("=")[1]) for kv in slos.split(",") if kv}
print(f"\n=== {label} ===")
print(f"{'api':10} {'n':>6} {'avail%':>7} {'perf%':>6} {'p50':>7} {'p95':>7} {'p99':>7} {'max':>7}")
for api, lim in slo.items():
    try: rows = list(csv.DictReader(open(f"{out}/{api}.csv")))
    except FileNotFoundError: rows = []
    if not rows: print(f"{api:10} NO DATA"); continue
    lat = [float(r["response-time"]) for r in rows]
    ok = [r for r in rows if r["status-code"].startswith("2") and float(r["response-time"]) <= 5.0]
    perf = [r for r in ok if float(r["response-time"]) <= lim]
    q = statistics.quantiles(lat, n=100)
    print(f"{api:10} {len(rows):>6} {100*len(ok)/len(rows):>6.1f}% {100*len(perf)/len(rows):>5.1f}% "
          f"{q[49]:>7.3f} {q[94]:>7.3f} {q[98]:>7.3f} {max(lat):>7.3f}")
nodes = [l.strip().split(",") for l in open(f"{out}/nodes.csv") if l.strip()]
ns = [int(n[1]) for n in nodes] or [2]
print(f"nodes      min={min(ns)} max={max(ns)} avg={sum(ns)/len(ns):.2f}  (cost proxy avg/2 = {sum(ns)/len(ns)/2:.2f})")
EOF
