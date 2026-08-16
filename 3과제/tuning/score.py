#!/usr/bin/env python3
"""hey CSV 결과 채점기 (loadtest.ps1 / autotune*.ps1 공용).

bash 판에서 각 스크립트에 인라인(heredoc)으로 들어있던 파이썬을 한 파일로 뺐다.
Windows 에는 heredoc 이 없으므로 파일로 분리하는 편이 깔끔하다.

사용법:
  python score.py report <outdir> <label> <slos>
  python score.py score  <outdir> <slos> <avail_gate> <cost_penalty> [focus_app]

  <slos> = "user=0.2,product=0.2,stress=1.0"
  [focus_app] : 지정하면 perf 를 전체 평균 대신 그 앱의 perf 로 계산
                (autotune.ps1 -App <앱> 앱별 튜닝 모드가 사용).
                가용성 게이트는 여전히 모든 앱의 최소값 기준 — 다른 앱을 죽이는
                조합이 이기지 못하게 한다.
"""
import csv
import os
import sys
import statistics

# 비용 패널티 기준선(노드 수). config.ps1 이 $COST_BASELINE_NODES 로 전달한다.
# terraform node_desired_size 와 맞아야 한다 (기본 1).
# 기본값은 terraform node_desired_size 와 같게 둔다(현재 2). config.ps1 이 환경변수로
# 넘기지만, score.py 를 직접 호출할 때도 틀린 기준으로 채점하지 않게 하기 위한 것.
BASELINE_NODES = float(os.environ.get("TUNE_BASELINE_NODES", "2"))


def parse_slo(s):
    return {kv.split("=")[0]: float(kv.split("=")[1]) for kv in s.split(",") if kv}


def load(out, slo):
    perf, avail, lats = {}, {}, {}
    for api, lim in slo.items():
        try:
            rows = list(csv.DictReader(open(f"{out}/{api}.csv")))
        except FileNotFoundError:
            rows = []
        if not rows:
            perf[api] = 0; avail[api] = 0; lats[api] = []
            continue
        lat = [float(r["response-time"]) for r in rows]
        ok = [r for r in rows if r["status-code"].startswith("2") and float(r["response-time"]) <= 5.0]
        good = [r for r in ok if float(r["response-time"]) <= lim]
        avail[api] = 100 * len(ok) / len(rows)
        perf[api] = 100 * len(good) / len(rows)
        lats[api] = lat
    return perf, avail, lats


def nodes(out):
    try:
        ns = [int(l.split(",")[1]) for l in open(f"{out}/nodes.csv") if l.strip()]
    except FileNotFoundError:
        ns = []
    # kubectl 이 없어 샘플이 없으면 기준선으로 가정 (비용 패널티 0).
    return ns or [BASELINE_NODES]


def q_at(lat, pct):
    if len(lat) < 2:
        return lat[0] if lat else 0.0
    return statistics.quantiles(lat, n=100)[pct]


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
                  f"{q_at(lat,49):>7.3f} {q_at(lat,94):>7.3f} {q_at(lat,98):>7.3f} {max(lat):>7.3f}")
        ns = nodes(out)
        print(f"nodes      min={min(ns)} max={max(ns)} avg={sum(ns)/len(ns):.2f}  "
              f"(baseline={BASELINE_NODES:g}, 초과분 {max(0, sum(ns)/len(ns)-BASELINE_NODES):.2f} 대가 비용 패널티)")
    elif mode == "score":
        out, slo, gate, pen = sys.argv[2], parse_slo(sys.argv[3]), float(sys.argv[4]), float(sys.argv[5])
        focus = sys.argv[6] if len(sys.argv) > 6 else None
        perf, avail, _ = load(out, slo)
        ns = nodes(out); navg = sum(ns) / len(ns)
        avg = perf[focus] if focus in perf else sum(perf.values()) / len(perf)
        mav = min(avail.values())
        cost = max(0, (navg - BASELINE_NODES)) * pen; g = 0 if mav >= gate else -50
        print(f"{avg:.1f} {mav:.1f} {navg:.2f} {avg-cost+g:.1f}")
    else:
        sys.exit(f"unknown mode: {mode}")


if __name__ == "__main__":
    main()
