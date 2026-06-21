#!/bin/bash
# Polls cluster every INTERVAL sec while k6 runs.
# Writes a single wide CSV (timestamp + per-deploy replicas/CPU + HPA + node count).
#
# Usage: ./collect.sh <namespace> <output.csv> [interval_sec]
set -u

NS="${1:-app}"
OUT="${2:-out/metrics.csv}"
INTERVAL="${3:-10}"
KARGS="--request-timeout=5s"
[ -n "${KCTX:-}" ] && KARGS="$KARGS --context $KCTX"
CTX_ARG="$KARGS"

mkdir -p "$(dirname "$OUT")"

# header
echo "ts,deploy,replicas_desired,replicas_ready,cpu_milli_total,mem_mi_total,hpa_current_replicas,hpa_desired_replicas,hpa_cpu_pct,node_count,pending_pods" > "$OUT"

DEPLOYS=(user product stress)

trap 'echo "[collect] stopping"; exit 0' INT TERM

echo "[collect] ns=$NS interval=${INTERVAL}s out=$OUT"

while true; do
  TS=$(date +%s)

  # node count + pending
  NODES=$(kubectl $CTX_ARG get nodes -o json 2>/dev/null | jq '[.items[]] | length')
  PENDING=$(kubectl $CTX_ARG get pods -n "$NS" -o json 2>/dev/null | jq '[.items[] | select(.status.phase=="Pending")] | length')
  NODES="${NODES:-0}"; PENDING="${PENDING:-0}"

  # all pods JSON + top pods (single shot)
  PODS_JSON=$(kubectl $CTX_ARG get pods -n "$NS" -o json 2>/dev/null)
  TOP_RAW=$(kubectl $CTX_ARG top pods -n "$NS" --no-headers 2>/dev/null)

  for D in "${DEPLOYS[@]}"; do
    # deploy status
    DEP=$(kubectl $CTX_ARG get deploy "$D" -n "$NS" -o json 2>/dev/null)
    DESIRED=$(echo "$DEP"  | jq '.spec.replicas // 0' 2>/dev/null)
    READY=$(echo "$DEP"    | jq '.status.readyReplicas // 0' 2>/dev/null)

    # sum CPU/mem across pods of this deploy
    # match pods whose name starts with deploy- (ReplicaSet appends hash)
    CPU_TOT=$(echo "$TOP_RAW" | awk -v d="$D" 'index($1, d"-")==1 {gsub(/m/,"",$2); s+=$2} END{print s+0}')
    MEM_TOT=$(echo "$TOP_RAW" | awk -v d="$D" 'index($1, d"-")==1 {gsub(/Mi/,"",$3); s+=$3} END{print s+0}')

    # HPA
    HPA=$(kubectl $CTX_ARG get hpa "$D" -n "$NS" -o json 2>/dev/null)
    HPA_CUR=$(echo "$HPA"  | jq '.status.currentReplicas // 0' 2>/dev/null)
    HPA_DES=$(echo "$HPA"  | jq '.status.desiredReplicas // 0' 2>/dev/null)
    HPA_CPU=$(echo "$HPA"  | jq '.status.currentMetrics[0].resource.current.averageUtilization // 0' 2>/dev/null)

    : "${DESIRED:=0}"; : "${READY:=0}"; : "${HPA_CUR:=0}"; : "${HPA_DES:=0}"; : "${HPA_CPU:=0}"

    echo "$TS,$D,$DESIRED,$READY,$CPU_TOT,$MEM_TOT,$HPA_CUR,$HPA_DES,$HPA_CPU,$NODES,$PENDING" >> "$OUT"
  done

  sleep "$INTERVAL"
done
