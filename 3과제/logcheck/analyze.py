#!/usr/bin/env python3
"""
Join k6 raw output + kubectl metrics into a per-app, per-RPS-bucket profile.

Inputs:
  k6.json     : k6 JSON stream (line-per-event)
  metrics.csv : collect.sh output

Outputs:
  profile.csv : columns = app, rps_bucket, samples, p50, p95, p99, err_rate,
                          avg_replicas, avg_cpu_milli, avg_mem_mi, avg_nodes
  report.md   : human-readable summary with capacity thresholds
"""
import json
import sys
import csv
from collections import defaultdict
from statistics import median

K6_PATH, METRICS_PATH, PROFILE_OUT, REPORT_OUT = sys.argv[1:5]

# RPS buckets (per app, per 10-second window)
WINDOW = 10  # seconds
SLA_MS = {'user': 200, 'product': 200, 'stress': 1000}

# --- 1) parse k6.json: stream events tagged by app ---
samples = defaultdict(list)  # (app, window_ts) -> [duration_ms]
errs    = defaultdict(int)   # (app, window_ts) -> error count
reqs    = defaultdict(int)   # (app, window_ts) -> total requests

with open(K6_PATH) as f:
    for line in f:
        try:
            ev = json.loads(line)
        except Exception:
            continue
        if ev.get('type') != 'Point':
            continue
        m = ev.get('metric')
        d = ev.get('data', {})
        tags = d.get('tags') or {}
        app = tags.get('app')
        if not app:
            continue
        ts_iso = d.get('time', '')
        try:
            # 2026-05-17T08:00:01.234Z → epoch
            import datetime
            ts = int(datetime.datetime.fromisoformat(ts_iso.replace('Z', '+00:00')).timestamp())
        except Exception:
            continue
        win = (ts // WINDOW) * WINDOW
        if m == 'http_req_duration':
            samples[(app, win)].append(d['value'])
            reqs[(app, win)] += 1
        elif m == 'http_req_failed' and d['value'] == 1:
            errs[(app, win)] += 1

# --- 2) parse metrics.csv: per-window per-deploy averages ---
mtx = defaultdict(list)  # (deploy, win) -> list of {replicas, cpu, mem, nodes}
with open(METRICS_PATH) as f:
    r = csv.DictReader(f)
    for row in r:
        try:
            ts = int(row['ts'])
            win = (ts // WINDOW) * WINDOW
            mtx[(row['deploy'], win)].append({
                'replicas': float(row.get('replicas_ready') or 0),
                'cpu':      float(row.get('cpu_milli_total') or 0),
                'mem':      float(row.get('mem_mi_total') or 0),
                'nodes':    float(row.get('node_count') or 0),
            })
        except (ValueError, KeyError):
            continue

def avg(xs):
    return (sum(xs) / len(xs)) if xs else 0.0

def pct(xs, p):
    if not xs: return 0.0
    s = sorted(xs)
    k = max(0, min(len(s) - 1, int(round((p / 100.0) * (len(s) - 1)))))
    return s[k]

# --- 3) collapse per-window into RPS buckets ---
RPS_BUCKETS = [10, 25, 50, 100, 200, 400, 700, 1000, 1500]

def bucket_for(rps):
    for b in RPS_BUCKETS:
        if rps <= b:
            return b
    return RPS_BUCKETS[-1]

agg = defaultdict(lambda: {'dur': [], 'reqs': 0, 'errs': 0, 'reps': [], 'cpu': [], 'mem': [], 'nodes': []})

for (app, win), durs in samples.items():
    rps = reqs[(app, win)] / WINDOW
    b = bucket_for(rps)
    key = (app, b)
    agg[key]['dur'].extend(durs)
    agg[key]['reqs'] += reqs[(app, win)]
    agg[key]['errs'] += errs[(app, win)]
    # match deploy = app
    rows = mtx.get((app, win), [])
    for x in rows:
        agg[key]['reps'].append(x['replicas'])
        agg[key]['cpu'].append(x['cpu'])
        agg[key]['mem'].append(x['mem'])
        agg[key]['nodes'].append(x['nodes'])

# --- 4) write profile.csv ---
with open(PROFILE_OUT, 'w') as f:
    w = csv.writer(f)
    w.writerow(['app', 'rps_bucket', 'samples', 'p50_ms', 'p95_ms', 'p99_ms',
                'err_rate', 'avg_replicas', 'avg_cpu_milli', 'avg_mem_mi', 'avg_nodes'])
    rows = []
    for (app, b), v in sorted(agg.items()):
        if not v['dur']:
            continue
        rows.append([
            app, b, len(v['dur']),
            round(pct(v['dur'], 50), 1),
            round(pct(v['dur'], 95), 1),
            round(pct(v['dur'], 99), 1),
            round(v['errs'] / max(1, v['reqs']), 4),
            round(avg(v['reps']), 2),
            round(avg(v['cpu']), 1),
            round(avg(v['mem']), 1),
            round(avg(v['nodes']), 2),
        ])
    for row in rows:
        w.writerow(row)

# --- 5) report.md with capacity thresholds ---
lines = []
lines.append('# Load Profile Report\n')
lines.append(f'- buckets (RPS): {RPS_BUCKETS}\n- window: {WINDOW}s\n')

for app in ['user', 'product', 'stress']:
    rows = [r for r in agg if r[0] == app and agg[r]['dur']]
    if not rows:
        lines.append(f'\n## {app}\n_no data_\n')
        continue
    lines.append(f'\n## {app}  (SLA p95 ≤ {SLA_MS[app]}ms)\n')
    lines.append('| RPS bucket | samples | p50 | p95 | p99 | err | replicas | cpu(m) | mem(Mi) | nodes |')
    lines.append('|---|---|---|---|---|---|---|---|---|---|')
    sla_cap = None
    for (a, b) in sorted(rows, key=lambda x: x[1]):
        v = agg[(a, b)]
        p95 = pct(v['dur'], 95)
        line = f"| {b} | {len(v['dur'])} | {pct(v['dur'],50):.0f} | {p95:.0f} | {pct(v['dur'],99):.0f} | {v['errs']/max(1,v['reqs']):.2%} | {avg(v['reps']):.1f} | {avg(v['cpu']):.0f} | {avg(v['mem']):.0f} | {avg(v['nodes']):.1f} |"
        lines.append(line)
        if sla_cap is None and p95 > SLA_MS[app]:
            sla_cap = b
    if sla_cap:
        lines.append(f'\n**SLA breach at**: ~{sla_cap} RPS (p95 exceeds {SLA_MS[app]}ms)')
    else:
        lines.append(f'\n**SLA holds across entire tested range** (max bucket: {max(b for _, b in rows)} RPS)')

with open(REPORT_OUT, 'w') as f:
    f.write('\n'.join(lines))

print(f'wrote {PROFILE_OUT} and {REPORT_OUT}')
