#!/usr/bin/env python3
"""공식 채점기준 기반 범용 라이브 Kubernetes 튜닝 엔진.

순수 계산과 읽기 전용 adapter만 포함한다. 실제 적용은 optimize.ps1 또는 사용자가
대시보드에 표시된 kubectl 명령을 실행한다.
"""
from __future__ import annotations

import csv
import json
import math
import os
import subprocess
from dataclasses import asdict, dataclass, field
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

import rubric

META_CSV = {"nodes", "nodecpu", "podcpu", "loadplan", "loadwindows"}
REQUEST_UNIT_M = 25
REQUEST_MIN_M = 50
TARGET_MIN = 25
TARGET_MAX = 90
NODE_CPU_HARD_PCT = 90


def clamp(value, low, high):
    return max(low, min(high, value))


def ceil_to(value, unit=REQUEST_UNIT_M):
    return int(math.ceil(float(value) / unit) * unit)


def nearest_rank(values: Sequence[float], quantile: float):
    if not values:
        return 0
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, max(0, math.ceil(quantile * len(ordered)) - 1))]


def cpu_m(value) -> Optional[int]:
    if value in (None, "", "-"):
        return None
    text = str(value).strip()
    try:
        if text.endswith("m"):
            return int(float(text[:-1]))
        if text.endswith("n"):
            return int(math.ceil(float(text[:-1]) / 1_000_000.0))
        return int(float(text) * 1000)
    except (TypeError, ValueError):
        return None


def pct(value) -> Optional[int]:
    if value in (None, "", "-"):
        return None
    try:
        return int(float(str(value).replace("%", "")))
    except ValueError:
        return None


def run(cmd, timeout=30):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8",
                              errors="replace", timeout=timeout).stdout or ""
    except Exception:
        return ""


@dataclass
class AppSnapshot:
    name: str
    slo_seconds: float
    deployment_name: Optional[str] = None
    hpa_name: Optional[str] = None
    samples: int = 0
    availability: float = 0.0
    performance: float = 0.0
    p95_latency: float = 0.0
    early_performance: Optional[float] = None
    steady_performance: Optional[float] = None
    request_m: Optional[int] = None
    cpu_limit_m: Optional[int] = None
    min_replicas: Optional[int] = None
    max_replicas: Optional[int] = None
    target: Optional[int] = None
    replicas: Optional[int] = None
    desired: Optional[int] = None
    per_pod_p50: int = 0
    per_pod_p90: int = 0
    per_pod_p95: int = 0
    total_cpu_p90: int = 0
    total_cpu_p95: int = 0
    pods_p50: int = 0
    pods_p90: int = 0
    pods_max: int = 0
    cpu_samples: int = 0
    rds_cpu_pct: Optional[float] = None
    rds_latency_ms: Optional[float] = None
    proxy_borrow_ms: Optional[float] = None

    @property
    def measured(self):
        return self.samples > 0 and self.request_m is not None and self.target is not None

    @property
    def trigger_m(self):
        if self.request_m is None or self.target is None:
            return 0.0
        return self.request_m * self.target / 100.0


@dataclass
class ClusterSnapshot:
    baseline_nodes: float = 2.0
    node_average: float = 2.0
    node_count: int = 2
    node_alloc_m: int = 0
    node_cpu_p95: int = 0
    cluster_cpu_p95_m: int = 0
    system_reserved_m: int = 0
    node_types: Tuple[str, ...] = ()

    @property
    def physical_cpu_floor(self):
        if self.node_alloc_m <= 0 or self.cluster_cpu_p95_m <= 0:
            return 1
        return max(1, int(math.ceil(self.cluster_cpu_p95_m / self.node_alloc_m)))


