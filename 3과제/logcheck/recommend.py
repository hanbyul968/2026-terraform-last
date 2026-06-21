#!/usr/bin/env python3
"""
Inverse lookup: given expected peak RPS per app, recommend pods / nodes / HPA / Karpenter config.

Reads profile.csv (built by analyze.py) and interpolates resource needs.

Usage:
  ./recommend.py --user 300 --product 800 --stress 50
  ./recommend.py --user 300 --product 800 --stress 50 --safety 1.3 --mode ha
  ./recommend.py --profile out/20260517-080000/profile.csv --user 300 ...

Modes:
  cost (default) — minimize pods/nodes within SLA + safety margin
  ha             — enforce >= 2 pods per app, >= 3 nodes total
"""
import argparse
import csv
import sys
from collections import defaultdict

SLA_MS = {'user': 200, 'product': 200, 'stress': 1000}
# t3.medium allocatable (after kube + system overhead)
NODE_CPU_M    = 1800   # 2 vCPU = 2000m, leave ~200m for kubelet/cni
NODE_MEM_MI   = 3500   # 4Gi ~3.5Gi allocatable
SYS_CPU_M     = 600    # kube-system + alb-controller + karpenter
SYS_MEM_MI    = 800

def load_profile(path):
    by_app = defaultdict(list)
    with open(path) as f:
        for row in csv.DictReader(f):
            by_app[row['app']].append({
                'rps':      float(row['rps_bucket']),
                'p95':      float(row['p95_ms']),
                'err':      float(row['err_rate']),
                'replicas': float(row['avg_replicas']) or 1.0,
                'cpu':      float(row['avg_cpu_milli']),
                'mem':      float(row['avg_mem_mi']),
            })
    for a in by_app:
        by_app[a].sort(key=lambda r: r['rps'])
    return by_app

def find_capacity_per_pod(rows, sla_ms):
    """Walk buckets, return (rps_per_pod, cpu_per_pod, mem_per_pod) at the highest bucket still meeting SLA."""
    best = None
    for r in rows:
        if r['p95'] <= sla_ms and r['replicas'] > 0:
            best = r
    if best is None:
        # SLA never met — use the smallest bucket and warn
        best = rows[0] if rows else None
    if best is None:
        return None
    return {
        'rps_per_pod': best['rps'] / best['replicas'],
        'cpu_per_pod': best['cpu'] / best['replicas'],
        'mem_per_pod': best['mem'] / best['replicas'],
        'measured_at_rps': best['rps'],
        'measured_p95':    best['p95'],
        'measured_replicas': best['replicas'],
        'extrapolated':    False,
    }

