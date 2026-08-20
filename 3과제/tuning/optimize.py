#!/usr/bin/env python3
"""공식 점수 기반 닫힌 루프 최적화기의 후보 선택 CLI."""
import argparse
import json
import os
import sys

import advise
import rubric
import tuning_engine as engine

BASELINE_NODES = float(os.environ.get("TUNE_BASELINE_NODES", "2"))


def band_floor_and_gap(perf):
    return rubric.band_floor(perf), rubric.next_band(perf)[1]


def plan_step(knobs, summary, rejected=None, avail_gate=99.0):
    """구형 순수함수 계약 호환. 새 코드는 engine.plan(snapshot)을 사용한다."""
    apps = {}
    perfs = summary.get("perfs", {}) or {}
    avails = summary.get("availability", {}) or {}
    for name in sorted(set(knobs) | set(perfs)):
        current = knobs.get(name, {})
        apps[name] = engine.AppSnapshot(
            name=name, slo_seconds=1.0, samples=100,
            performance=float(perfs.get(name, 0)), availability=float(avails.get(name, 0)),
            request_m=int(current.get("request") or 100), target=int(current.get("target") or 60),
            min_replicas=int(current.get("min") or 1), max_replicas=int(current.get("max") or 6),
            replicas=int(current.get("replicas") or current.get("min") or 1),
            pods_max=int(current.get("replicas") or current.get("min") or 1),
        )
    ratio = float(summary.get("cost_ratio", 1.0))
    snapshot = engine.TuningSnapshot(
        apps, engine.ClusterSnapshot(BASELINE_NODES, ratio * BASELINE_NODES,
                                     max(1, int(round(ratio * BASELINE_NODES))), 1930),
        avail_gate,
    )
    old_rejected = {f"{item.get('app')}|{item.get('kind')}" for item in (rejected or [])}
    candidates = [c for c in engine.generate_candidates(snapshot)
                  if f"{c.app}|{c.kind}" not in old_rejected]
    if not candidates:
        return {"done": True, "app": None, "knob": None, "kind": None,
                "predicted_delta": 0.0, "reason": "공통 엔진: 개선 후보 없음"}
    c = candidates[0]
    return {"done": False, "app": c.app, "kind": c.kind,
            "knob": c.proposed, "predicted_delta": c.predicted_delta,
            "reason": c.reason, "candidate": c.to_dict()}


