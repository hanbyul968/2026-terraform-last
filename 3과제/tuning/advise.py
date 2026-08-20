#!/usr/bin/env python3
"""완료된 loadtest 결과로 requests.cpu와 HPA 값을 계산하는 비파괴 추천기.

클러스터에서는 현재 Deployment/HPA/노드 정보만 읽는다. kubectl patch, set resources,
rollout, terraform apply는 절대 실행하지 않는다.
"""
import argparse
import csv
import json
import math
import os
import subprocess
import sys

BASELINE_NODES = float(os.environ.get("TUNE_BASELINE_NODES", "2"))
RATE_BANDS = [30.0, 50.0, 70.0, 80.0, 82.5, 85.0, 87.5, 90.0]
META_CSV = {"nodes", "nodecpu", "podcpu", "loadplan", "loadwindows"}


def run(cmd, timeout=30):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8",
                              errors="replace", timeout=timeout).stdout or ""
    except Exception:
        return ""


def cpu_m(value):
    if value is None or value == "":
        return None
    value = str(value)
    return int(value[:-1]) if value.endswith("m") else int(float(value) * 1000)


def ceil_to(value, unit):
    return int(math.ceil(float(value) / unit) * unit)


def nearest_rank(values, q):
    if not values:
        return 0
    values = sorted(values)
    return values[min(len(values) - 1, max(0, math.ceil(q * len(values)) - 1))]


def next_band(value):
    for threshold in RATE_BANDS:
        if value < threshold:
            return threshold, threshold - value
    return 90.0, 0.0


def resolve_outdir(target):
    if os.path.isdir(target):
        return os.path.abspath(target)
    return os.path.join(os.environ.get("TEMP", "/tmp"), "tune-" + target)


def discover_apps(outdir, slos):
    apps = []
    try:
        files = os.listdir(outdir)
    except OSError:
        files = []
    for filename in sorted(files):
        if not filename.endswith(".csv"):
            continue
        name = os.path.splitext(filename)[0]
        if name in META_CSV:
            continue
        path = os.path.join(outdir, filename)
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                if "response-time" not in f.readline():
                    continue
        except OSError:
            continue
        apps.append(name)
    return apps or list(slos)


def load_measurements(outdir, apps, slos):
    result = {}
    for app in apps:
        try:
            with open(os.path.join(outdir, app + ".csv"), encoding="utf-8", errors="replace") as f:
                rows = list(csv.DictReader(f))
        except OSError:
            rows = []
        if not rows:
            result[app] = None
            continue
        slo = slos[app]
        latencies = [float(row["response-time"]) for row in rows]
        available = [row for row in rows
                     if row["status-code"].startswith("2") and float(row["response-time"]) <= 5.0]
        performant = [row for row in available if float(row["response-time"]) <= slo]
        result[app] = {
            "samples": len(rows),
            "availability": 100.0 * len(available) / len(rows),
            "performance": 100.0 * len(performant) / len(rows),
            "p95_latency": nearest_rank(latencies, 0.95),
            "slo": slo,
        }
    return result


def load_windows(outdir):
    result = {}
    try:
        with open(os.path.join(outdir, "loadwindows.csv"), encoding="utf-8-sig", errors="replace") as f:
            for row in csv.DictReader(f):
                result[row["name"]] = (int(float(row["start_epoch"])),
                                       int(float(row["active_end_epoch"])))
    except OSError:
        pass
    return result


def app_from_pod(pod_name, apps):
    matches = [app for app in apps if pod_name == app or pod_name.startswith(app + "-")]
    return max(matches, key=len) if matches else None