def recommend_pods(target_rps, per_pod, safety):
    eff = per_pod['rps_per_pod']
    if eff <= 0:
        return 0
    raw = target_rps / eff
    return max(1, int(-(-raw * safety // 1)))  # ceil

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--profile', default='profile.csv')
    ap.add_argument('--user',    type=float, required=True, help='expected peak RPS for user')
    ap.add_argument('--product', type=float, required=True, help='expected peak RPS for product')
    ap.add_argument('--stress',  type=float, required=True, help='expected peak RPS for stress')
    ap.add_argument('--safety',  type=float, default=1.2, help='safety multiplier (default 1.2 = +20%%)')
    ap.add_argument('--mode',    choices=['cost', 'ha'], default='cost')
    args = ap.parse_args()

    try:
        prof = load_profile(args.profile)
    except FileNotFoundError:
        print(f'error: {args.profile} not found. Run ./run.sh first to generate it.', file=sys.stderr)
        sys.exit(1)

    targets = {'user': args.user, 'product': args.product, 'stress': args.stress}
    min_replicas = 2 if args.mode == 'ha' else 1
    min_nodes    = 3 if args.mode == 'ha' else 2

    per_app = {}
    for app, rps in targets.items():
        rows = prof.get(app, [])
        if not rows:
            print(f'warning: no profile data for {app}, skipping', file=sys.stderr)
            continue
        cap = find_capacity_per_pod(rows, SLA_MS[app])
        if cap is None:
            continue
        # check extrapolation
        max_measured = max(r['rps'] for r in rows)
        extrapolating = rps > max_measured
        pods = max(min_replicas, recommend_pods(rps, cap, args.safety))
        per_app[app] = {
            'target_rps':   rps,
            'pods':         pods,
            'cpu_per_pod':  cap['cpu_per_pod'],
            'mem_per_pod':  cap['mem_per_pod'],
            'total_cpu_m':  pods * cap['cpu_per_pod'],
            'total_mem_mi': pods * cap['mem_per_pod'],
            'measured_at':  cap['measured_at_rps'],
            'measured_p95': cap['measured_p95'],
            'extrapolated': extrapolating,
            'max_measured': max_measured,
            'rps_per_pod':  cap['rps_per_pod'],
        }

    # cluster sizing
    total_cpu = sum(v['total_cpu_m']  for v in per_app.values()) + SYS_CPU_M
    total_mem = sum(v['total_mem_mi'] for v in per_app.values()) + SYS_MEM_MI
    nodes_cpu = -(-total_cpu // NODE_CPU_M)
    nodes_mem = -(-total_mem // NODE_MEM_MI)
    nodes = max(min_nodes, int(max(nodes_cpu, nodes_mem)))

    # output
    print(f'\n=== Capacity recommendation (mode={args.mode}, safety={args.safety:.0%}) ===\n')
    print(f'{"App":<10} {"Target RPS":>10} {"Pods":>5} {"CPU/pod":>9} {"Mem/pod":>9} {"Total CPU":>10} {"Total Mem":>10}  Note')
    print('-' * 100)
    for app, v in per_app.items():
        note = ''
        if v['extrapolated']:
            note = f'⚠ extrapolated (max measured: {v["max_measured"]:.0f} RPS)'
        print(f'{app:<10} {v["target_rps"]:>10.0f} {v["pods"]:>5d} {v["cpu_per_pod"]:>7.0f}m {v["mem_per_pod"]:>7.0f}Mi {v["total_cpu_m"]:>8.0f}m {v["total_mem_mi"]:>8.0f}Mi  {note}')

    print(f'\n=== Cluster sizing (t3.medium, alloc {NODE_CPU_M}m / {NODE_MEM_MI}Mi) ===')
    print(f'  app CPU total : {sum(v["total_cpu_m"] for v in per_app.values()):.0f}m')
    print(f'  app Mem total : {sum(v["total_mem_mi"] for v in per_app.values()):.0f}Mi')
    print(f'  system overhead: {SYS_CPU_M}m / {SYS_MEM_MI}Mi')
    print(f'  → recommended nodes: {nodes} (CPU={nodes_cpu:.0f}, Mem={nodes_mem:.0f}, min={min_nodes})')

    print(f'\n=== HPA suggestions ===')
    for app, v in per_app.items():
        # target CPU% = (avg_used / pod_cpu_request) where request = ceil(cpu_per_pod * 1.5)
        req_m = max(100, int(((v['cpu_per_pod'] * 1.5) // 50 + 1) * 50))
        target_pct = max(50, min(80, int((v['cpu_per_pod'] / req_m) * 100)))
        min_r = max(min_replicas, max(2, v['pods'] // 3))
        max_r = max(v['pods'] * 2, v['pods'] + 2)
        print(f'  {app:<8} request={req_m}m  minReplicas={min_r}  maxReplicas={max_r}  targetCPU={target_pct}%')

    print(f'\n=== Karpenter NodePool suggestion ===')
    print(f'  instanceType: [t3.medium]')
    print(f'  cpu limit: {nodes * 2}  (t3.medium = 2 vCPU each)')
    print(f'  consolidation: WhenUnderutilized')

    if any(v['extrapolated'] for v in per_app.values()):
        print(f'\n⚠ Warning: one or more targets exceed measured RPS range. Re-run ./run.sh full for higher confidence.')

if __name__ == '__main__':
    main()
