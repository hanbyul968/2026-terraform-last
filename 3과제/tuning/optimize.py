#!/usr/bin/env python3
"""공식 점수(score.py)를 목적함수로 쓰는 닫힌 루프 최적화기의 '두뇌'.

왜 닫힌 루프인가:
  한 번의 측정으로는 최적 HPA target 을 알 수 없다. target 을 올리면 파드가 줄어 지연이
  얼마나 늘지(= 성능%가 어느 밴드로 떨어질지)는 그 지점을 '실제로 측정'해야만 안다.
  그래서 이 모듈은 예측이 아니라 '다음에 시도할 한 수'만 고르고, 실제 채점은 optimize.ps1
  이 재측정으로 검증한다(좌표상승법 + 측정 검증). 예측이 틀려도 루프가 되돌린다.

핵심 함수 plan_step() 은 순수 함수다(부수효과 없음) — 단위 테스트로 검증한다.
실제 클러스터 변경(kubectl patch)과 재측정 루프는 optimize.ps1 이 담당한다.

목적함수는 score.py 와 '동일한' 공식 채점식이다. 별도 근사식을 쓰지 않는다.
"""
import argparse
import importlib.util
import json
import os
import pathlib
import sys

_HERE = pathlib.Path(__file__).parent


def _load(name):
    spec = importlib.util.spec_from_file_location(name, _HERE / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


score = _load("score")
advise = _load("advise")

# ---- 탐색 파라미터 ----
STEP = 10            # 한 번에 움직이는 target %p (좌표상승 스텝)
BIG_STEP = 15        # 게이트 위반 시 더 크게 내린다
PERF_NEAR = 3.0      # 밴드 경계에 이만큼 못 미치면 target 을 내려 넘길 가치가 있다
COST_MARGIN = 5.0    # 이만큼 밴드 위에 여유가 있어야 비용 회수(target ↑)를 시도한다
TARGET_MIN = 25
TARGET_MAX = 85

# 후보 종류별 우선순위(큰 값이 먼저). 확실한 성능 이득(경계 넘기)을 먼저 확정하고,
# 그다음 비용 회수를 시도한다. 게이트 위반은 무조건 최우선.
KIND_PRIORITY = {"emergency": 3, "perf-up": 2, "cost-reclaim": 1}


def clamp(value, low, high):
    return max(low, min(high, value))


def band_floor_and_gap(perf):
    """현재 perf 가 통과한 가장 높은 공식 밴드(floor)와, 다음 상위 밴드까지 남은 %p(gap)."""
    bands = sorted(score.RATE_BANDS)  # [30,50,70,80,82.5,85,87.5,90]
    floor = 0.0
    for band in bands:
        if perf >= band:
            floor = band
    gap_up = 0.0
    for band in bands:
        if perf < band:
            gap_up = band - perf
            break
    return floor, gap_up


def plan_step(knobs, summary, rejected=None, avail_gate=99.0):
    """현재 knobs 와 방금 측정한 점수 요약(summary)을 보고 '다음 한 수'를 고른다.

    knobs   : {app: {"target": int, "min": int, "max": int}}
    summary : score.score_summary() 결과 dict
    rejected: [{"app":..,"kind":..}] — 시도했다가 점수가 안 오른 수(재제안 금지)
    반환    : {"done","app","knob","kind","predicted_delta","reason"}
    """
    rejected = rejected or []
    rejected_set = {(item["app"], item["kind"]) for item in rejected}
    perfs = summary.get("perfs", {}) or {}
    avails = summary.get("availability", {}) or {}
    ratio = float(summary.get("cost_ratio", 0.0))

    candidates = []

    # 1) 게이트 위반(성능<30 = 비용 전체 0점, 또는 가용성<게이트) — 최우선 복구.
    #    target 을 크게 내려 더 일찍 확장하고, min/max 도 올려 용량을 확보한다.
    emergency_exists = False
    for app, perf in perfs.items():
        avail = float(avails.get(app, 100.0))
        if perf < score.COST_PERF_GATE or avail < avail_gate:
            emergency_exists = True
            if ("emergency", app) in {(k, a) for a, k in rejected_set}:
                pass
            if (app, "emergency") in rejected_set:
                continue
            cur = knobs.get(app, {})
            new_target = clamp(int(cur.get("target", 60)) - BIG_STEP, TARGET_MIN, TARGET_MAX)
            knob = {
                "target": new_target,
                "min": max(2, int(cur.get("min", 2))),
                "max": max(int(cur.get("max", 6)), int(cur.get("max", 6)) + 2),
            }
            candidates.append({
                "app": app, "kind": "emergency", "knob": knob,
                "predicted_delta": 6.0,  # 게이트 통과는 비용 12점 잠금 해제 등 파급이 크다
                "sort_key": 1000.0,
                "reason": (f"{app} 게이트 위반(perf={perf:.1f}%, avail={avail:.1f}%) "
                           f"-> target {cur.get('target')}→{new_target}, min≥2, max+2 로 용량 확보"),
            })

    # 게이트 위반이 있으면 그것만 처리한다(다른 최적화는 게이트 복구 후에).
    if not emergency_exists:
        # 2) 성능 상향: 다음 밴드 경계 바로 아래면 target 을 내려 넘긴다(고신뢰 +0.5).
        for app, perf in perfs.items():
            if (app, "perf-up") in rejected_set:
                continue
            _floor, gap_up = band_floor_and_gap(perf)
            cur = knobs.get(app, {})
            target = int(cur.get("target", 60))
            if 0 < gap_up <= PERF_NEAR and target - STEP >= TARGET_MIN:
                knob = {"target": target - STEP, "min": int(cur.get("min", 2)),
                        "max": int(cur.get("max", 6))}
                candidates.append({
                    "app": app, "kind": "perf-up", "knob": knob,
                    "predicted_delta": 0.5,
                    "sort_key": KIND_PRIORITY["perf-up"] * 100 + (PERF_NEAR - gap_up),
                    "reason": (f"{app} perf {perf:.1f}% 는 다음 밴드까지 {gap_up:.1f}%p — "
                               f"target {target}→{target - STEP} 로 파드를 늘려 경계를 넘긴다(+0.5 기대)"),
                })

        # 3) 비용 회수: 노드가 기준 초과(ratio>1 → 비용 만점 아님)이고, 성능이 현재 밴드
        #    위로 여유가 크면 target 을 올려 파드/노드를 줄인다. 성능 밴드 하락 위험은
        #    루프의 재측정이 검증하고, 여유(margin)와 1스텝 제한으로 억제한다.
        if ratio > 1.0:
            for app, perf in perfs.items():
                if (app, "cost-reclaim") in rejected_set:
                    continue
                floor, _gap_up = band_floor_and_gap(perf)
                margin = perf - floor
                cur = knobs.get(app, {})
                target = int(cur.get("target", 60))
                if margin >= COST_MARGIN and target + STEP <= TARGET_MAX:
                    knob = {"target": target + STEP, "min": int(cur.get("min", 2)),
                            "max": int(cur.get("max", 6))}
                    candidates.append({
                        "app": app, "kind": "cost-reclaim", "knob": knob,
                        "predicted_delta": 1.0,
                        # 같은 종류면 여유가 큰 앱을 먼저(가장 안전하게 파드를 줄일 수 있음)
                        "sort_key": KIND_PRIORITY["cost-reclaim"] * 100 + margin,
                        "reason": (f"비용 ratio {ratio:.2f}>1 이고 {app} perf {perf:.1f}% 가 밴드 "
                                   f"{floor:g}% 위로 {margin:.1f}%p 여유 — target {target}→{target + STEP} "
                                   f"로 파드/노드를 줄여 비용 회수(+1 기대, 성능 밴드는 유지 목표)"),
                    })

    if not candidates:
        return {
            "done": True, "app": None, "knob": None, "kind": None,
            "predicted_delta": 0.0,
            "reason": ("개선 후보 없음 — 성능 밴드 경계 근처도, 회수할 비용 여유(ratio>1 & 성능 여유)도, "
                       "게이트 위반도 없음. 현재 구성이 이 트래픽에서 국소 최적."),
        }

    best = max(candidates, key=lambda c: c["sort_key"])
    best["done"] = False
    return best


def _cli():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    parser = argparse.ArgumentParser(
        description="측정 결과 -> 닫힌 루프 최적화의 '다음 한 수'(JSON). 클러스터는 변경하지 않음.")
    parser.add_argument("target", help="loadtest 결과 폴더 또는 label")
    parser.add_argument("--slos", default="user=0.2,product=0.2,stress=1.0")
    parser.add_argument("--ns", default="app")
    parser.add_argument("--avail-gate", type=float, default=99.0)
    parser.add_argument("--rejected", default="", help="재제안 금지 목록 JSON 파일 경로")
    parser.add_argument("--json", action="store_true", help="사람이 읽는 텍스트 대신 JSON만 출력")
    args = parser.parse_args()

    outdir = advise.resolve_outdir(args.target)
    if not os.path.isdir(outdir):
        sys.exit(f"결과 폴더 없음: {outdir}")
    slos = {kv.split("=")[0]: float(kv.split("=")[1]) for kv in args.slos.split(",") if kv}

    perf, avail, _ = score.load(outdir, slos)
    samples = score.nodes(outdir)
    node_avg = sum(samples) / len(samples)
    summary = score.score_summary(perf, avail, node_avg, availability_gate=args.avail_gate)

    live = advise.live_state(args.ns)
    knobs = {}
    for app in perf:
        state = live.get(app, {})
        knobs[app] = {
            "target": int(state.get("target") or 60),
            "min": int(state.get("min") or 2),
            "max": int(state.get("max") or 6),
        }

    rejected = []
    if args.rejected and os.path.isfile(args.rejected):
        try:
            with open(args.rejected, encoding="utf-8") as f:
                rejected = json.load(f)
        except Exception:
            rejected = []

    step = plan_step(knobs, summary, rejected, args.avail_gate)
    step["current_total"] = summary["total"]
    step["current_cost_ratio"] = summary["cost_ratio"]
    step["knobs"] = knobs

    if args.json:
        print(json.dumps(step, ensure_ascii=True))
        return

    print("\n=== 닫힌 루프 최적화: 다음 한 수 ===")
    print(f"결과: {outdir}")
    print(f"현재 총점(성능+가용성+비용) {summary['total']:.1f}/36, 비용 ratio {summary['cost_ratio']:.2f}")
    for app in sorted(perf):
        print(f"  [{app}] perf={perf[app]:.1f}% avail={avail[app]:.1f}% "
              f"target={knobs[app]['target']}% min={knobs[app]['min']} max={knobs[app]['max']}")
    if step["done"]:
        print(f"\n수렴: {step['reason']}")
    else:
        knob = step["knob"]
        print(f"\n다음 수 [{step['kind']}] {step['app']}: "
              f"target={knob['target']}% min={knob['min']} max={knob['max']} "
              f"(기대 +{step['predicted_delta']:.1f})")
        print(f"근거: {step['reason']}")
    print(json.dumps(step, ensure_ascii=False))


if __name__ == "__main__":
    _cli()