def load_cpu_window(outdir, apps, windows):
    """활성 부하창만 사용한다. UTC+9 오염·부하 종료 뒤 유휴 표본은 자동 제외된다."""
    per_time = {app: {} for app in apps}
    path = os.path.join(outdir, "podcpu.csv")
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for row in csv.reader(f):
                if len(row) < 3:
                    continue
                try:
                    ts, cpu = int(row[0]), int(row[2])
                except ValueError:
                    continue
                app = app_from_pod(row[1], apps)
                if not app or app not in windows:
                    continue
                start, end = windows[app]
                if not start <= ts <= end:
                    continue
                per_time[app].setdefault(ts, []).append(cpu)
    except OSError:
        return {}

    result = {}
    for app, samples in per_time.items():
        if not samples:
            continue
        totals = [sum(values) for values in samples.values()]
        counts = [len(values) for values in samples.values()]
        per_pod = [value for values in samples.values() for value in values]
        result[app] = {
            "time_samples": len(totals),
            "per_pod_p50": nearest_rank(per_pod, 0.50),
            "per_pod_p90": nearest_rank(per_pod, 0.90),
            "per_pod_p95": nearest_rank(per_pod, 0.95),
            "total_p50": nearest_rank(totals, 0.50),
            "total_p90": nearest_rank(totals, 0.90),
            "total_p95": nearest_rank(totals, 0.95),
            "pods_p50": nearest_rank(counts, 0.50),
            "pods_p90": nearest_rank(counts, 0.90),
            "pods_max": max(counts),
        }
    return result


def load_node_cpu_window(outdir, windows):
    if not windows:
        return None
    start = min(value[0] for value in windows.values())
    end = max(value[1] for value in windows.values())
    values = []
    try:
        with open(os.path.join(outdir, "nodecpu.csv"), encoding="utf-8", errors="replace") as f:
            for row in csv.reader(f):
                if len(row) < 3:
                    continue
                try:
                    ts, value = int(row[0]), int(row[2])
                except ValueError:
                    continue
                if start <= ts <= end:
                    values.append(value)
    except OSError:
        return None
    return max(values) if values else None


def load_nodes(outdir, windows):
    values = []
    start = min((value[0] for value in windows.values()), default=None)
    end = max((value[1] for value in windows.values()), default=None)
    try:
        with open(os.path.join(outdir, "nodes.csv"), encoding="utf-8", errors="replace") as f:
            for row in csv.reader(f):
                try:
                    ts, value = int(row[0]), int(row[1])
                except (ValueError, IndexError):
                    continue
                if value <= 0:
                    continue
                if start is not None and not start <= ts <= end:
                    continue
                values.append(value)
    except OSError:
        pass
    return values


def live_state(namespace):
    state = {}
    try:
        deployments = json.loads(run(["kubectl", "-n", namespace, "get", "deploy", "-o", "json"]) or "{}")
        for item in deployments.get("items", []):
            name = item["metadata"]["name"]
            containers = item["spec"]["template"]["spec"].get("containers", [])
            for container in containers:
                request = (container.get("resources", {}).get("requests", {}) or {}).get("cpu")
                if request:
                    state.setdefault(name, {})["request"] = cpu_m(request)
                    break
        hpas = json.loads(run(["kubectl", "-n", namespace, "get", "hpa", "-o", "json"]) or "{}")
        for item in hpas.get("items", []):
            spec = item.get("spec", {})
            # HPA metadata.name이 user-hpa처럼 Deployment와 달라도 실제 대상 앱을 사용한다.
            name = (spec.get("scaleTargetRef", {}) or {}).get("name") or item["metadata"]["name"]
            current = state.setdefault(name, {})
            current["min"] = spec.get("minReplicas", 1)
            current["max"] = spec.get("maxReplicas")
            status = item.get("status", {}) or {}
            current["replicas"] = status.get("currentReplicas")
            current["desired"] = status.get("desiredReplicas")
            for metric in spec.get("metrics", []):
                resource = metric.get("resource", {})
                if metric.get("type") == "Resource" and resource.get("name") == "cpu":
                    current["target"] = resource.get("target", {}).get("averageUtilization")
    except Exception:
        return {}
    return state