def _rejected_keys(path):
    if not path or not os.path.isfile(path):
        return [], []
    try:
        with open(path, encoding="utf-8") as f:
            rows = json.load(f)
    except Exception:
        return [], []
    keys, nodes = [], []
    for row in rows if isinstance(rows, list) else []:
        if isinstance(row, str):
            keys.append(row)
            continue
        if row.get("key"):
            keys.append(row["key"])
        elif row.get("app") and row.get("kind"):
            keys.append(f"{row['app']}|{row['kind']}")
        try:
            if int(row.get("nodes") or 0) > 0:
                nodes.append(int(row["nodes"]))
        except (TypeError, ValueError):
            pass
    return keys, nodes


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    parser = argparse.ArgumentParser(description="측정 결과 -> 공통 엔진의 다음 라이브 튜닝 후보")
    parser.add_argument("target", help="loadtest 결과 폴더 또는 label")
    parser.add_argument("--slos", default="user=0.2,product=0.2,stress=1.0")
    parser.add_argument("--ns", default="app")
    parser.add_argument("--avail-gate", type=float, default=99.0)
    parser.add_argument("--objective", choices=["cost", "balanced"], default="cost",
                        help="cost: 공식 밴드 기준(가용성 90%+, 성능 30%+)에서 비용 우선. "
                             "balanced: 가용성 99% 유지")
    parser.add_argument("--avail-floor", type=float, default=None,
                        help="비용 우선 모드에서 지킬 최소 가용성%% (기본 92)")
    parser.add_argument("--perf-floor", type=float, default=None,
                        help="비용 우선 모드에서 지킬 최소 성능%% (기본 80)")
    parser.add_argument("--load-scale", type=float, default=1.0,
                        help="목표 부하 배수. 1.0=측정 부하 기준, 0.5=측정 부하의 절반 기준 사이징")
    parser.add_argument("--target-rps", default="",
                        help="앱별 목표 초당 요청수: user=100,stress=10 (측정 부하와 무관하게 고정)")
    parser.add_argument("--hpa-only", action="store_true",
                        help="request 변경(rollout) 후보 제외. 부하 중 라이브 루프의 기본값")
    parser.add_argument("--rejected", default="")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    outdir = advise.resolve_outdir(args.target)
    if not os.path.isdir(outdir):
        sys.exit(f"결과 폴더 없음: {outdir}")
    slos = {kv.split("=")[0]: float(kv.split("=")[1]) for kv in args.slos.split(",") if kv}
    snapshot = engine.snapshot_from_outdir(outdir, slos, args.ns, BASELINE_NODES,
                                           availability_gate=args.avail_gate)
    snapshot.cost_first = args.objective == "cost"
    if args.avail_floor is not None:
        snapshot.avail_floor = args.avail_floor
    if args.perf_floor is not None:
        snapshot.perf_floor = args.perf_floor
    snapshot.load_scale = max(args.load_scale, 0.0)
    snapshot.target_rps = {kv.split("=")[0]: float(kv.split("=")[1])
                           for kv in args.target_rps.split(",") if "=" in kv}
    rejected, rejected_nodes = _rejected_keys(args.rejected)
    data = engine.plan(snapshot, rejected, args.ns, rejected_nodes, args.hpa_only)
    best = data.get("best")
    knobs = {row["app"]: {"request": row["request"], "target": row["target"],
                           "min": row["min"], "max": row["max"],
                           "replicas": row["replicas"],
                           "deployment_name": row["deployment_name"],
                           "hpa_name": row["hpa_name"]} for row in data["apps"]}
    best_knob = None
    if best:
        best_knob = dict(best["proposed"])
        best_knob.update({"deployment_name": best["deployment_name"], "hpa_name": best["hpa_name"]})
    result = {
        "schema_version": data["schema_version"], "done": data["done"],
        "app": best["app"] if best else None, "kind": best["kind"] if best else None,
        "knob": best_knob,
        "predicted_delta": best["predicted_delta"] if best else 0.0,
        "reason": best["reason"] if best else data["reason"],
        "candidate": best, "candidates": data["candidates"],
        "knob_set": (best or {}).get("knobs") or {},
        "current_total": data["score"]["total"],
        "current_cost_ratio": data["score"]["cost_ratio"], "knobs": knobs,
        "objective": args.objective,
        "avail_floor": snapshot.avail_floor if snapshot.cost_first else args.avail_gate,
        "perf_floor": snapshot.perf_floor if snapshot.cost_first else rubric.COST_PERF_GATE,
        "cost_locked": data.get("cost_locked", ""),
        "reservation_fit": data.get("reservation_fit"),
    }
    if args.json:
        print(json.dumps(result, ensure_ascii=True, separators=(",", ":")))
        return
    print("\n=== 공통 엔진: 다음 라이브 튜닝 후보 ===")
    print(f"공식 소계 {result['current_total']:.1f}/36 | 비용 ratio {result['current_cost_ratio']:.2f}")
    if result["done"]:
        print("수렴: " + result["reason"])
    else:
        p = result["knob"]
        print(f"[{result['kind']}] {result['app']}: request={p['request']}m target={p['target']}% "
              f"min={p['min']} max={p['max']} (예상 {result['predicted_delta']:+.1f})")
        print("근거: " + result["reason"])
        print("적용:")
        for command in best["apply_commands"]:
            print("  " + command)
        print("롤백:")
        for command in best["rollback_commands"]:
            print("  " + command)
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
