#!/usr/bin/env python3
"""완료된 loadtest + 라이브 상태를 공통 엔진으로 분석하는 비파괴 추천기."""
import argparse
import json
import os
import sys

import rubric
import tuning_engine as engine

BASELINE_NODES = float(os.environ.get("TUNE_BASELINE_NODES", "2"))
RATE_BANDS = rubric.RATE_BANDS
META_CSV = engine.META_CSV
cpu_m = engine.cpu_m
ceil_to = engine.ceil_to
nearest_rank = engine.nearest_rank
discover_apps = engine.discover_apps
live_state = engine.live_state


def resolve_outdir(target):
    if os.path.isdir(target):
        return os.path.abspath(target)
    return os.path.join(os.environ.get("TEMP", "/tmp"), "tune-" + target)


def recommendation(measurement, cpu, current, node_cpu, ratio=None):
    """이전 외부 호출 계약 호환용. 실제 판단은 공통 엔진이 수행한다."""
    app = engine.AppSnapshot(
        name="app", slo_seconds=float((measurement or {}).get("slo", 1.0)),
        samples=int((measurement or {}).get("samples", 1 if measurement else 0)),
        availability=float((measurement or {}).get("availability", 0)),
        performance=float((measurement or {}).get("performance", 0)),
        request_m=int(current.get("request") or 200), target=int(current.get("target") or 70),
        min_replicas=int(current.get("min") or 1), max_replicas=int(current.get("max") or 6),
        replicas=int(current.get("replicas") or current.get("min") or 1),
        per_pod_p90=int((cpu or {}).get("per_pod_p90", 0)),
        per_pod_p95=int((cpu or {}).get("per_pod_p95", (cpu or {}).get("per_pod_p90", 0))),
        total_cpu_p90=int((cpu or {}).get("total_p90", 0)),
        total_cpu_p95=int((cpu or {}).get("total_p95", (cpu or {}).get("total_p90", 0))),
        pods_p50=int((cpu or {}).get("pods_p50", current.get("min", 1))),
        pods_p90=int((cpu or {}).get("pods_p90", (cpu or {}).get("pods_p50", current.get("min", 1)))),
        pods_max=int((cpu or {}).get("pods_max", (cpu or {}).get("pods_p90", current.get("min", 1)))),
        cpu_samples=int((cpu or {}).get("time_samples", 10 if cpu else 0)),
    )
    node_avg = (ratio or 1.0) * BASELINE_NODES
    cluster = engine.ClusterSnapshot(
        baseline_nodes=BASELINE_NODES, node_average=node_avg,
        node_count=max(1, int(round(node_avg))), node_cpu_p95=int(node_cpu or 0),
        node_alloc_m=1930, cluster_cpu_p95_m=int((cpu or {}).get("total_p95", 0)),
    )
    snapshot = engine.TuningSnapshot({"app": app}, cluster)
    candidates = engine.generate_candidates(snapshot)
    best = candidates[0] if candidates else None
    if not best:
        return {"request": app.request_m, "target": app.target, "min": app.min_replicas,
                "max": app.max_replicas, "needed": None,
                "reason": "공통 엔진: 안전하게 공식 점수를 올릴 후보 없음"}
    return {"request": best.proposed["request"], "target": best.proposed["target"],
            "min": best.proposed["min"], "max": best.proposed["max"],
            "needed": best.proposed.get("estimated_replicas"), "reason": best.reason}


def _print_plan(plan_data, app_filter=""):
    score = plan_data["score"]
    print("\n=== READ-ONLY official-rubric tuning plan ===")
    print("클러스터 변경 없음: 출력은 라이브 적용/롤백 후보이며 자동 실행하지 않습니다.")
    print(f"공식 소계 {score['total']:.1f}/36 | 비용 ratio {score['cost_ratio']:.2f} "
          f"| 가용성 게이트 {'PASS' if score['avail_gate_pass'] else 'FAIL'} "
          f"| 성능30 게이트 {'PASS' if score['perf_gate_pass'] else 'FAIL'}")
    for row in plan_data["apps"]:
        if app_filter and row["app"] != app_filter:
            continue
        print(f"\n[{row['app']}] avail={row['availability']:.1f}% perf={row['performance']:.1f}% "
              f"bottleneck={row['bottleneck']}")
        print(f"  현재: request={row['request']}m min={row['min']} max={row['max']} "
              f"target={row['target']}% trigger={row['trigger']:.1f}m replicas={row['replicas']}")
        print(f"  CPU: per-pod p90={row['cpu_p90']}m total p90={row['total_cpu_p90']}m")
    shown = [c for c in plan_data["candidates"] if not app_filter or c["app"] == app_filter]
    print("\n--- 공식 총점 기준 후보(최대 3개) ---")
    if not shown:
        print("변경 권장 없음: " + (plan_data.get("reason") or "선택 앱에 안전 후보 없음"))
    for index, candidate in enumerate(shown, 1):
        p = candidate["proposed"]
        print(f"{index}. [{candidate['kind']}] {candidate['app']}: requests.cpu=\"{p['request']}m\", "
              f"min_replicas={p['min']}, max_replicas={p['max']}, average_utilization={p['target']}")
        print(f"   trigger {candidate['trigger_before']:.1f}m -> {candidate['trigger_after']:.1f}m | "
              f"예상 nodes={candidate['predicted_nodes']} (실CPU 하한={candidate['observed_cpu_floor']}) "
              f"| 예상 delta={candidate['predicted_delta']:+.1f}")
        print(f"   근거: {candidate['reason']}")
        print("   적용:")
        for command in candidate["apply_commands"]:
            print("     " + command)
        print("   롤백:")
        for command in candidate["rollback_commands"]:
            print("     " + command)
    print("\n앱별 첫 후보 줄(대시보드 튜닝적용 붙여넣기 호환):")
    seen = set()
    for candidate in shown:
        if candidate["app"] in seen:
            continue
        seen.add(candidate["app"])
        p = candidate["proposed"]
        print(f"{candidate['app']}: requests.cpu=\"{p['request']}m\", min_replicas={p['min']}, "
              f"max_replicas={p['max']}, average_utilization={p['target']}")


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    parser = argparse.ArgumentParser(description="loadtest 결과 -> 공식 채점기준 비파괴 튜닝 계획")
    parser.add_argument("target", help="loadtest label 또는 결과 폴더")
    parser.add_argument("--slos", default="user=0.2,product=0.2,stress=1.0")
    parser.add_argument("--ns", default="app")
    parser.add_argument("--app", default="")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    outdir = resolve_outdir(args.target)
    if not os.path.isdir(outdir):
        sys.exit(f"결과 폴더 없음: {outdir}")
    slos = {part.split("=")[0]: float(part.split("=")[1]) for part in args.slos.split(",") if part}
    snapshot = engine.snapshot_from_outdir(outdir, slos, args.ns, BASELINE_NODES)
    data = engine.plan(snapshot, namespace=args.ns)
    if args.json:
        print(json.dumps(data, ensure_ascii=True, separators=(",", ":")))
    else:
        _print_plan(data, args.app)


if __name__ == "__main__":
    main()
