#!/usr/bin/env python3
"""hey CSV 결과를 2026 전국대회 3과제 공식 기준으로 채점한다.

사용법:
  python score.py report <outdir> <label> <slos>
  python score.py score  <outdir> <slos> <avail_gate> <cost_penalty> [focus_app]

score 모드는 autotune이 숫자 위치를 잘못 해석하지 않도록 JSON을 출력한다.
"""
import csv
import json
import os
import statistics
import sys

BASELINE_NODES = float(os.environ.get("TUNE_BASELINE_NODES", "2"))

# 공식 누적 점수 구간. 각 구간 통과 시 앱별 0.5점.
RATE_BANDS = [90.0, 87.5, 85.0, 82.5, 80.0, 70.0, 50.0, 30.0]
COST_LIMITS = [1.00, 1.25, 1.50, 1.75, 2.00, 2.25,
               2.50, 2.75, 3.00, 3.25, 3.50, 3.75]
COST_RATIO_FLOOR = 0.50
COST_PERF_GATE = 30.0


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
            perf[api] = 0.0
            avail[api] = 0.0
            lats[api] = []
            continue
        lat = [float(r["response-time"]) for r in rows]
        ok = [r for r in rows
              if r["status-code"].startswith("2") and float(r["response-time"]) <= 5.0]
        good = [r for r in ok if float(r["response-time"]) <= limit]
        avail[api] = 100.0 * len(ok) / len(rows)
        perf[api] = 100.0 * len(good) / len(rows)
        lats[api] = lat
    return perf, avail, lats


def nodes(out):
    """활성 부하창의 정상 노드 표본만 사용한다.

    0은 kubectl 실패이므로 버리고, loadwindows 밖 표본도 버린다. 고아 sampler가 부하 종료
    뒤 2노드 유휴값을 계속 append하면 평균 비용이 실제보다 좋아지는 문제를 막는다.
    """
    start = end = None
    try:
        with open(os.path.join(out, "loadwindows.csv"), encoding="utf-8-sig", errors="replace") as f:
            windows = list(csv.DictReader(f))
        if windows:
            start = min(int(float(row["start_epoch"])) for row in windows)
            end = max(int(float(row["active_end_epoch"])) for row in windows)
    except (FileNotFoundError, KeyError, ValueError):
        pass
    samples = []
    dropped = 0
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
        print(f"  [!] nodes.csv 표본 {dropped}개가 0(측정 실패) 이어서 제외했습니다",
              file=sys.stderr)
    return samples or [BASELINE_NODES]


def band_points(value):
    return 0.5 * sum(1 for threshold in RATE_BANDS if value >= threshold)


def next_band(value):
    """현재 값보다 높은 다음 공식 성능 구간과 필요한 %p. 90% 이상이면 (90, 0)."""
    for threshold in sorted(RATE_BANDS):
        if value < threshold:
            return threshold, threshold - value
    return max(RATE_BANDS), 0.0


def cost_points(ratio, perfs):
    if ratio < COST_RATIO_FLOOR:
        return 0.0, "ratio %.2f < %.2f (하한 미달)" % (ratio, COST_RATIO_FLOOR)
    bad = [api for api, value in perfs.items() if value < COST_PERF_GATE]
    if bad:
        return 0.0, "성능 30%% 미달: %s -> 비용 전체 0점" % ", ".join(sorted(bad))
    return float(sum(1 for limit in COST_LIMITS if ratio <= limit)), ""


def rubric(perf, avail, ratio):
    rows = []
    availability_points = performance_points = 0.0
    for api in sorted(avail):
        ap = band_points(avail[api])
        pp = band_points(perf[api])
        availability_points += ap
        performance_points += pp
        rows.append((api, avail[api], ap, perf[api], pp))
    cp, note = cost_points(ratio, perf)
    return availability_points, performance_points, cp, rows, note


def score_summary(perf, avail, node_average, focus=None, availability_gate=99.0):
    ratio = node_average / BASELINE_NODES if BASELINE_NODES else 0.0
    av_points, pf_points, cp, _rows, note = rubric(perf, avail, ratio)
    focus_perf = perf[focus] if focus in perf else sum(perf.values()) / len(perf)
    min_perf = min(perf.values()) if perf else 0.0
    min_avail = min(avail.values()) if avail else 0.0
    next_target, next_gap = next_band(focus_perf)
    return {
        "focus_perf": round(focus_perf, 4),
        "min_perf": round(min_perf, 4),
        "min_avail": round(min_avail, 4),
        "nodes_avg": round(node_average, 4),
        "cost_ratio": round(ratio, 4),
        "availability_points": av_points,
        "performance_points": pf_points,
        "cost_points": cp,
        "total": av_points + pf_points + cp,
        "perf_gate_pass": bool(perf) and min_perf >= COST_PERF_GATE,
        "avail_gate_pass": bool(avail) and min_avail >= availability_gate,
        "focus_next_band": next_target,
        "focus_next_gap": round(next_gap, 4),
        "perfs": perf,
        "availability": avail,
        "cost_note": note,
    }


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
        ratio = navg / BASELINE_NODES if BASELINE_NODES else 0.0
        print(f"nodes      min={min(samples)} max={max(samples)} avg={navg:.2f}  "
              f"(baseline={BASELINE_NODES:g}, cost ratio {ratio:.2f})")
        avp, pfp, cp, rows, note = rubric(perf, avail, ratio)
        print()
        print(f"{'채점 환산':10} {'avail%':>7} {'가용성':>6} {'perf%':>7} {'성능':>5}")
        for api, av, ap, pv, pp in rows:
            print(f"{api:10} {av:>6.1f}% {ap:>6.1f} {pv:>6.1f}% {pp:>5.1f}")
        print(f"{'합계':10} {'':>7} {avp:>6.1f}/12 {'':>7} {pfp:>4.1f}/12")
        print(f"{'비용':10} ratio {ratio:.2f} -> {cp:.1f}/12" +
              (f"   [!] {note}" if note else ""))
        print(f"{'소계':10} {avp + pfp + cp:.1f}/36  (+ 비정상요청 4점은 verify.ps1 로 확인)")
    elif mode == "score":
        out = sys.argv[2]
        slo = parse_slo(sys.argv[3])
        availability_gate = float(sys.argv[4])
        # sys.argv[5] cost_penalty는 예전 호출 계약 호환용이다. 공식 구간식에는 쓰지 않는다.
        focus = sys.argv[6] if len(sys.argv) > 6 else None
        perf, avail, _ = load(out, slo)
        samples = nodes(out)
        navg = sum(samples) / len(samples)
        print(json.dumps(score_summary(perf, avail, navg, focus, availability_gate),
                         ensure_ascii=False, separators=(",", ":")))
    else:
        sys.exit(f"unknown mode: {mode}")


if __name__ == "__main__":
    main()