def recommendation(measurement, cpu, current, node_cpu, ratio=None):
    """현재 한 회차에서 다음 회차로 이동할 보수적인 1-step 권장값을 계산한다.

    request와 target은 독립값이 아니다. request*target%가 HPA의 파드당 목표 CPU다.
    request 변경 시 이 값을 보존한 뒤, 성능/가용성 미달일 때만 5~10% 낮춘다.
    """
    request = int(current.get("request") or 200)
    target = int(current.get("target") or 70)
    minimum = int(current.get("min") or 2)
    maximum = int(current.get("max") or max(6, minimum))
    if not measurement or not cpu:
        return {
            "request": request, "target": target, "min": minimum, "max": maximum,
            "needed": None, "reason": "측정 또는 활성 부하창 CPU 표본 없음 — 값 유지",
        }

    perf = measurement["performance"]
    avail = measurement["availability"]
    old_trigger = request * target / 100.0
    recommended_request = request

    # request는 속도 제한이 아니므로 노드가 실제 포화됐고 파드 CPU도 request를 넘을 때만 올린다.
    fitted = ceil_to(max(50, cpu["per_pod_p90"] * 1.15), 25)
    if node_cpu is not None and node_cpu >= 90 and cpu["per_pod_p90"] > request * 1.10:
        recommended_request = min(fitted, ceil_to(request * 1.25, 25))
    elif perf >= 90 and fitted < request * 0.75:
        recommended_request = max(50, fitted)

    # 30% 게이트 미달은 비용 12점 전체를 잠그므로 가장 강하게, 그 위는 다음 구간용으로 완만하게.
    factor = 1.0
    if perf < 30 or avail < 90:
        factor = 0.90
    elif perf < 50 or avail < 99:
        factor = 0.92
    elif perf < 70:
        factor = 0.95
    elif perf < 90:
        factor = 0.98

    wanted_trigger = old_trigger * factor
    recommended_target = int(round(100.0 * wanted_trigger / recommended_request))
    recommended_target = max(25, min(90, recommended_target))

    # 비용 회수(양방향). 기존 로직은 성능 보호로 target을 '내리기만' 해 노드가 남아돌아도
    # 비용을 못 줄였다. 노드가 기준 초과(ratio>1)이고 성능이 최상위 밴드(>=90%)로 안전하며
    # 파드가 request 대비 저활용(<60%)이면, target을 한 스텝(+10%p, 상한 85) 올려 파드/노드를
    # 줄인다. 단일 회차 권고라 밴드 하락 위험이 가장 낮은 '>=90%' 에서만 시도한다.
    # 정밀 최적화(어디까지 올릴 수 있나)는 optimize.py 의 닫힌 루프가 재측정으로 찾는다.
    reclaimed_cost = False
    if ratio and ratio > 1.0 and perf >= 90 and cpu["per_pod_p90"] < recommended_request * 0.6:
        bumped = min(85, recommended_target + 10)
        if bumped > recommended_target:
            recommended_target = bumped
            reclaimed_cost = True

    actual_trigger = recommended_request * recommended_target / 100.0
    needed = max(2, int(math.ceil(cpu["total_p90"] / max(actual_trigger, 1.0))))

    # 비용 기준선은 관리형 2노드다. min을 올리면 유휴 시에도 앱 Pod가 2노드 용량을 넘어
    # Karpenter 노드를 붙잡을 수 있으므로 모든 앱의 권장 minReplicas는 항상 2로 고정한다.
    recommended_min = 2

    recommended_max = maximum
    observed_peak = int(cpu.get("pods_max") or cpu.get("pods_p90") or 0)
    hit_max = observed_peak >= maximum
    # 이론상 needed가 커도 실제 파드가 현재 max에 닿지 않았다면 max가 병목이라는 증거가 없다.
    # 짧은 스파이크 하나로 13->17처럼 상한을 계속 키우면 2시간 변동 부하에서 비용만 커진다.
    # 활성 부하창에서 실제로 상한에 도달했고 성능/가용성이 미달일 때만 1-step 증가한다.
    if needed > maximum and hit_max and (perf < 90 or avail < 99):
        growth_cap = maximum + max(2, int(math.ceil(maximum * 0.25)))
        recommended_max = min(needed, growth_cap)
    # 한 번의 로컬 고성능 결과만으로 max를 줄이지 않는다. 공식 트래픽의 키 분포가
    # 다르면 product처럼 로컬 99% / 공식 80%가 될 수 있어 축소가 성능을 망친다.
    recommended_min = min(recommended_min, recommended_max)

    band, gap = next_band(perf)
    reasons = [
        f"perf {perf:.1f}% -> 다음 공식 구간 {band:g}%까지 {gap:.1f}%p",
        f"활성창 total CPU p90 {cpu['total_p90']}m / 권장 파드당 목표 {actual_trigger:.0f}m = 필요 약 {needed} pods",
    ]
    if hit_max:
        reasons.append(f"활성창 파드 최대 {observed_peak}개로 현재 max {maximum} 도달")
    else:
        reasons.append(f"활성창 파드 최대 {observed_peak}개 < 현재 max {maximum}; max 병목 증거 없어 유지")
    if recommended_request != request:
        reasons.append(f"노드 CPU {node_cpu}% 포화 + 파드 CPU p90 {cpu['per_pod_p90']}m > request {request}m; request는 1회 최대 25%만 조정")
    else:
        reasons.append("request 변경 조건 없음; 성능만 보고 request를 올리지 않음")
    if reclaimed_cost:
        reasons.append(f"비용 회수: ratio {ratio:.2f}>1 & perf {perf:.1f}%>=90 & 파드 저활용 -> target +10%p")
    return {
        "request": recommended_request,
        "target": recommended_target,
        "min": recommended_min,
        "max": recommended_max,
        "needed": needed,
        "reason": "; ".join(reasons),
    }


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    parser = argparse.ArgumentParser(description="loadtest 결과 -> 비파괴 request/HPA 권장값")
    parser.add_argument("target", help="loadtest label 또는 결과 폴더")
    parser.add_argument("--slos", default="user=0.2,product=0.2,stress=1.0")
    parser.add_argument("--ns", default="app")
    parser.add_argument("--app", default="", help="한 앱만 출력")
    args = parser.parse_args()

    outdir = resolve_outdir(args.target)
    if not os.path.isdir(outdir):
        sys.exit(f"결과 폴더 없음: {outdir}")
    slos = {part.split("=")[0]: float(part.split("=")[1])
            for part in args.slos.split(",") if part}
    apps = discover_apps(outdir, slos)
    if args.app:
        apps = [app for app in apps if app == args.app]
        if not apps:
            sys.exit(f"결과에 앱 없음: {args.app}")
    for app in apps:
        slos.setdefault(app, 1.0)

    measurements = load_measurements(outdir, apps, slos)
    windows = load_windows(outdir)
    cpu = load_cpu_window(outdir, apps, windows)
    node_cpu = load_node_cpu_window(outdir, windows)
    current = live_state(args.ns)
    node_samples = load_nodes(outdir, windows)
    ratio_now = None

    print("\n=== READ-ONLY tuning recommendation ===")
    print("클러스터 변경 없음: kubectl patch/set resources/rollout/terraform apply를 실행하지 않습니다.")
    print(f"결과: {outdir}")
    if node_samples:
        average = sum(node_samples) / len(node_samples)
        ratio_now = average / BASELINE_NODES if BASELINE_NODES else None
        print(f"노드: min={min(node_samples)} max={max(node_samples)} avg={average:.2f} ratio={average / BASELINE_NODES:.2f}")
    print(f"활성 부하창 노드 CPU 최대: {node_cpu if node_cpu is not None else '미측정'}%")

    changed = []
    for app in apps:
        measurement = measurements.get(app)
        usage = cpu.get(app)
        live = current.get(app, {})
        rec = recommendation(measurement, usage, live, node_cpu, ratio_now)
        if measurement:
            print(f"\n[{app}] avail={measurement['availability']:.1f}% perf={measurement['performance']:.1f}% p95={measurement['p95_latency']:.3f}s")
        else:
            print(f"\n[{app}] 측정 없음")
        print(f"  현재: request={live.get('request', '?')}m min={live.get('min', '?')} max={live.get('max', '?')} target={live.get('target', '?')}%")
        if usage:
            print(f"  CPU: per-pod p90={usage['per_pod_p90']}m, total p90={usage['total_p90']}m, pods p50/p90/max={usage['pods_p50']}/{usage['pods_p90']}/{usage['pods_max']}")
        print(f"  권장: request={rec['request']}m min={rec['min']} max={rec['max']} target={rec['target']}%")
        print(f"  근거: {rec['reason']}")
        if any((live.get("request") != rec["request"], live.get("min") != rec["min"],
                live.get("max") != rec["max"], live.get("target") != rec["target"])):
            changed.append((app, rec))

    print("\n--- 사용자가 검토 후 Terraform에 수동 반영할 값 ---")
    if not changed:
        print("변경 권장 없음")
    for app, rec in changed:
        print(f"{app}: requests.cpu=\"{rec['request']}m\", min_replicas={rec['min']}, max_replicas={rec['max']}, average_utilization={rec['target']}")
    print("자동 적용하지 않았습니다. 한 회차 반영 후 새 label로 180초 재측정하세요.")


if __name__ == "__main__":
    main()