@dataclass
class TuningSnapshot:
    apps: Dict[str, AppSnapshot]
    cluster: ClusterSnapshot
    availability_gate: float = rubric.DEFAULT_AVAILABILITY_GATE
    history: List[dict] = field(default_factory=list)

    def score(self):
        return rubric.score(
            {name: app.performance for name, app in self.apps.items()},
            {name: app.availability for name, app in self.apps.items()},
            self.cluster.node_average,
            self.cluster.baseline_nodes,
            self.availability_gate,
        )


@dataclass
class Candidate:
    app: str
    deployment_name: str
    hpa_name: str
    kind: str
    current: dict
    proposed: dict
    reason: str
    bottleneck: str
    predicted_delta: float
    predicted_total: float
    predicted_nodes: int
    observed_cpu_floor: int
    trigger_before: float
    trigger_after: float
    disruptive: bool
    settle_seconds: int
    confidence: str
    apply_commands: List[str] = field(default_factory=list)
    rollback_commands: List[str] = field(default_factory=list)

    def key(self):
        p = self.proposed
        return f"{self.app}|{self.kind}|{p['request']}|{p['target']}|{p['min']}|{p['max']}"

    def to_dict(self):
        return asdict(self)


def _live_json(namespace="app"):
    deployments = json.loads(run(["kubectl", "-n", namespace, "get", "deploy", "-o", "json"]) or "{}")
    hpas = json.loads(run(["kubectl", "-n", namespace, "get", "hpa", "-o", "json"]) or "{}")
    nodes = json.loads(run(["kubectl", "get", "nodes", "-o", "json"]) or "{}")
    return deployments, hpas, nodes


def live_state(namespace="app"):
    state = {}
    try:
        deployments, hpas, nodes = _live_json(namespace)
        for item in deployments.get("items", []):
            name = item["metadata"]["name"]
            containers = item.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])
            if not containers:
                continue
            resources = containers[0].get("resources", {}) or {}
            current = state.setdefault(name, {})
            current["deployment_name"] = name
            current["request"] = cpu_m((resources.get("requests", {}) or {}).get("cpu"))
            current["limit"] = cpu_m((resources.get("limits", {}) or {}).get("cpu"))
        for item in hpas.get("items", []):
            spec, status = item.get("spec", {}), item.get("status", {}) or {}
            name = (spec.get("scaleTargetRef", {}) or {}).get("name") or item["metadata"]["name"]
            current = state.setdefault(name, {})
            current.update({
                "hpa_name": item["metadata"]["name"],
                "min": spec.get("minReplicas", 1), "max": spec.get("maxReplicas"),
                "replicas": status.get("currentReplicas"), "desired": status.get("desiredReplicas"),
            })
            for metric in spec.get("metrics", []):
                resource = metric.get("resource", {})
                if metric.get("type") == "Resource" and resource.get("name") == "cpu":
                    current["target"] = resource.get("target", {}).get("averageUtilization")
        alloc, types = [], []
        for item in nodes.get("items", []):
            value = cpu_m((item.get("status", {}).get("allocatable", {}) or {}).get("cpu"))
            if value:
                alloc.append(value)
            types.append((item.get("metadata", {}).get("labels", {}) or {}).get(
                "node.kubernetes.io/instance-type", "?"))
        state["__cluster__"] = {"node_alloc_m": min(alloc) if alloc else 0,
                                "node_count": len(nodes.get("items", [])),
                                "node_types": sorted(types)}
    except Exception:
        return {}
    return state


def discover_apps(outdir, slos):
    found = []
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
        try:
            with open(os.path.join(outdir, filename), encoding="utf-8", errors="replace") as f:
                if "response-time" in f.readline():
                    found.append(name)
        except OSError:
            pass
    return found or list(slos)


def load_windows(outdir):
    result = {}
    try:
        with open(os.path.join(outdir, "loadwindows.csv"), encoding="utf-8-sig", errors="replace") as f:
            for row in csv.DictReader(f):
                result[row["name"]] = (int(float(row["start_epoch"])), int(float(row["active_end_epoch"])))
    except OSError:
        pass
    return result


