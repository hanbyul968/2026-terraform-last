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
    """nodes.csv 의 노드 수 표본. 0 은 '측정 실패'이므로 제외한다.

    노드가 0대인 상황은 존재하지 않는다. 옛 loadtest 는 kubectl 조회 실패 시 0 을
    기록했고, 그 0 이 평균에 섞여 비용 지표를 실제보다 좋게 만들었다.
      실측: 3399 표본 중 1370개가 0 -> 평균 2.28대(ratio 1.14) 로 보였지만
            0 을 빼면 3.82대(ratio 1.91) 였다. 비용 점수가 11점 -> 9점으로 달라진다.
    """
    try:
        ns = [int(l.split(",")[1]) for l in open(f"{out}/nodes.csv") if l.strip()]
    except FileNotFoundError:
        ns = []
    dropped = sum(1 for v in ns if v <= 0)
    ns = [v for v in ns if v > 0]
    if dropped:
        print(f"  [!] nodes.csv 표본 {dropped}개가 0(측정 실패) 이어서 제외했습니다", file=sys.stderr)
    # kubectl 이 없어 샘플이 없으면 기준선으로 가정 (비용 패널티 0).
    return ns or [BASELINE_NODES]


# ---------- 실제 채점기준 (2026 전국대회 3과제, 40점) ----------
# 채점기준표를 그대로 옮긴 것. 기존 점수함수(perf% - 노드초과x6)는 선형 근사여서
# autotune 이 실제 점수와 다른 조합을 우승으로 뽑았다.
#
# 2. 고가용성 12점 : 앱별 availability 가 아래 구간을 넘을 때마다 0.5점 (누적, 앱당 최대 4점)
# 3. 성능     12점 : 앱별 performance 도 같은 구간 (앱당 최대 4점)
# 4. 비용     12점 : cost ratio 가 각 상한 이하일 때마다 1점 (누적, 최대 12점)
#                    단 ratio >= 0.50 이어야 하고, 세 앱 performance 가 모두 30% 이상이어야
#                    비용 점수가 인정된다. 하나라도 30% 미달이면 비용 12점 전부 0.
# 1. 비정상요청 4점 : image download / Exception Handling (loadtest 로는 측정 못함 -> verify.ps1)
RATE_BANDS = [90.0, 87.5, 85.0, 82.5, 80.0, 70.0, 50.0, 30.0]  # 각 0.5점
COST_LIMITS = [1.00, 1.25, 1.50, 1.75, 2.00, 2.25, 2.50, 2.75, 3.00, 3.25, 3.50, 3.75]  # 각 1점
COST_RATIO_FLOOR = 0.50
COST_PERF_GATE = 30.0


def band_points(value):
    """비율(%) -> 점수. 넘는 구간마다 0.5점 누적 (최대 4.0)."""
    return 0.5 * sum(1 for b in RATE_BANDS if value >= b)


def cost_points(ratio, perfs):
    """cost ratio -> 점수. ratio 하한과 '세 앱 성능 30% 이상' 조건을 함께 본다."""
    if ratio < COST_RATIO_FLOOR:
        return 0.0, "ratio %.2f < %.2f (하한 미달)" % (ratio, COST_RATIO_FLOOR)
    bad = [a for a, v in perfs.items() if v < COST_PERF_GATE]
    if bad:
        return 0.0, "성능 30%% 미달: %s -> 비용 전체 0점" % ", ".join(sorted(bad))
    return float(sum(1 for lim in COST_LIMITS if ratio <= lim)), ""


def rubric(perf, avail, ratio):
    """(총점, 상세) — 비정상요청 4점은 제외한 36점 만점 기준으로 계산."""
    rows = []
    av_tot = pf_tot = 0.0
    for api in sorted(avail):
        ap = band_points(avail[api])
        pp = band_points(perf[api])
        av_tot += ap
        pf_tot += pp
        rows.append((api, avail[api], ap, perf[api], pp))
    cp, note = cost_points(ratio, perf)
    return av_tot, pf_tot, cp, rows, note


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
        navg = sum(ns) / len(ns)
        ratio = navg / BASELINE_NODES if BASELINE_NODES else 0
        print(f"nodes      min={min(ns)} max={max(ns)} avg={navg:.2f}  "
              f"(baseline={BASELINE_NODES:g}, cost ratio {ratio:.2f})")
        # 실제 채점기준으로 환산 (비정상요청 4점은 verify.ps1 영역이라 제외)
        av, pf, cp, rows, note = rubric(perf, avail, ratio)
        print()
        print(f"{'채점 환산':10} {'avail%':>7} {'가용성':>6} {'perf%':>7} {'성능':>5}")
        for api, a, ap, pv, pp in rows:
            print(f"{api:10} {a:>6.1f}% {ap:>6.1f} {pv:>6.1f}% {pp:>5.1f}")
        print(f"{'합계':10} {'':>7} {av:>6.1f}/12 {'':>7} {pf:>4.1f}/12")
        print(f"{'비용':10} ratio {ratio:.2f} -> {cp:.1f}/12" + (f"   [!] {note}" if note else ""))
        print(f"{'소계':10} {av+pf+cp:.1f}/36  (+ 비정상요청 4점은 verify.ps1 로 확인)")
    elif mode == "score":
        out, slo, gate, pen = sys.argv[2], parse_slo(sys.argv[3]), float(sys.argv[4]), float(sys.argv[5])
        focus = sys.argv[6] if len(sys.argv) > 6 else None
        perf, avail, _ = load(out, slo)
        ns = nodes(out); navg = sum(ns) / len(ns)
        avg = perf[focus] if focus in perf else sum(perf.values()) / len(perf)
        mav = min(avail.values())
        ratio = navg / BASELINE_NODES if BASELINE_NODES else 0
        # 목표함수를 실제 채점 총점으로 바꾼다. 예전 'perf% - 노드초과xpen' 은 선형 근사라
        # 구간 경계(90/87.5/.../30)와 비용 하한(0.50), 성능 30% 게이트를 반영하지 못해
        # autotune 이 실제 점수가 더 낮은 조합을 우승으로 뽑을 수 있었다.
        av, pf, cp, _rows, _note = rubric(perf, avail, ratio)
        total = av + pf + cp
        # gate/pen 인자는 하위호환을 위해 받되, 총점 계산에는 쓰지 않는다.
        print(f"{avg:.1f} {mav:.1f} {navg:.2f} {total:.1f}")
    else:
        sys.exit(f"unknown mode: {mode}")


if __name__ == "__main__":
    main()
