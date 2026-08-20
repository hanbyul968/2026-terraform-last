#!/usr/bin/env python3
"""hey CSV 결과를 2026 전국대회 3과제 공식 기준으로 채점한다."""
import csv
import json
import os
import statistics
import sys

import rubric as official

BASELINE_NODES = float(os.environ.get("TUNE_BASELINE_NODES", "2"))
RATE_BANDS = official.RATE_BANDS
COST_LIMITS = official.COST_LIMITS
COST_RATIO_FLOOR = official.COST_RATIO_FLOOR
COST_PERF_GATE = official.COST_PERF_GATE


def parse_slo(value):
    return {kv.split("=")[0]: float(kv.split("=")[1])
            for kv in value.split(",") if kv}


def load(out, slo):
    perf, avail, lats = {}, {}, {}
    for api, limit in slo.items():
        try:
            with open(os.path.join(out, api + ".csv"), encoding="utf-8", errors="replace") as f:
                rows = list(csv.DictReader(f))
        except FileNotFoundError:
            rows = []
        if not rows:
            perf[api], avail[api], lats[api] = 0.0, 0.0, []
            continue
        lat = [float(r["response-time"]) for r in rows]
        ok = [r for r in rows if r["status-code"].startswith("2")
              and float(r["response-time"]) <= 5.0]
        good = [r for r in ok if float(r["response-time"]) <= limit]
        avail[api] = 100.0 * len(ok) / len(rows)
        perf[api] = 100.0 * len(good) / len(rows)
        lats[api] = lat
    return perf, avail, lats


def nodes(out):
    start = end = None
    try:
        with open(os.path.join(out, "loadwindows.csv"), encoding="utf-8-sig", errors="replace") as f:
            windows = list(csv.DictReader(f))
        if windows:
            start = min(int(float(row["start_epoch"])) for row in windows)
            end = max(int(float(row["active_end_epoch"])) for row in windows)
    except (FileNotFoundError, KeyError, ValueError):
        pass
    samples, dropped = [], 0
    try:
        with open(os.path.join(out, "nodes.csv"), encoding="utf-8", errors="replace") as f:
            for row in csv.reader(f):
                try:
                    ts, value = int(row[0]), int(row[1])
                except (ValueError, IndexError):
                    continue
                if value <= 0:
                    dropped += 1
                    continue
                if start is not None and not start <= ts <= end:
                    continue
                samples.append(value)
    except FileNotFoundError:
        pass
    if dropped:
        print(f"  [!] nodes.csv 표본 {dropped}개가 0(측정 실패) 이어서 제외했습니다", file=sys.stderr)
    return samples or [BASELINE_NODES]


def band_points(value):
    return official.band_points(value)


def next_band(value):
    return official.next_band(value)


def cost_points(ratio, perfs):
    return official.cost_points(ratio, perfs)


def rubric(perf, avail, ratio):
    result = official.score(perf, avail, ratio * BASELINE_NODES, BASELINE_NODES)
    return (result.availability_points, result.performance_points, result.cost_points,
            official.legacy_rows(result), result.cost_note)


def score_summary(perf, avail, node_average, focus=None, availability_gate=99.0):
    result = official.score(perf, avail, node_average, BASELINE_NODES, availability_gate)
    focus_perf = perf[focus] if focus in perf else (sum(perf.values()) / len(perf) if perf else 0.0)
    target, gap = official.next_band(focus_perf)
    data = {
        "focus_perf": round(focus_perf, 4),
        "min_perf": round(result.min_performance, 4),
        "min_avail": round(result.min_availability, 4),
        "nodes_avg": round(node_average, 4),
        "cost_ratio": round(result.cost_ratio, 4),
        "availability_points": result.availability_points,
        "performance_points": result.performance_points,
        "cost_points": result.cost_points,
        "total": result.total,
        "perf_gate_pass": result.perf_gate_pass,
        "avail_gate_pass": result.avail_gate_pass,
        "focus_next_band": target,
        "focus_next_gap": round(gap, 4),
        "perfs": perf,
        "availability": avail,
        "cost_note": result.cost_note,
        "rubric_apps": [row.__dict__ for row in result.apps],
    }
    return data


def q_at(latencies, percentile):
    if len(latencies) < 2:
        return latencies[0] if latencies else 0.0
    return statistics.quantiles(latencies, n=100)[percentile]


def main():
    mode = sys.argv[1]
    if mode == "report":
        out, label, slo = sys.argv[2], sys.argv[3], parse_slo(sys.argv[4])
        perf, avail, lats = load(out, slo)
        print(f"\n=== {label} ===")
        print(f"{'api':10} {'n':>6} {'avail%':>7} {'perf%':>6} {'p50':>7} {'p95':>7} {'p99':>7} {'max':>7}")
        for api in slo:
            lat = lats[api]
            if not lat:
                print(f"{api:10} NO DATA")
                continue
            print(f"{api:10} {len(lat):>6} {avail[api]:>6.1f}% {perf[api]:>5.1f}% "
                  f"{q_at(lat,49):>7.3f} {q_at(lat,94):>7.3f} "
                  f"{q_at(lat,98):>7.3f} {max(lat):>7.3f}")
        samples = nodes(out)
        navg = sum(samples) / len(samples)
        result = official.score(perf, avail, navg, BASELINE_NODES)
        print(f"nodes      min={min(samples)} max={max(samples)} avg={navg:.2f}  "
              f"(baseline={BASELINE_NODES:g}, cost ratio {result.cost_ratio:.2f})")
        print()
        print(f"{'채점 환산':10} {'avail%':>7} {'가용성':>6} {'perf%':>7} {'성능':>5}")
        for row in result.apps:
            print(f"{row.app:10} {row.availability:>6.1f}% {row.availability_points:>6.1f} "
                  f"{row.performance:>6.1f}% {row.performance_points:>5.1f}")
        print(f"{'합계':10} {'':>7} {result.availability_points:>6.1f}/12 {'':>7} {result.performance_points:>4.1f}/12")
        print(f"{'비용':10} ratio {result.cost_ratio:.2f} -> {result.cost_points:.1f}/12" +
              (f"   [!] {result.cost_note}" if result.cost_note else ""))
        print(f"{'소계':10} {result.total:.1f}/36  (+ 비정상요청 4점은 verify.ps1 로 확인)")
    elif mode == "score":
        out = sys.argv[2]
        slo = parse_slo(sys.argv[3])
        availability_gate = float(sys.argv[4])
        focus = sys.argv[6] if len(sys.argv) > 6 else None
        perf, avail, _ = load(out, slo)
        samples = nodes(out)
        print(json.dumps(score_summary(perf, avail, sum(samples) / len(samples), focus,
                                       availability_gate), ensure_ascii=True,
                         separators=(",", ":")))
    else:
        sys.exit(f"unknown mode: {mode}")


if __name__ == "__main__":
    main()