def _response_measurement(path, slo):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            rows = list(csv.DictReader(f))
    except OSError:
        rows = []
    if not rows:
        return {}
    latencies = [float(row["response-time"]) for row in rows]
    good2 = [row for row in rows if row["status-code"].startswith("2")
             and float(row["response-time"]) <= 5.0]
    performant = [row for row in good2 if float(row["response-time"]) <= slo]
    quarter = max(1, len(rows) // 4)
    early = rows[:quarter]
    steady = rows[len(rows) // 2:]
    rate = lambda part: 100.0 * sum(1 for row in part if row["status-code"].startswith("2")
                                    and float(row["response-time"]) <= slo) / len(part) if part else 0.0
    return {
        "samples": len(rows), "availability": 100.0 * len(good2) / len(rows),
        "performance": 100.0 * len(performant) / len(rows),
        "p95_latency": nearest_rank(latencies, .95),
        "early_performance": rate(early), "steady_performance": rate(steady),
    }


def _cpu_measurements(outdir, apps, windows):
    per_app = {name: {} for name in apps}
    cluster_by_ts = {}
    try:
        with open(os.path.join(outdir, "podcpu.csv"), encoding="utf-8", errors="replace") as f:
            for row in csv.reader(f):
                if len(row) < 3:
                    continue
                try:
                    ts, value = int(row[0]), int(row[2])
                except ValueError:
                    continue
                matching = [name for name in apps if row[1] == name or row[1].startswith(name + "-")]
                if not matching:
                    continue
                name = max(matching, key=len)
                if name not in windows or not windows[name][0] <= ts <= windows[name][1]:
                    continue
                per_app[name].setdefault(ts, []).append(value)
                cluster_by_ts[ts] = cluster_by_ts.get(ts, 0) + value
    except OSError:
        pass
    result = {}
    for name, by_ts in per_app.items():
        if not by_ts:
            continue
        flat = [value for values in by_ts.values() for value in values]
        totals = [sum(values) for values in by_ts.values()]
        counts = [len(values) for values in by_ts.values()]
        result[name] = {
            "cpu_samples": len(flat), "per_pod_p50": nearest_rank(flat, .50),
            "per_pod_p90": nearest_rank(flat, .90), "per_pod_p95": nearest_rank(flat, .95),
            "total_cpu_p90": nearest_rank(totals, .90), "total_cpu_p95": nearest_rank(totals, .95),
            "pods_p50": nearest_rank(counts, .50), "pods_p90": nearest_rank(counts, .90),
            "pods_max": max(counts),
        }
    return result, nearest_rank(list(cluster_by_ts.values()), .95)


def _cluster_csv(outdir, windows, baseline_nodes, live):
    start = min((x[0] for x in windows.values()), default=None)
    end = max((x[1] for x in windows.values()), default=None)
    nodes, node_cpu = [], []
    try:
        with open(os.path.join(outdir, "nodes.csv"), encoding="utf-8", errors="replace") as f:
            for row in csv.reader(f):
                try:
                    ts, value = int(row[0]), int(row[1])
                except (ValueError, IndexError):
                    continue
                if value > 0 and (start is None or start <= ts <= end):
                    nodes.append(value)
    except OSError:
        pass
    try:
        with open(os.path.join(outdir, "nodecpu.csv"), encoding="utf-8", errors="replace") as f:
            for row in csv.reader(f):
                try:
                    ts, value = int(row[0]), int(row[2])
                except (ValueError, IndexError):
                    continue
                if start is None or start <= ts <= end:
                    node_cpu.append(value)
    except OSError:
        pass
    cluster = live.get("__cluster__", {})
    return ClusterSnapshot(
        baseline_nodes=baseline_nodes,
        node_average=sum(nodes) / len(nodes) if nodes else baseline_nodes,
        node_count=max(nodes) if nodes else int(cluster.get("node_count") or baseline_nodes),
        node_alloc_m=int(cluster.get("node_alloc_m") or 0),
        node_cpu_p95=int(nearest_rank(node_cpu, .95) or 0),
        node_types=tuple(cluster.get("node_types") or ()),
    )


def snapshot_from_outdir(outdir, slos, namespace="app", baseline_nodes=2.0, live=None,
                         availability_gate=99.0):
    live = live if live is not None else live_state(namespace)
    names = [name for name in discover_apps(outdir, slos) if name in slos]
    windows = load_windows(outdir)
    cpu, cluster_cpu = _cpu_measurements(outdir, names, windows)
    cluster = _cluster_csv(outdir, windows, baseline_nodes, live)
    cluster.cluster_cpu_p95_m = cluster_cpu
    apps = {}
    for name in names:
        measurement = _response_measurement(os.path.join(outdir, name + ".csv"), slos[name])
        current = live.get(name, {})
        app = AppSnapshot(
            name=name, slo_seconds=float(slos[name]),
            deployment_name=current.get("deployment_name") or name,
            hpa_name=current.get("hpa_name") or name,
            request_m=current.get("request"),
            cpu_limit_m=current.get("limit"), min_replicas=current.get("min"),
            max_replicas=current.get("max"), target=current.get("target"),
            replicas=current.get("replicas"), desired=current.get("desired"),
            **measurement, **cpu.get(name, {}),
        )
        apps[name] = app
    return TuningSnapshot(apps, cluster, availability_gate)


def snapshot_from_dashboard(data, baseline_nodes=2.0, cpu_history=None, availability_gate=99.0):
    cpu_history = cpu_history or {}
    hpamap = {row.get("name"): row for row in data.get("hpa", [])}
    pods = data.get("pods", [])
    nodes = data.get("nodes", [])
    apps = {}
    for row in data.get("apps", []):
        name, hpa = row.get("app"), hpamap.get(row.get("app"), {})
        selector = row.get("selector") or name
        values = [cpu_m(v) for v in cpu_history.get(selector, [])]
        values = [v for v in values if v]
        current_values = [cpu_m(p.get("cpu")) for p in pods if p.get("app") == selector and p.get("phase") == "Running"]
        current_values = [v for v in current_values if v]
        observed = values or current_values
        app_pods = len([p for p in pods if p.get("app") == selector and p.get("phase") == "Running"])
        apps[name] = AppSnapshot(
            name=name, slo_seconds=float(row.get("slo_ms", 1000)) / 1000.0,
            deployment_name=row.get("deployment_name") or name,
            hpa_name=hpa.get("hpa_name") or name,
            samples=int(row.get("total") or 0), availability=float(row.get("ok_rate") or 0),
            performance=float(row.get("slo_rate") or 0), p95_latency=float(row.get("p95") or 0) / 1000.0,
            request_m=cpu_m(row.get("cpu_req")), min_replicas=hpa.get("min"),
            max_replicas=hpa.get("max"), target=pct(hpa.get("tgt")), replicas=hpa.get("replicas"),
            per_pod_p50=int(nearest_rank(observed, .50) or 0), per_pod_p90=int(nearest_rank(observed, .90) or 0),
            per_pod_p95=int(nearest_rank(observed, .95) or 0), cpu_samples=len(observed),
            total_cpu_p90=int(nearest_rank(observed, .90) * app_pods if observed else 0),
            total_cpu_p95=int(nearest_rank(observed, .95) * app_pods if observed else 0),
            pods_p50=app_pods, pods_p90=app_pods, pods_max=app_pods,
        )
    allocs = [int(n.get("cpu_alloc") or 0) for n in nodes if int(n.get("cpu_alloc") or 0) > 0]
    node_cpu = [pct(n.get("cpu_pct")) for n in nodes]
    node_cpu = [v for v in node_cpu if v is not None]
    total_current = sum(cpu_m(p.get("cpu")) or 0 for p in pods if p.get("phase") == "Running")
    cluster = ClusterSnapshot(
        baseline_nodes=baseline_nodes, node_average=float(len(nodes) or baseline_nodes),
        node_count=len(nodes), node_alloc_m=min(allocs) if allocs else 0,
        node_cpu_p95=int(nearest_rank(node_cpu, .95) or 0), cluster_cpu_p95_m=total_current,
        node_types=tuple(sorted(str(n.get("type") or "?") for n in nodes)),
    )
    return TuningSnapshot(apps, cluster, availability_gate)


def classify_bottleneck(app: AppSnapshot, cluster: ClusterSnapshot, history=None):
    history = history or []
    if app.availability < rubric.DEFAULT_AVAILABILITY_GATE:
        if app.max_replicas and app.pods_max >= app.max_replicas:
            return "hpa-max"
        if app.early_performance is not None and app.steady_performance is not None \
                and app.steady_performance - app.early_performance >= 10:
            return "cold-start"
        return "scale-delay"
    if app.performance < rubric.RATE_BANDS[-1]:
        if app.max_replicas and app.pods_max >= app.max_replicas:
            return "hpa-max"
        if cluster.node_cpu_p95 >= 85:
            return "node-cpu"
        if app.request_m and app.per_pod_p90 and app.per_pod_p90 < app.request_m * .5:
            if (app.rds_cpu_pct or 0) >= 70 or (app.proxy_borrow_ms or 0) >= 50:
                return "db-rds"
            return "cpu-not-root"
        trials = [h for h in history if h.get("app") == app.name and h.get("replicas_after", 0) > h.get("replicas_before", 0)]
        if trials and all(float(h.get("performance_after", 0)) - float(h.get("performance_before", 0)) < .5 for h in trials):
            return "non-scalable"
        return "pod-cpu"
    return "balanced"


def _current_dict(app):
    return {"request": int(app.request_m or REQUEST_MIN_M), "target": int(app.target or 70),
            "min": int(app.min_replicas or 1), "max": int(app.max_replicas or max(2, app.min_replicas or 1)),
            "replicas": int(app.replicas or app.min_replicas or 1)}


def _estimated_nodes(snapshot: TuningSnapshot, changed_app: str, proposed: dict):
    alloc = snapshot.cluster.node_alloc_m
    if alloc <= 0:
        return snapshot.cluster.node_count or int(math.ceil(snapshot.cluster.node_average))
    total = snapshot.cluster.system_reserved_m
    for name, app in snapshot.apps.items():
        req = proposed["request"] if name == changed_app else int(app.request_m or REQUEST_MIN_M)
        pods = proposed.get("estimated_replicas", 0) if name == changed_app else 0
        if not pods:
            pods = int(app.pods_p90 or app.replicas or app.min_replicas or 1)
        total += req * pods
    return max(1, int(math.ceil(total / alloc)))


def _predicted_replicas(app, proposed):
    trigger = max(1.0, proposed["request"] * proposed["target"] / 100.0)
    if app.total_cpu_p90:
        return max(proposed["min"], min(proposed["max"], int(math.ceil(app.total_cpu_p90 / trigger))))
    return max(proposed["min"], min(proposed["max"], int(app.replicas or proposed["min"])))


def _commands(namespace, app: AppSnapshot, current, proposed):
    deployment = app.deployment_name or app.name
    hpa = app.hpa_name or app.name
    safe_hpa = "".join(ch if ch.isalnum() or ch in "-_" else "-" for ch in hpa)
    def patch(values, suffix):
        body = {"spec": {"minReplicas": values["min"], "maxReplicas": values["max"],
                         "metrics": [{"type": "Resource", "resource": {"name": "cpu",
                         "target": {"type": "Utilization", "averageUtilization": values["target"]}}}]}}
        text = json.dumps(body, separators=(",", ":"))
        path = f'$env:TEMP\\hpa-{safe_hpa}-{suffix}.json'
        return [f"'{text}' | Set-Content -Path \"{path}\" -Encoding ascii",
                f'kubectl -n {namespace} patch hpa {hpa} --type=merge --patch-file \"{path}\"']
    apply = patch(proposed, "apply")
    rollback = []
    if proposed["request"] != current["request"]:
        apply += [f"kubectl -n {namespace} set resources deploy/{deployment} --requests=cpu={proposed['request']}m",
                  f"kubectl -n {namespace} rollout status deploy/{deployment} --timeout=120s"]
        rollback += [f"kubectl -n {namespace} set resources deploy/{deployment} --requests=cpu={current['request']}m",
                     f"kubectl -n {namespace} rollout status deploy/{deployment} --timeout=120s"]
    rollback += patch(current, "rollback")
    return apply, rollback


def _make_candidate(snapshot, app, kind, proposed, reason, priority, namespace="app"):
    current = _current_dict(app)
    proposed = dict(proposed)
    proposed["estimated_replicas"] = _predicted_replicas(app, proposed)
    predicted_nodes = _estimated_nodes(snapshot, app.name, proposed)
    cpu_floor = snapshot.cluster.physical_cpu_floor
    if predicted_nodes < cpu_floor:
        return None
    result = snapshot.score()
    predicted_score = rubric.score(
        {name: value.performance for name, value in snapshot.apps.items()},
        {name: value.availability for name, value in snapshot.apps.items()},
        float(predicted_nodes), snapshot.cluster.baseline_nodes, snapshot.availability_gate)
    delta = predicted_score.total - result.total
    if kind in ("gate-recovery", "performance-band"):
        delta = max(delta, priority)
    apply, rollback = _commands(namespace, app, current, proposed)
    disruptive = proposed["request"] != current["request"]
    return Candidate(
        app=app.name, deployment_name=app.deployment_name or app.name,
        hpa_name=app.hpa_name or app.name, kind=kind, current=current, proposed=proposed, reason=reason,
        bottleneck=classify_bottleneck(app, snapshot.cluster, snapshot.history),
        predicted_delta=round(delta, 2), predicted_total=round(result.total + delta, 2),
        predicted_nodes=predicted_nodes, observed_cpu_floor=cpu_floor,
        trigger_before=round(app.trigger_m, 2),
        trigger_after=round(proposed["request"] * proposed["target"] / 100.0, 2),
        disruptive=disruptive, settle_seconds=60 if disruptive else (105 if kind == "cost-reclaim" else 25),
        confidence="high" if app.samples >= 100 and app.cpu_samples >= 10 else "low",
        apply_commands=apply, rollback_commands=rollback,
    )


def generate_candidates(snapshot: TuningSnapshot, rejected=None, namespace="app"):
    rejected = set(rejected or ())
    candidates = []
    any_gate_failure = any(app.performance < rubric.COST_PERF_GATE or app.availability < snapshot.availability_gate
                           for app in snapshot.apps.values())
    for app in snapshot.apps.values():
        if not app.measured:
            continue
        current = _current_dict(app)
        bottleneck = classify_bottleneck(app, snapshot.cluster, snapshot.history)
        if app.performance < rubric.COST_PERF_GATE or app.availability < snapshot.availability_gate:
            proposed = dict(current)
            proposed["target"] = max(TARGET_MIN, current["target"] - 15)
            if bottleneck == "hpa-max":
                proposed["max"] = current["max"] + max(2, int(math.ceil(current["max"] * .25)))
            if bottleneck == "cold-start" and current["min"] < current["max"]:
                proposed["min"] = min(current["max"], current["min"] + 1)
            c = _make_candidate(snapshot, app, "gate-recovery", proposed,
                                f"안전 게이트 복구: perf {app.performance:.1f}%, avail {app.availability:.1f}%",
                                6.0, namespace)
            if c and c.key() not in rejected:
                candidates.append(c)
            continue
        if any_gate_failure:
            continue
        nxt, gap = rubric.next_band(app.performance)
        if 0 < gap <= 3.0 and current["target"] > TARGET_MIN:
            proposed = dict(current)
            proposed["target"] = max(TARGET_MIN, current["target"] - 10)
            c = _make_candidate(snapshot, app, "performance-band", proposed,
                                f"공식 {nxt:g}% 밴드까지 {gap:.2f}%p; HPA를 일찍 확장", .5, namespace)
            if c and c.key() not in rejected:
                candidates.append(c)
        # request packing: 충분한 CPU 표본이 있을 때만, 기존 절대 trigger 보존.
        if app.cpu_samples >= 10 and current["request"] > REQUEST_MIN_M and current["target"] < TARGET_MAX:
            new_target = min(TARGET_MAX, max(current["target"] + 15, 75))
            new_request = max(REQUEST_MIN_M, ceil_to(app.trigger_m * 100.0 / new_target))
            if app.cpu_limit_m:
                new_request = min(new_request, app.cpu_limit_m)
            if new_request <= current["request"] - REQUEST_UNIT_M:
                proposed = dict(current)
                proposed.update({"request": new_request,
                                 "target": int(clamp(round(app.trigger_m * 100.0 / new_request), TARGET_MIN, TARGET_MAX))})
                c = _make_candidate(snapshot, app, "request-packing", proposed,
                                    f"request 예약을 줄이고 절대 HPA trigger {app.trigger_m:.0f}m 보존",
                                    0.0, namespace)
                if c and c.key() not in rejected and c.predicted_nodes < math.ceil(snapshot.cluster.node_average):
                    candidates.append(c)
        if snapshot.cluster.node_average / snapshot.cluster.baseline_nodes > 1.0 \
                and bottleneck not in ("db-rds", "non-scalable") and current["target"] < TARGET_MAX:
            floor = rubric.band_floor(app.performance)
            margin = app.performance - floor
            if margin >= 2.0:
                proposed = dict(current)
                proposed["target"] = min(TARGET_MAX, current["target"] + 10)
                c = _make_candidate(snapshot, app, "cost-reclaim", proposed,
                                    f"공식 {floor:g}% 밴드 위 {margin:.1f}%p 여유; HPA trigger를 높여 비용 회수",
                                    0.0, namespace)
                if c and c.key() not in rejected and c.predicted_nodes <= math.ceil(snapshot.cluster.node_average):
                    candidates.append(c)
    kind_rank = {"gate-recovery": 4, "performance-band": 3, "request-packing": 2, "cost-reclaim": 1}
    candidates.sort(key=lambda c: (c.predicted_delta, kind_rank.get(c.kind, 0),
                                   -int(c.disruptive), -c.predicted_nodes), reverse=True)
    return candidates


def plan(snapshot: TuningSnapshot, rejected=None, namespace="app"):
    score = snapshot.score()
    candidates = generate_candidates(snapshot, rejected, namespace)
    apps = []
    for name, app in sorted(snapshot.apps.items()):
        apps.append({
            "app": name, "deployment_name": app.deployment_name or name,
            "hpa_name": app.hpa_name or name,
            "measured": app.measured, "samples": app.samples,
            "availability": round(app.availability, 3), "performance": round(app.performance, 3),
            "request": app.request_m, "target": app.target, "min": app.min_replicas,
            "max": app.max_replicas, "replicas": app.replicas,
            "trigger": round(app.trigger_m, 2), "cpu_p90": app.per_pod_p90,
            "total_cpu_p90": app.total_cpu_p90, "bottleneck": classify_bottleneck(app, snapshot.cluster, snapshot.history),
        })
    return {
        "schema_version": 1,
        "done": not candidates,
        "reason": "개선 후보 없음 — 현재 측정에서 안전하게 공식 점수를 올릴 수 없음" if not candidates else "",
        "score": score.to_dict(), "apps": apps,
        "cluster": asdict(snapshot.cluster),
        "candidates": [c.to_dict() for c in candidates[:3]],
        "best": candidates[0].to_dict() if candidates else None,
    }
