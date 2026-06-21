#!/usr/bin/env bash
# Config-driven hill-climbing refiner. Starts from a point and refines two
# uniform knobs (cpu request, HPA util) applied to every app in config.env.
# Cleaner measurement than autotune.sh: DRAINS nodes toward baseline before each
# trial (waits for Karpenter consolidation) and runs a longer load.
#
# Knobs: cpu (step 100m, [100..1000]), util (step 5, [40..75]).
# Usage: ./autotune-hc.sh <endpoint> [duration] [start_cpu] [start_util] [max_moves]
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
source "$HERE/config.env"
export PATH="$HOME/bin:$PATH"   # CloudShell: hey/kubectl live in ~/bin
EP=${1:?endpoint required}; DUR=${2:-120s}
CPU=${3:-300}; UTIL=${4:-55}; MAXMOVES=${5:-4}
export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}
command -v hey >/dev/null && command -v kubectl >/dev/null || { echo "ERROR: hey/kubectl 없음 — ./cloudshell-setup.sh 먼저"; exit 1; }
LOG=/tmp/autotune-hc-results.csv
echo "trial,cpu,util,avg_perf,min_avail,nodes_avg,score" > "$LOG"

APPS=(); for a in "${APIS[@]}"; do IFS='|' read -r n _ <<<"$a"; APPS+=("$n"); done
SLOS=$(for a in "${APIS[@]}"; do IFS='|' read -r n s _ <<<"$a"; echo "$n=$s"; done | paste -sd, -)
TRIAL=0
ccpu(){ local v=$1;((v<100))&&v=100;((v>1000))&&v=1000;echo $v;}
cutil(){ local v=$1;((v<40))&&v=40;((v>75))&&v=75;echo $v;}

apply_state(){ # cpu util
  for app in "${APPS[@]}"; do
    kubectl -n "$NS" set resources deploy/"$app" --requests=cpu=${1}m >/dev/null 2>&1 || true
    kubectl -n "$NS" patch hpa "$app" --type=merge -p \
      "{\"spec\":{\"minReplicas\":2,\"maxReplicas\":10,\"metrics\":[{\"type\":\"Resource\",\"resource\":{\"name\":\"cpu\",\"target\":{\"type\":\"Utilization\",\"averageUtilization\":$2}}}]}}" >/dev/null 2>&1 || true
  done
  for app in "${APPS[@]}"; do kubectl -n "$NS" rollout status deploy/"$app" --timeout=180s >/dev/null 2>&1 || true; done
}
drain(){
  echo "    draining nodes to baseline..."
  for i in $(seq 1 36); do
    n=$(kubectl get nodes --no-headers 2>/dev/null | grep -c Ready || echo 9)
    [ "$n" -le 3 ] && { echo "    drained to $n"; return; }; sleep 5
  done; echo "    drain timeout"
}
eval_state(){ # cpu util -> echoes score
  TRIAL=$((TRIAL+1)); local label="hc${TRIAL}_${1}_${2}"
  apply_state "$1" "$2"; drain
  "$HERE/loadtest.sh" "$EP" "$DUR" "$label" >/dev/null 2>&1 || true
  read -r ap ma na sc <<<"$(python3 - "/tmp/tune-$label" "$SLOS" "$AVAIL_GATE" "$COST_PENALTY" <<'PY'
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
print(f"{avg:.1f} {mav:.1f} {navg:.2f} {avg-max(0,(navg-2))*pen+(0 if mav>=gate else -50):.1f}")
PY
)"
  echo "$TRIAL,$1,$2,$ap,$ma,$na,$sc" >> "$LOG"
  printf "    trial%-2s cpu=%s util=%s -> perf=%s avail=%s nodes=%s SCORE=%s\n" "$TRIAL" "$1" "$2" "$ap" "$ma" "$na" "$sc"
  echo "$sc"
}

echo "### hill-climb from cpu=$CPU util=$UTIL  (dur=$DUR, max moves=$MAXMOVES, apps=[${APPS[*]}])"
BEST=$(eval_state $CPU $UTIL); moves=0
while [ $moves -lt $MAXMOVES ]; do
  improved=0
  for cand in "$(ccpu $((CPU+100))) $UTIL" "$(ccpu $((CPU-100))) $UTIL" \
              "$CPU $(cutil $((UTIL+5)))" "$CPU $(cutil $((UTIL-5)))"; do
    read -r c u <<<"$cand"
    [ "$c" = "$CPU" ] && [ "$u" = "$UTIL" ] && continue
    echo ">>> try cpu=$c util=$u (best $BEST)"
    sc=$(eval_state $c $u)
    if awk "BEGIN{exit !($sc > $BEST)}"; then
      echo "    ^ improves -> MOVE"; BEST=$sc; CPU=$c; UTIL=$u; improved=1; moves=$((moves+1)); break
    fi
  done
  [ $improved -eq 0 ] && { echo "### local optimum"; break; }
done
echo; echo "### BEST: cpu=${CPU}m util=$UTIL  score=$BEST"
apply_state $CPU $UTIL
echo "### terraform: requests.cpu=\"${CPU}m\", HPA averageUtilization=$UTIL (all apps)"
echo "All trials: $LOG"; column -t -s, "$LOG"
