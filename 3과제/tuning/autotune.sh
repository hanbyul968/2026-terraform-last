#!/usr/bin/env bash
# Config-driven auto-tuner. Sweeps tuning combos by patching the LIVE cluster
# (fast, no terraform re-apply), runs the grader-style load test for each,
# scores on the contest rubric (성능효율 + 고가용성 + 비용), declares the winner
# and leaves it applied. Works for whatever app set is in config.env.
#
# Each combo applies a UNIFORM (cpu request, HPA util, min, max) to EVERY app in
# config.env's APIS list — on the day you don't know which API is heavy, so we
# sweep cpu levels and let the load test reveal per-API perf.
#
# Usage: ./autotune.sh <endpoint> [duration]
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
source "$HERE/config.env"
export PATH="$HOME/bin:$PATH"   # CloudShell: hey/kubectl live in ~/bin
EP=${1:?endpoint required}
DUR=${2:-90s}
export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}
command -v hey >/dev/null && command -v kubectl >/dev/null || { echo "ERROR: hey/kubectl 없음 — ./cloudshell-setup.sh 먼저"; exit 1; }
RESULTS=/tmp/autotune-results.csv
echo "combo,avg_perf,min_avail,nodes_avg,score" > "$RESULTS"

# app names from config
APPS=(); for a in "${APIS[@]}"; do IFS='|' read -r n _ <<<"$a"; APPS+=("$n"); done

# --- candidate grid: name | cpu | util | min | max  (applied to every app) ---
COMBOS=(
  "baseline      |300m|55|2|10"
  "lean-cpu      |200m|55|2|10"
  "rich-cpu      |500m|55|2|10"
  "aggressive-hpa|300m|45|3|12"
  "calm-hpa      |300m|65|2|8"
  "cost-min      |200m|65|2|6"
)

patch_all () { # cpu util min max
  for app in "${APPS[@]}"; do
    kubectl -n "$NS" set resources deploy/"$app" --requests=cpu="$1" >/dev/null 2>&1 || true
    kubectl -n "$NS" patch hpa "$app" --type=merge -p \
      "{\"spec\":{\"minReplicas\":$3,\"maxReplicas\":$4,\"metrics\":[{\"type\":\"Resource\",\"resource\":{\"name\":\"cpu\",\"target\":{\"type\":\"Utilization\",\"averageUtilization\":$2}}}]}}" >/dev/null 2>&1 || true
  done
  for app in "${APPS[@]}"; do kubectl -n "$NS" rollout status deploy/"$app" --timeout=180s >/dev/null 2>&1 || true; done
}

SLOS=$(for a in "${APIS[@]}"; do IFS='|' read -r n s _ <<<"$a"; echo "$n=$s"; done | paste -sd, -)
score_trial () { # label
  python3 - "/tmp/tune-$1" "$SLOS" "$AVAIL_GATE" "$COST_PENALTY" <<'PY'
import csv,sys
out,slos,gate,pen=sys.argv[1],sys.argv[2],float(sys.argv[3]),float(sys.argv[4])
slo={kv.split("=")[0]:float(kv.split("=")[1]) for kv in slos.split(",") if kv}
perf={};avail={}
for api,lim in slo.items():
    try: rows=list(csv.DictReader(open(f"{out}/{api}.csv")))
    except FileNotFoundError: rows=[]
    if not rows: perf[api]=0;avail[api]=0;continue
    ok=[r for r in rows if r["status-code"].startswith("2") and float(r["response-time"])<=5.0]
    good=[r for r in ok if float(r["response-time"])<=lim]
    avail[api]=100*len(ok)/len(rows);perf[api]=100*len(good)/len(rows)
ns=[int(l.split(",")[1]) for l in open(f"{out}/nodes.csv") if l.strip()] or [2]
navg=sum(ns)/len(ns);avg=sum(perf.values())/len(perf);mav=min(avail.values())
cost=max(0,(navg-2))*pen;g=0 if mav>=gate else -50
print(f"{avg:.1f} {mav:.1f} {navg:.2f} {avg-cost+g:.1f}")
PY
}

echo "### autotune: ${#COMBOS[@]} combos x $DUR  apps=[${APPS[*]}]  endpoint=$EP"
for row in "${COMBOS[@]}"; do
  IFS='|' read -r name cpu util mn mx <<<"$(echo "$row" | tr -d ' ')"
  echo; echo ">>> combo=$name  cpu=$cpu util=$util replicas=$mn-$mx"
  patch_all "$cpu" "$util" "$mn" "$mx"
  sleep 45   # let HPA/Karpenter settle back toward baseline
  "$HERE/loadtest.sh" "$EP" "$DUR" "$name" >/dev/null 2>&1 || true
  read -r ap ma na sc <<<"$(score_trial "$name")"
  printf "    perf_avg=%s avail_min=%s nodes_avg=%s SCORE=%s\n" "$ap" "$ma" "$na" "$sc"
  echo "$name,$ap,$ma,$na,$sc" >> "$RESULTS"
done

echo; echo "### ranked (higher = better)"
sort -t, -k5 -gr "$RESULTS" | column -t -s,
WNAME=$(tail -n +2 "$RESULTS" | sort -t, -k5 -gr | head -1 | cut -d, -f1)
echo; echo "### WINNER: $WNAME — re-applying to live cluster"
for row in "${COMBOS[@]}"; do
  nm=$(echo "$row" | cut -d'|' -f1 | tr -d ' '); [ "$nm" = "$WNAME" ] || continue
  IFS='|' read -r name cpu util mn mx <<<"$(echo "$row" | tr -d ' ')"
  patch_all "$cpu" "$util" "$mn" "$mx"
  cat <<EOF

### terraform/k8s_apps.tf 반영값 (모든 앱):
  requests.cpu = "$cpu",  HPA averageUtilization = $util,  min=$mn max=$mx
EOF
done
echo; echo "Full results: $RESULTS"
