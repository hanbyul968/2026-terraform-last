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
# 선형 지연 모델(지연 ∝ CPU 공급 부족 배수)은 관측 범위를 크게 벗어나면 신뢰할 수 없다.
# 한 회차에서 허용하는 외삽 한도. 더 내려가려면 그 값을 실측한 뒤 다음 회차가 이어서 판단한다.
MAX_EXTRAPOLATED_SLOWDOWN = 1.5
# 비용 우선 모드 기준선. 공식 채점에서 가용성은 90%면 앱당 만점이므로 그 경계를 지키고,
# 성능은 80% 밴드를 유지선으로 둔다(30%까지 내려가면 비용 12점이 0이 되고 성능 점수도 폭락한다).
COST_FIRST_AVAIL_FLOOR = 90.0
COST_FIRST_PERF_FLOOR = 80.0
COST_FIRST_MAX_SLOWDOWN = 3.0
# request는 실측 사용량과 동떨어질 수 없다. 파드당 실사용의 이 비율 아래로는 내리지 않는다.
# (실측 1800m 쓰는 파드에 50m을 예약하는 값이 나오던 문제를 막는다.)
REQUEST_USAGE_FLOOR_RATIO = 0.5
# 사이징은 '노드를 꽉 채우는 최대 request'가 아니라 그보다 낮게 잡는다. 여유를 둬야 앱/트래픽이
# 바뀌어도 유휴 파드가 baseline 노드에 넉넉히 들어가고, 부족분은 HPA replica가 채운다.
# 계산된 필요 request에 이 계수를 곱해 낮춘다(0.7 = 30% 낮게).
REQUEST_HEADROOM = 0.7


def clamp(value, low, high):
    return max(low, min(high, value))


def ceil_to(value, unit=REQUEST_UNIT_M):
    return int(math.ceil(float(value) / unit) * unit)


def nearest_rank(values: Sequence[float], quantile: float):
    if not values:
        return 0
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, max(0, math.ceil(quantile * len(ordered)) - 1))]


def bin_pack_nodes(pod_requests, node_capacity_m):
    """파드 request 리스트를 노드 용량에 first-fit-decreasing으로 담아 필요한 노드 수를 센다.

    노드 수는 '총 예약 합 / 용량'(=평균)이 아니라 실제 스케줄링으로 정해진다.
    예: 용량 1480m에 [775,775,750,750]은 합 3050m라 2노드처럼 보이지만, 775+750=1525>1480이라
    같은 노드에 못 앉아 4노드가 뜬다. 이 함수가 그 차이를 계산한다.
    """
    caps = []
    for req in sorted((int(r) for r in pod_requests if r), reverse=True):
        for i in range(len(caps)):
            if caps[i] + req <= node_capacity_m:
                caps[i] += req
                break
        else:
            caps.append(req)
    return len(caps)


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


def mem_mi(value) -> int:
    """메모리 요청을 MiB 정수로. 노드 메모리도 파드 수 상한을 만든다."""
    if value in (None, "", "-"):
        return 0
    text = str(value).strip()
    try:
        for suffix, factor in (("Ki", 1 / 1024), ("Mi", 1), ("Gi", 1024), ("Ti", 1024 * 1024),
                               ("K", 1000 / 1048576), ("M", 1000000 / 1048576),
                               ("G", 1000000000 / 1048576)):
            if text.endswith(suffix):
                return int(float(text[:-len(suffix)]) * factor)
        return int(float(text) / 1048576)
    except (TypeError, ValueError):
        return 0


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
    memory_request_mi: int = 0
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
    latencies: Tuple[float, ...] = ()
    window_seconds: float = 0.0

    @property
    def cpu_seconds_per_request(self):
        """요청 1건이 실제로 쓴 CPU 시간(초). 측정값만 사용한다."""
        if not self.window_seconds or not self.samples or not self.total_cpu_p90:
            return None
        rps = self.samples / self.window_seconds
        if rps <= 0:
            return None
        return (self.total_cpu_p90 / 1000.0) / rps

    @property
    def cpu_bound_fraction(self):
        """지연 중 CPU 처리 비중(0~1). 나머지는 DB/네트워크 대기로 본다.

        대회날 앱이 바뀌어도 이 값을 매 측정에서 다시 구하므로, CPU 바운드 앱은 노드 감소에
        민감하게, DB 대기형/고정 지연형 앱은 둔감하게 평가된다. 측정이 부족하면 1.0(보수적)로
        둬서 노드를 과감하게 줄이지 않는다.
        """
        cpu_seconds = self.cpu_seconds_per_request
        if cpu_seconds is None or not self.latencies:
            return 1.0
        mean_latency = sum(self.latencies) / len(self.latencies)
        if mean_latency <= 0:
            return 1.0
        return float(clamp(cpu_seconds / mean_latency, 0.0, 1.0))

    @property
    def measured_rps(self):
        if not self.window_seconds or not self.samples:
            return 0.0
        return self.samples / self.window_seconds

    def required_cpu_m(self, target_rps=None):
        """부하량에 정규화된 필요 CPU(밀리코어).

        측정 당시 부하가 얼마였는지에 좌우되지 않게, 부하와 무관한 값인
        '요청당 CPU 시간'에 목표 초당 요청수를 곱해 구한다.
            필요 CPU = 요청당 CPU 시간 x 목표 rps
        목표 rps를 주지 않으면 측정 당시 rps를 쓴다(그때는 측정값과 동일해진다).
        """
        cpu_seconds = self.cpu_seconds_per_request
        if cpu_seconds is None:
            return int(self.total_cpu_p95 or self.total_cpu_p90 or 0)
        rps = target_rps if target_rps else self.measured_rps
        return int(round(cpu_seconds * max(rps, 0.0) * 1000))

    def performance_at(self, slowdown: float):
        """CPU 공급이 slowdown배 부족할 때의 성능%/가용성% 추정.

        지연 = CPU 처리분 + 대기분으로 보고 CPU 처리분만 공급 부족 배수로 늘린다.
        비중은 실측(요청당 CPU 시간 / 평균 지연)에서 구한다.
        """
        if not self.latencies:
            return self.performance, self.availability
        factor = 1.0 + (max(1.0, float(slowdown)) - 1.0) * self.cpu_bound_fraction
        total = len(self.latencies)
        perf = 100.0 * sum(1 for x in self.latencies if x * factor <= self.slo_seconds) / total
        avail = 100.0 * sum(1 for x in self.latencies if x * factor <= 5.0) / total
        return perf, avail

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
    node_mem_alloc_mi: int = 0
    node_cpu_p95: int = 0
    cluster_cpu_p95_m: int = 0
    system_reserved_m: int = 0
    node_types: Tuple[str, ...] = ()
    # 관리형 노드그룹 고정 대수(node_desired_size). 이 수를 넘으면 Karpenter 노드가 상주한다.
    baseline_node_count: int = 2
    # AZ 수. topology spread가 파드를 AZ에 흩어 노드 패킹이 AZ별로 일어난다.
    zone_count: int = 2

    @property
    def daemonset_per_node_m(self):
        """DaemonSet 등 시스템 예약은 노드마다 붙는다. 총합을 고정값으로 더하면 노드가 늘수록
        예약이 부풀어 계산이 틀어진다(실측: 6노드에서 총 1500m = 노드당 250m)."""
        if self.system_reserved_m <= 0 or self.node_count <= 0:
            return 0
        return int(self.system_reserved_m / self.node_count)

    @property
    def usable_cpu_per_node_m(self):
        """앱 파드가 실제로 쓸 수 있는 노드당 CPU."""
        return max(1, self.node_alloc_m - self.daemonset_per_node_m)

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
    cost_first: bool = True
    avail_floor: float = COST_FIRST_AVAIL_FLOOR
    perf_floor: float = COST_FIRST_PERF_FLOOR
    # 측정 당시 부하가 채점 부하와 같다고 가정하지 않는다. 1.0이면 측정 부하 기준,
    # 0.5면 그 절반 부하를 목표로 사이징한다. 앱별 목표 rps를 직접 줄 수도 있다.
    load_scale: float = 1.0
    target_rps: Dict[str, float] = field(default_factory=dict)

    def app_target_rps(self, name):
        app = self.apps[name]
        if name in self.target_rps:
            return float(self.target_rps[name])
        return app.measured_rps * max(self.load_scale, 0.0)

    def app_required_cpu_m(self, name):
        return self.apps[name].required_cpu_m(self.app_target_rps(name))

    def idle_nodes(self, plan_map=None):
        """유휴(min replicas) 상태에서 실제로 뜨는 노드 수. bin-packing으로 계산한다.

        대회날 '아무것도 안 하는데' 뜨는 노드가 이 값이다. 파드당 request가 커서 baseline
        노드(관리형 NG)에 min replica들이 안 들어가면, Karpenter 노드가 상주해 회수되지 않는다.
        총 예약 합으로는 안 보이고 개별 파드가 노드에 담기는지를 봐야 한다.

        topology spread(zone maxSkew=1)가 있으면 각 앱 파드가 AZ에 고르게 흩어지므로,
        노드 패킹도 AZ별로 따로 일어난다. 그래서 AZ 수로 나눠 zone별로 bin-packing한 뒤 합친다.
        """
        plan_map = plan_map or {}
        cap = self.cluster.usable_cpu_per_node_m
        zones = max(1, self.cluster.zone_count)
        zone_pods = [[] for _ in range(zones)]
        for name, app in self.apps.items():
            change = plan_map.get(name)
            req = int(change["request"]) if change else int(app.request_m or REQUEST_MIN_M)
            mn = int((change or {}).get("min", app.min_replicas or 1))
            # min replica를 AZ에 라운드로빈으로 배분(zone spread maxSkew=1 근사)
            for i in range(max(1, mn)):
                zone_pods[i % zones].append(req)
        return sum(bin_pack_nodes(pods, cap) for pods in zone_pods)

    def required_cluster_cpu_m(self):
        """목표 부하에서 필요한 앱 CPU 합계. 측정 부하가 아니라 목표 부하 기준이다."""
        total = sum(self.app_required_cpu_m(name) for name in self.apps)
        if total > 0:
            return total
        return self.cluster.cluster_cpu_p95_m

    @property
    def max_slowdown(self):
        return COST_FIRST_MAX_SLOWDOWN if self.cost_first else MAX_EXTRAPOLATED_SLOWDOWN

    def acceptable(self, result):
        """비용을 챙길 때 실제로 지켜야 하는 선.

        공식 채점: 가용성 >= 90%면 앱당 만점, 성능 < 30%면 비용 12점 전부 0.
        따라서 비용 우선 모드는 avail_floor(기본 92%)와 perf_floor(기본 35%)만 지키면 된다.
        균형 모드는 기존처럼 가용성 99%를 유지한다.
        """
        if self.cost_first:
            return (result.min_availability >= self.avail_floor
                    and result.min_performance >= self.perf_floor
                    and result.cost_points > 0)
        return result.perf_gate_pass and result.avail_gate_pass

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
    cpu_supply_ratio: float
    risk: str
    disruptive: bool
    settle_seconds: int
    confidence: str
    apply_commands: List[str] = field(default_factory=list)
    rollback_commands: List[str] = field(default_factory=list)
    knobs: Dict[str, dict] = field(default_factory=dict)

    def key(self):
        parts = []
        for name in sorted(self.knobs or {self.app: self.proposed}):
            p = (self.knobs or {self.app: self.proposed})[name]
            parts.append(f"{name}:{p['request']}:{p['target']}:{p['min']}:{p['max']}")
        return f"{self.kind}|" + "|".join(parts)

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
            current["memory"] = mem_mi((resources.get("requests", {}) or {}).get("memory"))
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
        alloc, types, mem_alloc = [], [], []
        baseline_ng = 0
        zones = set()
        for item in nodes.get("items", []):
            labels = item.get("metadata", {}).get("labels", {}) or {}
            zone = labels.get("topology.kubernetes.io/zone")
            if zone:
                zones.add(zone)
            allocatable = item.get("status", {}).get("allocatable", {}) or {}
            value = cpu_m(allocatable.get("cpu"))
            if value:
                alloc.append(value)
            memory = mem_mi(allocatable.get("memory"))
            if memory:
                mem_alloc.append(memory)
            types.append(labels.get("node.kubernetes.io/instance-type", "?"))
            # 관리형 노드그룹 노드(고정 대수) = Karpenter가 회수하지 않는 baseline.
            if "eks.amazonaws.com/nodegroup" in labels and "karpenter.sh/nodepool" not in labels:
                baseline_ng += 1
        state["__cluster__"] = {"node_alloc_m": min(alloc) if alloc else 0,
                               "node_mem_alloc_mi": min(mem_alloc) if mem_alloc else 0,
                               "node_count": len(nodes.get("items", [])),
                               "baseline_node_count": baseline_ng or 2,
                               "zone_count": len(zones) or 2,
                               "node_types": sorted(types),
                               "system_reserved_m": _system_reserved_m(namespace)}
    except Exception:
        return {}
    return state


def _system_reserved_m(namespace="app"):
    """앱 네임스페이스 밖 Pod의 CPU request 합계 (DaemonSet/컨트롤러 등).

    Karpenter는 실사용이 아니라 request로 노드를 만든다. 이 값을 빼먹으면 노드 예측이
    시스템 Pod만큼 낮게 나온다.
    """
    try:
        pods = json.loads(run(["kubectl", "get", "pods", "-A", "-o", "json"]) or "{}")
    except Exception:
        return 0
    total = 0
    for item in pods.get("items", []):
        meta = item.get("metadata", {})
        if meta.get("namespace") == namespace:
            continue
        if (item.get("status", {}) or {}).get("phase") not in ("Running", "Pending"):
            continue
        for container in item.get("spec", {}).get("containers", []) or []:
            total += cpu_m(((container.get("resources", {}) or {}).get("requests", {}) or {}).get("cpu")) or 0
    return total


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
    ok2 = [float(row["response-time"]) for row in rows if row["status-code"].startswith("2")]
    step = max(1, len(ok2) // 3000)
    return {
        "samples": len(rows), "availability": 100.0 * len(good2) / len(rows),
        "performance": 100.0 * len(performant) / len(rows),
        "p95_latency": nearest_rank(latencies, .95),
        "early_performance": rate(early), "steady_performance": rate(steady),
        "latencies": tuple(ok2[::step]),
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
        node_mem_alloc_mi=int(cluster.get("node_mem_alloc_mi") or 0),
        node_cpu_p95=int(nearest_rank(node_cpu, .95) or 0),
        node_types=tuple(cluster.get("node_types") or ()),
        system_reserved_m=int(cluster.get("system_reserved_m") or 0),
        baseline_node_count=int(cluster.get("baseline_node_count") or 2),
        zone_count=int(cluster.get("zone_count") or 2),
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
        window = windows.get(name)
        app = AppSnapshot(
            name=name, slo_seconds=float(slos[name]),
            deployment_name=current.get("deployment_name") or name,
            hpa_name=current.get("hpa_name") or name,
            request_m=current.get("request"),
            memory_request_mi=int(current.get("memory") or 0),
            cpu_limit_m=current.get("limit"), min_replicas=current.get("min"),
            max_replicas=current.get("max"), target=current.get("target"),
            replicas=current.get("replicas"), desired=current.get("desired"),
            window_seconds=float(max(1, window[1] - window[0])) if window else 0.0,
            **measurement, **cpu.get(name, {}),
        )
        apps[name] = app
    return TuningSnapshot(apps, cluster, availability_gate)


def snapshot_from_dashboard(data, baseline_nodes=2.0, cpu_history=None, availability_gate=99.0,
                            window_seconds=0.0, system_reserved_m=0):
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
            window_seconds=float(window_seconds or 0.0),
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
        system_reserved_m=int(system_reserved_m or 0),
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


def _reservation_nodes(snapshot: TuningSnapshot, changed, proposed=None):
    """changed: 앱 이름(단일) 또는 {앱: proposed} 딕셔너리."""
    plan_map = changed if isinstance(changed, dict) else (
        {changed: proposed} if changed and proposed else {})
    alloc = snapshot.cluster.node_alloc_m
    if alloc <= 0:
        return snapshot.cluster.node_count or int(math.ceil(snapshot.cluster.node_average))
    total = 0
    total_mem = 0
    pod_reqs = []
    for name, app in snapshot.apps.items():
        change = plan_map.get(name)
        req = int(change["request"]) if change else int(app.request_m or REQUEST_MIN_M)
        observed = int(app.pods_p90 or app.replicas or app.min_replicas or 1)
        if change and change.get("estimated_replicas"):
            # 실측 관측 파드 수보다 적게 잡으면 예약을 과소평가해 노드 하한이 무너진다.
            pods = max(int(change["estimated_replicas"]), observed) if not change.get("consolidate") \
                else int(change["estimated_replicas"])
        else:
            pods = observed
        total += req * pods
        total_mem += int(app.memory_request_mi or 0) * pods
        pod_reqs += [req] * pods
    # bin-packing으로 실제 스케줄링을 반영한다. 총합/용량(평균)은 큰 파드가 노드에 안 들어가는
    # 경우를 놓친다(예: 775+750>1480이라 같은 노드 불가 -> 노드가 더 뜬다).
    cpu_nodes = bin_pack_nodes(pod_reqs, snapshot.cluster.usable_cpu_per_node_m)
    mem_nodes = 0
    if snapshot.cluster.node_mem_alloc_mi > 0 and total_mem > 0:
        # 파드당 메모리 요청도 노드 수를 만든다. 파드 수를 줄이면 여기서 이득이 난다.
        mem_nodes = int(math.ceil(total_mem / snapshot.cluster.node_mem_alloc_mi))
    return max(1, cpu_nodes, mem_nodes)


def _node_calibration(snapshot: TuningSnapshot):
    """예약 기반 예측을 실측 평균 노드 수에 맞춘 보정 계수.

    bin-packing 손실, HPA 과도 구간, Karpenter 지연 때문에 실제 노드는 예약 계산보다 많다
    (실측: 예측 6대 vs 실제 평균 7대). 비용은 실제 노드로 채점되므로 이 계수를 곱해야
    예측 이득이 낙관적으로 나오지 않는다.
    """
    baseline = _reservation_nodes(snapshot, "", {})
    if baseline <= 0 or snapshot.cluster.node_average <= 0:
        return 1.0
    return max(1.0, snapshot.cluster.node_average / baseline)


def _estimated_node_average(snapshot: TuningSnapshot, changed, proposed=None):
    """비용 채점용 평균 노드 수(소수). 정수로 올리면 현재 상태조차 손해로 계산된다."""
    raw = _reservation_nodes(snapshot, changed, proposed)
    return max(1.0, raw * _node_calibration(snapshot))


def _estimated_nodes(snapshot: TuningSnapshot, changed, proposed=None):
    """용량/하한 판정용 정수 노드 수."""
    return max(1, int(math.ceil(_estimated_node_average(snapshot, changed, proposed))))


def _predicted_replicas(app, proposed):
    trigger = max(1.0, proposed["request"] * proposed["target"] / 100.0)
    if app.total_cpu_p90:
        return max(proposed["min"], min(proposed["max"], int(math.ceil(app.total_cpu_p90 / trigger))))
    return max(proposed["min"], min(proposed["max"], int(app.replicas or proposed["min"])))


def _predicted_score(snapshot: TuningSnapshot, nodes: int, node_average=None):
    """노드 수가 nodes일 때의 공식 점수 추정.

    CPU 공급이 실측 수요보다 적으면 그 배수만큼 지연이 늘어난다고 보고 앱별 성능/가용성을
    다시 계산한다. 비용은 실측처럼 평균 노드(소수)로 채점한다.
    """
    supply = nodes * snapshot.cluster.node_alloc_m
    demand = snapshot.required_cluster_cpu_m()
    slowdown = demand / supply if supply and demand else 1.0
    perfs, avails = {}, {}
    for name, app in snapshot.apps.items():
        perf, avail = app.performance_at(slowdown)
        perfs[name], avails[name] = perf, avail
    return (rubric.score(perfs, avails,
                         float(node_average if node_average is not None else nodes),
                         snapshot.cluster.baseline_nodes, snapshot.availability_gate),
            round(max(slowdown, 0.0), 3))


def deterministic_reservation(snapshot: TuningSnapshot):
    """실측 CPU 수요에서 '필요 노드 수와 그에 맞는 앱별 request'를 한 번에 계산한다.

    탐색이 아니라 나눗셈이다.
        필요 노드 = ceil((시스템 예약 + 앱 동시 CPU p95 합) / 노드 allocatable)
        앱 예약 예산 = 필요 노드 x allocatable - 시스템 예약
        앱별 request = 예산 x (앱 CPU 비중) / 파드수
    이렇게 하면 예약이 실제 수요와 일치해 과투자도, 과소예약도 없다. 이미 현재 노드 수가
    필요 노드와 같으면 request로는 비용을 더 줄일 수 없다는 뜻이므로 즉시 수렴을 알린다.
    """
    alloc = snapshot.cluster.node_alloc_m
    usable = snapshot.cluster.usable_cpu_per_node_m
    # 수요는 목표 부하에서의 필요 CPU다. 측정 당시 부하에 좌우되지 않는다.
    demand = snapshot.required_cluster_cpu_m()
    shares = {name: max(snapshot.app_required_cpu_m(name), 0) for name in snapshot.apps}
    shares_total = sum(shares.values())
    if alloc <= 0 or demand <= 0 or shares_total <= 0:
        return None
    nodes_min = max(1, int(math.ceil(demand / usable)))
    budget = nodes_min * usable
    knobs = {}
    for name, app in snapshot.apps.items():
        if not app.measured:
            continue
        current = _current_dict(app)
        pods = max(1, int(app.pods_p90 or app.replicas or current["min"]))
        share = shares.get(name, 0) / shares_total
        request = max(REQUEST_MIN_M, ceil_to(budget * share / pods * REQUEST_HEADROOM))
        if app.cpu_limit_m:
            request = min(request, app.cpu_limit_m)
        proposed = dict(current)
        proposed["request"] = request
        if app.trigger_m > 0:
            proposed["target"] = int(clamp(round(app.trigger_m * 100.0 / request),
                                           TARGET_MIN, TARGET_MAX))
        knobs[name] = proposed
    return {"nodes": nodes_min, "demand_m": demand, "budget_m": budget, "knobs": knobs}


def _usage_sized(snapshot, app: AppSnapshot, current: dict):
    """목표 부하에서의 필요 CPU로 request를 한 번에 역산한다.

    `request = (요청당 CPU x 목표 rps) / 파드수`.
    측정 당시 부하가 아니라 **목표 부하** 기준이므로, 부하를 세게 넣고 측정했다고 해서
    request가 과대하게 나오지 않는다. 목표 부하는 `load_scale` 또는 `target_rps`로 준다.
    HPA target은 실측으로 검증된 절대 발동점(request x target)을 최대한 보존한다.
    """
    pods = int(app.pods_p90 or app.replicas or current["min"] or 1)
    required = snapshot.app_required_cpu_m(app.name)
    if not required or pods <= 0:
        return None
    # 필요치의 최대가 아니라 여유(HEADROOM)를 둔 낮은 값으로 잡는다. 부족분은 HPA replica가 채운다.
    sized = max(REQUEST_MIN_M, ceil_to(required / pods * REQUEST_HEADROOM))
    # 단, 파드당 실사용의 절반보다는 낮추지 않는다(과소예약 방지).
    sized = max(sized, ceil_to(int(app.per_pod_p90 or 0) * REQUEST_USAGE_FLOOR_RATIO))
    if app.cpu_limit_m:
        sized = min(sized, app.cpu_limit_m)
    if abs(sized - current["request"]) < REQUEST_UNIT_M:
        return None
    proposed = dict(current)
    proposed["request"] = sized
    if app.trigger_m > 0:
        proposed["target"] = int(clamp(round(app.trigger_m * 100.0 / sized), TARGET_MIN, TARGET_MAX))
    return proposed


def _idle_fit(snapshot: TuningSnapshot):
    """유휴 노드가 baseline를 넘으면, min replica 파드가 baseline 노드에 담기도록 request를 줄인다.

    AZ topology spread 때문에 각 AZ 노드 1대에는 앱마다 파드 1개가 앉는다. 그래서 그 노드에
    'Σ 앱 request'가 노드 가용 CPU를 넘으면 Karpenter 노드가 상주해 회수되지 않는다.
    노드 가용 CPU 안에 들어가도록 request를 실사용 하한까지 비례 축소한 묶음을 만든다.
    """
    baseline = snapshot.cluster.baseline_node_count
    if snapshot.idle_nodes() <= baseline:
        return None
    zones = max(1, snapshot.cluster.zone_count)
    per_zone_nodes = max(1, baseline // zones)  # AZ당 baseline 노드 수(보통 1)
    budget = snapshot.cluster.usable_cpu_per_node_m * per_zone_nodes
    knobs, floors = {}, {}
    total = 0
    for name, app in snapshot.apps.items():
        if not app.measured:
            return None
        cur = _current_dict(app)
        knobs[name] = cur
        # 각 앱의 request 하한 = 파드당 실사용(목표 부하 필요 CPU / 파드수)의 절반
        pods = max(1, int(app.pods_p90 or app.replicas or cur["min"]))
        need = snapshot.app_required_cpu_m(name) / pods if snapshot.app_required_cpu_m(name) else app.per_pod_p90
        floors[name] = max(REQUEST_MIN_M, ceil_to((need or REQUEST_MIN_M) * REQUEST_USAGE_FLOOR_RATIO))
        total += cur["request"]
    if total <= budget:
        return None
    # request 합을 budget 안으로: 하한 위 여유분을 비례 축소.
    floor_sum = sum(floors.values())
    if floor_sum > budget:
        return None  # 하한만으로도 안 들어가면 request로는 못 푼다(노드 타입 문제)
    slack = total - floor_sum
    room = budget - floor_sum
    scale = room / slack if slack > 0 else 0.0
    proposed = {}
    for name, cur in knobs.items():
        extra = cur["request"] - floors[name]
        req = floors[name] + int(extra * scale)
        req = max(floors[name], (req // REQUEST_UNIT_M) * REQUEST_UNIT_M)
        if req >= cur["request"]:
            continue
        p = dict(cur)
        p["request"] = req
        # 절대 발동점 보존: target 재계산
        if app_trigger := cur["request"] * cur["target"] / 100.0:
            p["target"] = int(clamp(round(app_trigger * 100.0 / req), TARGET_MIN, TARGET_MAX))
        proposed[name] = p
    return proposed or None


def _consolidated(snapshot, app: AppSnapshot, current: dict):
    """작은 파드 다수 → 제대로 사이징된 파드 소수.

    HPA 발동점(request × target)이 실사용보다 훨씬 낮으면 HPA는 항상 max에 붙어 탄력성이 없다
    (실측: user 100m × 25% = 25m 발동점에 32파드). 목표 부하 필요 CPU를 파드당 적정 크기로 나눠
    파드 수를 정하고, request/target/max를 그 균형점에 맞춘다.
    파드 수가 줄면 파드당 메모리 요청(예: 128Mi) 합계도 줄어 노드가 함께 줄어든다.
    """
    required = snapshot.app_required_cpu_m(app.name)
    if not required:
        return None
    pods_now = int(app.pods_p90 or app.replicas or current["min"] or 1)
    ceiling = app.cpu_limit_m or int(snapshot.cluster.usable_cpu_per_node_m * .5)
    per_pod = int(clamp(ceiling, REQUEST_MIN_M, max(REQUEST_MIN_M, snapshot.cluster.usable_cpu_per_node_m)))
    target_pods = max(int(current["min"]), int(math.ceil(required / max(per_pod, 1))))
    if target_pods >= pods_now:
        return None
    request = max(REQUEST_MIN_M, ceil_to(required / target_pods))
    if app.cpu_limit_m:
        request = min(request, app.cpu_limit_m)
    proposed = dict(current)
    proposed.update({
        "request": request,
        "target": int(clamp(round(required / (target_pods * request) * 100), TARGET_MIN, TARGET_MAX)),
        "max": max(current["min"], target_pods + max(1, int(math.ceil(target_pods * .5)))),
        "consolidate": True,
    })
    return proposed, pods_now, target_pods, required


def _safe_node_floor(snapshot: TuningSnapshot, current_nodes: int):
    """줄여도 되는 노드 수의 하한.

    실측 CPU 수요를 공급이 못 받치면(ρ>1) 대기열이 폭발해 게이트가 깨진다(실측: 4노드에서
    가용성 게이트 실패, 6~7노드는 정상). 그래서 수요 기준 노드 미만으로는 내리지 않는다.
    동시에 **하한을 채우려고 request를 올리지는 않는다.** 이미 현재 예약이 그보다 낮으면
    현재 노드 수를 그대로 하한으로 쓴다.
    """
    demand = snapshot.required_cluster_cpu_m()
    alloc = snapshot.cluster.node_alloc_m
    if demand <= 0 or alloc <= 0:
        return 1
    needed = int(math.ceil(demand / snapshot.cluster.usable_cpu_per_node_m))
    return max(1, min(current_nodes, needed))


def _optimal_request_target(snapshot: TuningSnapshot, app: AppSnapshot, current: dict,
                            node_floor=None):
    """실측값으로 공식 점수가 최대인 request/target 조합을 탐색한다.

    핵심 모델(실측 근거):
      - request는 Pod 속도 상한이 아니다. stress는 CPU 바운드이고 limit이 따로 있으므로
        request를 내려도 Pod 자체가 느려지지 않는다.
      - 노드 수는 Karpenter가 보는 request 예약량으로 결정된다.
        nodes = ceil((시스템 예약 + 앱별 request x 파드수) / 노드 allocatable)
      - 노드가 줄면 CPU 공급이 줄어 지연이 늘고 성능/가용성 점수가 떨어진다.
        그 저하를 실측 응답시간 분포로 계산해 비용 이득과 함께 공식 점수로 비교한다.
      - 예측이 안전 게이트(가용성 99%, 성능 30%)를 깨는 조합은 후보에서 제외한다.
    """
    if app.cpu_samples < 5 or snapshot.cluster.node_alloc_m <= 0:
        return None
    protected_replicas = max(
        _predicted_replicas(app, current),
        min(current["max"], int(app.pods_p90 or app.replicas or current["min"])),
    )
    upper = int(app.cpu_limit_m or max(current["request"], app.per_pod_p95 or 0) * 2) or current["request"]
    upper = min(current["request"], max(REQUEST_MIN_M, min(8000, upper)))
    # 실측 사용량 기준 하한: 파드당 실사용(동시 총 CPU p95 / 파드수)의 절반.
    # 이게 없으면 "1800m 쓰는 파드에 request 50m" 같은 비현실적인 값이 나온다.
    pods = max(1, int(app.pods_p90 or app.replicas or current["min"]))
    required = snapshot.app_required_cpu_m(app.name)
    usage_per_pod = required / pods if required else int(app.per_pod_p90 or 0)
    lower = max(REQUEST_MIN_M, ceil_to(usage_per_pod * REQUEST_USAGE_FLOOR_RATIO))
    # 한 회차에 절반 이하로 급락시키지 않는다. 더 내려야 하면 실측 후 다음 회차가 이어서 내린다.
    lower = max(lower, ceil_to(current["request"] * .5))
    lower = min(lower, upper)
    options = []
    for request_m in range(lower, upper + 1, REQUEST_UNIT_M):
        for target in range(TARGET_MIN, TARGET_MAX + 1):
            proposed = dict(current)
            proposed.update({"request": request_m, "target": target})
            replicas = _predicted_replicas(app, proposed)
            if replicas < protected_replicas:
                continue
            proposed["estimated_replicas"] = replicas
            nodes = _estimated_nodes(snapshot, app.name, proposed)
            if node_floor is not None and nodes < node_floor:
                continue
            predicted, slowdown = _predicted_score(
                snapshot, nodes, _estimated_node_average(snapshot, app.name, proposed))
            if slowdown > snapshot.max_slowdown:
                continue
            if not snapshot.acceptable(predicted):
                continue
            rank = (predicted.total, -nodes, -request_m, -abs(target - current["target"]))
            options.append((rank, proposed, nodes, predicted.total, slowdown,
                            protected_replicas))
    if not options:
        return None
    return max(options, key=lambda row: row[0])


def _commands(namespace, snapshot, knobs):
    """knobs: {앱: proposed}. 여러 앱을 한 회차에 적용할 수 있게 전부 만든다."""
    apply, rollback = [], []
    for name in sorted(knobs):
        app = snapshot.apps[name]
        proposed = knobs[name]
        current = _current_dict(app)
        deployment = app.deployment_name or name
        hpa = app.hpa_name or name
        safe_hpa = "".join(ch if ch.isalnum() or ch in "-_" else "-" for ch in hpa)

        def patch(values, suffix):
            body = {"spec": {"minReplicas": values["min"], "maxReplicas": values["max"],
                             "metrics": [{"type": "Resource", "resource": {"name": "cpu",
                             "target": {"type": "Utilization", "averageUtilization": values["target"]}}}]}}
            text = json.dumps(body, separators=(",", ":"))
            path = f'$env:TEMP\\hpa-{safe_hpa}-{suffix}.json'
            return [f"'{text}' | Set-Content -Path \"{path}\" -Encoding ascii",
                    f'kubectl -n {namespace} patch hpa {hpa} --type=merge --patch-file \"{path}\"']

        apply += patch(proposed, "apply")
        if proposed["request"] != current["request"]:
            apply += [f"kubectl -n {namespace} set resources deploy/{deployment} --requests=cpu={proposed['request']}m",
                      f"kubectl -n {namespace} rollout status deploy/{deployment} --timeout=120s"]
            rollback += [f"kubectl -n {namespace} set resources deploy/{deployment} --requests=cpu={current['request']}m",
                         f"kubectl -n {namespace} rollout status deploy/{deployment} --timeout=120s"]
        rollback += patch(current, "rollback")
    return apply, rollback


def _make_candidate(snapshot, app, kind, proposed, reason, priority, namespace="app",
                    knobs=None):
    lead = app.name if hasattr(app, "name") else app
    knobs = knobs or {lead: dict(proposed)}
    knobs = {name: dict(values) for name, values in knobs.items()}
    for name, values in knobs.items():
        values["estimated_replicas"] = _predicted_replicas(snapshot.apps[name], values)
    proposed = knobs[lead]
    current = _current_dict(snapshot.apps[lead])
    predicted_nodes = _estimated_nodes(snapshot, knobs)
    cpu_floor = snapshot.cluster.physical_cpu_floor
    result = snapshot.score()
    predicted_score, slowdown = _predicted_score(
        snapshot, predicted_nodes, _estimated_node_average(snapshot, knobs))
    supply_ratio = slowdown
    risk = "cpu-oversubscribed" if supply_ratio > 1.0 else ""
    if kind != "usage-sized" and supply_ratio > snapshot.max_slowdown:
        return None
    exempt = kind in ("gate-recovery", "usage-sized")
    if kind == "bundle":
        # 기준 미달 앱이 섞인 묶음은 한 회차로 못 끌어올리므로 예측만으로 버리지 않는다.
        exempt = any(
            snapshot.apps[name].performance < snapshot.perf_floor
            or snapshot.apps[name].availability < (snapshot.avail_floor if snapshot.cost_first
                                                   else snapshot.availability_gate)
            for name in knobs)
    if not snapshot.acceptable(predicted_score) and not exempt:
        return None
    # 유휴(min replicas) 상태에서 baseline 노드그룹을 넘기면 대회날 아무 부하가 없어도
    # Karpenter 노드가 상주해 비용 ratio가 올라간다. 이 조합은 제안하지 않는다.
    idle_before = snapshot.idle_nodes()
    idle_after = snapshot.idle_nodes(knobs)
    baseline_ng = snapshot.cluster.baseline_node_count
    if idle_after > max(baseline_ng, idle_before) and not exempt and kind != "idle-fit":
        return None
    delta = predicted_score.total - result.total
    if kind in ("gate-recovery", "performance-band"):
        delta = max(delta, priority)
    apply, rollback = _commands(namespace, snapshot, knobs)
    disruptive = any(values["request"] != _current_dict(snapshot.apps[name])["request"]
                     for name, values in knobs.items())
    if kind == "cost-reclaim" or (kind in ("request-optimal", "bundle")
                                  and any(values["request"] < _current_dict(snapshot.apps[name])["request"]
                                          for name, values in knobs.items())):
        settle_seconds = 105
    elif disruptive:
        settle_seconds = 60
    else:
        settle_seconds = 25
    return Candidate(
        app=lead, deployment_name=snapshot.apps[lead].deployment_name or lead,
        hpa_name=snapshot.apps[lead].hpa_name or lead, kind=kind, current=current,
        proposed=proposed, reason=reason,
        bottleneck=classify_bottleneck(snapshot.apps[lead], snapshot.cluster, snapshot.history),
        predicted_delta=round(delta, 2), predicted_total=round(result.total + delta, 2),
        predicted_nodes=predicted_nodes, observed_cpu_floor=cpu_floor,
        trigger_before=round(snapshot.apps[lead].trigger_m, 2),
        trigger_after=round(proposed["request"] * proposed["target"] / 100.0, 2),
        cpu_supply_ratio=supply_ratio, risk=risk,
        disruptive=disruptive, settle_seconds=settle_seconds,
        confidence="high" if snapshot.apps[lead].samples >= 100 and snapshot.apps[lead].cpu_samples >= 10 else "low",
        apply_commands=apply, rollback_commands=rollback, knobs=knobs,
    )


def generate_candidates(snapshot: TuningSnapshot, rejected=None, namespace="app",
                        rejected_nodes=None, hpa_only=False):
    rejected = set(rejected or ())
    # 실측으로 거절된 노드 수는 다시 시도하지 않는다(같은 회차 안에서 학습).
    min_nodes_allowed = (max(rejected_nodes) + 1) if rejected_nodes else 1
    candidates = []
    # 유휴 노드가 baseline를 넘으면(=대회날 부하 없이도 Karpenter 노드 상주) request를 줄여
    # min replica 파드가 baseline 노드에 담기게 하는 묶음을 최우선으로 낸다.
    idle_now = snapshot.idle_nodes()
    fit = _idle_fit(snapshot)
    if fit:
        lead = max(fit, key=lambda n: snapshot.apps[n].request_m or 0)
        idle_after = snapshot.idle_nodes(fit)
        detail = ", ".join(f"{n} {_current_dict(snapshot.apps[n])['request']}→{v['request']}m"
                           for n, v in sorted(fit.items()))
        c = _make_candidate(
            snapshot, snapshot.apps[lead], "idle-fit", fit[lead],
            f"유휴 노드 {idle_now}→{idle_after}대(baseline {snapshot.cluster.baseline_node_count}): "
            f"AZ당 노드 1대에 앱 min 파드가 담기도록 request 축소 — {detail}",
            2.0, namespace, knobs=fit)
        if c and c.key() not in rejected:
            candidates.append(c)
    # 게이트 미달은 '그 앱'의 문제다. 예전에는 한 앱이 미달이면 전체 후보 생성을 막아
    # 3회차가 그 앱에서 다 소모됐다. 이제 앱별로만 판단한다.
    for app in snapshot.apps.values():
        if not app.measured:
            continue
        current = _current_dict(app)
        bottleneck = classify_bottleneck(app, snapshot.cluster, snapshot.history)
        avail_floor = snapshot.avail_floor if snapshot.cost_first else snapshot.availability_gate
        if app.performance < snapshot.perf_floor or app.availability < avail_floor:
            proposed = dict(current)
            # 미달이 심할수록 target을 크게 내려 파드를 일찍/많이 확장한다(경합 완화 = 지연 감소).
            perf_gap = max(0.0, snapshot.perf_floor - app.performance)
            avail_gap = max(0.0, avail_floor - app.availability)
            gap = max(perf_gap, avail_gap)
            if gap >= 30:      # 14.8% vs 80% 같은 심한 미달
                proposed["target"] = TARGET_MIN
            elif gap >= 15:
                proposed["target"] = max(TARGET_MIN, current["target"] - 30)
            else:
                proposed["target"] = max(TARGET_MIN, current["target"] - 15)
            # 스케일아웃 여지를 넓히고, 초기부터 파드를 늘려 콜드스타트/경합을 줄인다.
            if app.max_replicas and app.pods_max >= app.max_replicas:
                proposed["max"] = current["max"] + max(2, int(math.ceil(current["max"] * .5)))
            if gap >= 15 and current["min"] < proposed.get("max", current["max"]):
                proposed["min"] = min(proposed.get("max", current["max"]), current["min"] + 1)
            c = _make_candidate(snapshot, app, "gate-recovery", proposed,
                                f"성능/가용성 게이트 복구(우선): perf {app.performance:.1f}%(>= {snapshot.perf_floor:.0f}), "
                                f"avail {app.availability:.1f}%(>= {avail_floor:.0f}) → "
                                f"target {current['target']}→{proposed['target']}%"
                                + (f", max {current['max']}→{proposed['max']}" if proposed.get('max',current['max'])!=current['max'] else "")
                                + (f", min {current['min']}→{proposed['min']}" if proposed.get('min',current['min'])!=current['min'] else ""),
                                6.0, namespace)
            if c and c.key() not in rejected:
                candidates.append(c)
            continue
        nxt, gap = rubric.next_band(app.performance)
        if 0 < gap <= 3.0 and current["target"] > TARGET_MIN:
            proposed = dict(current)
            proposed["target"] = max(TARGET_MIN, current["target"] - 10)
            c = _make_candidate(snapshot, app, "performance-band", proposed,
                                f"공식 {nxt:g}% 밴드까지 {gap:.2f}%p; HPA를 일찍 확장", .5, namespace)
            if c and c.key() not in rejected:
                candidates.append(c)
        # request/target 최적화: 실측 CPU와 replica를 보존하면서 물리 CPU 하한 이상인
        # 모든 25m request × 1% target 조합을 탐색하고 공식 점수가 최대인 값을 선택한다.
        current_probe = dict(current)
        current_probe["estimated_replicas"] = _predicted_replicas(app, current_probe)
        current_nodes = _estimated_nodes(snapshot, app.name, current_probe)
        node_floor = min_nodes_allowed if snapshot.cost_first else max(
            _safe_node_floor(snapshot, current_nodes), min_nodes_allowed)
        # (1) 실측 사용량에서 바로 역산한 값. 탐색 없이 한 회차로 확정한다.
        sized = _usage_sized(snapshot, app, current)
        if sized:
            lowers = sized["request"] < current["request"]
            gate_risk = (app.availability < snapshot.availability_gate
                         or app.performance < rubric.COST_PERF_GATE + 5.0)
            if not (lowers or gate_risk):
                sized = None
        if sized:
            usage_pct = 100.0 * (app.per_pod_p90 or 0) / max(current["request"], 1)
            direction = "과소예약" if sized["request"] > current["request"] else "과투자"
            c = _make_candidate(
                snapshot, app, "usage-sized", sized,
                f"실측 역산({direction}): 파드당 사용 p90 {app.per_pod_p90}m = request의 {usage_pct:.0f}%, "
                f"동시 총 CPU p95 {app.total_cpu_p95}m ÷ 파드 {app.pods_p90}개 → "
                f"request {current['request']}→{sized['request']}m, target {current['target']}→{sized['target']}%",
                1.0, namespace)
            if c and c.key() not in rejected:
                candidates.append(c)
        # (1b) 파드 수 정리: 작은 파드 다수를 적정 크기 소수로 바꾼다(메모리 예약까지 줄어든다).
        merged_pods = _consolidated(snapshot, app, current)
        if merged_pods:
            proposed, pods_now, target_pods, required = merged_pods
            mem_saved = int(app.memory_request_mi or 0) * (pods_now - target_pods)
            c = _make_candidate(
                snapshot, app, "pod-consolidate", proposed,
                f"파드 정리: 발동점 {app.trigger_m:.0f}m로 HPA가 항상 max({current['max']})에 붙어 "
                f"{pods_now}개가 떠 있다. 목표 부하 필요 CPU {required}m을 "
                f"{target_pods}개 파드로 → request {current['request']}→{proposed['request']}m, "
                f"target {current['target']}→{proposed['target']}%, max {current['max']}→{proposed['max']}"
                + (f", 메모리 예약 {mem_saved}Mi 절감" if mem_saved > 0 else ""),
                0.5, namespace)
            if c and c.key() not in rejected:
                candidates.append(c)
        # (2) 파드 수 상한. 노드는 'request x 파드수'로 늘어나므로 max_replicas도 비용 노브다.
        #     실측에서 상한까지 붙었고 성능 밴드에 여유가 있을 때만 제안한다.
        saturated = app.max_replicas and app.pods_max >= app.max_replicas
        band_margin = app.performance - rubric.band_floor(app.performance)
        if saturated and band_margin >= 5.0 and current["max"] > current["min"]:
            capped = dict(current)
            capped["max"] = max(current["min"], int(math.floor(current["max"] * .85)))
            if capped["max"] < current["max"]:
                c = _make_candidate(
                    snapshot, app, "pod-cap", capped,
                    f"파드 상한이 비용을 만든다: 실측 최대 {app.pods_max}개(상한 {current['max']}) x "
                    f"request {current['request']}m = 예약 {app.pods_max * current['request']}m; "
                    f"성능 {app.performance:.1f}%는 밴드 하한 위 {band_margin:.1f}%p 여유 → "
                    f"max {current['max']}→{capped['max']}",
                    0.0, namespace)
                if c and c.key() not in rejected:
                    candidates.append(c)
        optimal = _optimal_request_target(snapshot, app, current, node_floor)
        if optimal and (not sized or sized["request"] != optimal[1]["request"]):
            _, proposed, searched_nodes, searched_total, slowdown, protected_replicas = optimal
            changed = proposed["request"] != current["request"] or proposed["target"] != current["target"]
            if changed and searched_nodes <= current_nodes:
                warning = (f", CPU 공급 {slowdown:.2f}배 부족 예상(지연 증가 반영됨)"
                           if slowdown > 1.0 else "")
                reason = (f"실측 최적값: request {current['request']}→{proposed['request']}m, "
                          f"target {current['target']}→{proposed['target']}%, "
                          f"replica {protected_replicas}개 유지, "
                          f"예약 기준 노드 {current_nodes}→{searched_nodes}대"
                          f"(안전 하한 {node_floor}대), "
                          f"공식 예상 {searched_total:.1f}/36{warning}")
                c = _make_candidate(snapshot, app, "request-optimal", proposed,
                                    reason, 0.0, namespace)
                if c and c.key() not in rejected:
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
    kind_rank = {"gate-recovery": 5, "bundle": 5, "idle-fit": 5, "usage-sized": 4,
                 "pod-consolidate": 4, "performance-band": 3, "request-optimal": 2,
                 "pod-cap": 2, "cost-reclaim": 1}
    if hpa_only:
        # 부하 중에는 request를 바꾸지 않는다. request 변경은 rollout을 일으켜(적용+롤백 각각)
        # 회차 시간을 몇 분씩 잡아먹고, rollout 자체가 가용성을 깎는다. HPA(target/min/max)만
        # 만지는 후보는 즉시 적용/롤백된다. request 사이징은 부하 전 1회로 끝낸다.
        candidates = [c for c in candidates
                      if not any(v["request"] != _current_dict(snapshot.apps[n])["request"]
                                 for n, v in c.knobs.items())]
    # (A) 모든 앱 변경을 '한 번'에 묶는다. 반복 측정 루프 없이 1회 적용/1회 확인으로 끝내기 위해
    #     bundle을 항상 최상위로 둔다(멤버 delta 합). runner는 이 bundle 하나만 적용한다.
    per_app_best = {}
    for c in candidates:
        if c.kind in ("gate-recovery", "usage-sized", "pod-consolidate", "request-optimal",
                      "performance-band", "pod-cap", "cost-reclaim", "idle-fit"):
            prev = per_app_best.get(c.app)
            if prev is None or c.predicted_delta > prev.predicted_delta:
                per_app_best[c.app] = c
    if len(per_app_best) >= 1:
        merged = {}
        for c in per_app_best.values():
            merged.update(c.knobs)
        lead = max(per_app_best.values(), key=lambda c: c.predicted_delta)
        detail = ", ".join(
            f"{name} target {_current_dict(snapshot.apps[name])['target']}→{values['target']}%"
            + (f" request {_current_dict(snapshot.apps[name])['request']}→{values['request']}m"
               if values['request'] != _current_dict(snapshot.apps[name])['request'] else "")
            for name, values in sorted(merged.items()))
        bundle = _make_candidate(
            snapshot, snapshot.apps[lead.app], "bundle", merged[lead.app],
            f"앱 {len(merged)}개 한 번에 적용(반복 측정 없음): {detail}", 0.0, namespace, knobs=merged)
        if bundle and bundle.key() not in rejected:
            # 멤버 delta 합으로 최상위 보장
            bundle.predicted_delta = round(sum(c.predicted_delta for c in per_app_best.values()), 2)
            candidates.insert(0, bundle)
    candidates.sort(key=lambda c: (c.predicted_delta, -max(c.cpu_supply_ratio, 1.0),
                                   kind_rank.get(c.kind, 0),
                                   -int(c.disruptive), -c.predicted_nodes), reverse=True)
    # (B) 한 앱이 시험 3회를 독식하지 못하게 앱별 1개씩 우선 배치한다.
    ordered, seen_apps, spare = [], set(), []
    for c in candidates:
        target_apps = tuple(sorted(c.knobs))
        if c.kind == "bundle" or not seen_apps.intersection(target_apps):
            ordered.append(c)
            seen_apps.update(target_apps)
        else:
            spare.append(c)
    return ordered + spare


def plan(snapshot: TuningSnapshot, rejected=None, namespace="app", rejected_nodes=None,
         hpa_only=False):
    score = snapshot.score()
    candidates = generate_candidates(snapshot, rejected, namespace, rejected_nodes, hpa_only)
    fit = deterministic_reservation(snapshot)
    cost_locked = ""
    if fit:
        if fit["nodes"] >= snapshot.cluster.node_average:
            cost_locked = (f"실측 동시 CPU 수요 {fit['demand_m']}m ÷ 노드당 가용 "
                           f"{snapshot.cluster.usable_cpu_per_node_m}m = {fit['nodes']}대가 필요하고 "
                           f"관측 평균은 {snapshot.cluster.node_average:.1f}대다. "
                           f"request/파드수 조정으로 비용을 더 줄일 수 없다 — 수요를 줄이거나 성능을 내주는 선택만 남는다.")
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
            "pods_p90": app.pods_p90, "pods_max": app.pods_max,
            "peak_reservation_m": int((app.pods_max or 0) * (app.request_m or 0)),
            "cpu_bound_fraction": round(app.cpu_bound_fraction, 3),
            "measured_rps": round(app.measured_rps, 2),
            "cpu_per_request_ms": (round(app.cpu_seconds_per_request * 1000, 1)
                                   if app.cpu_seconds_per_request is not None else None),
            "target_rps": round(snapshot.app_target_rps(name), 2),
            "required_cpu_m": snapshot.app_required_cpu_m(name),
            "total_cpu_p90": app.total_cpu_p90, "bottleneck": classify_bottleneck(app, snapshot.cluster, snapshot.history),
        })
    if cost_locked:
        # 비용을 더 줄일 수 없으면 노드 감소를 노린 후보는 시험 자체가 시간 낭비다.
        candidates = [c for c in candidates
                      if c.kind in ("gate-recovery", "usage-sized") or c.predicted_delta > 0]
    # 트래픽 전 1회 적용할 request 사이징(rollout 동반). 유휴 노드가 baseline를 넘으면 idle-fit,
    # 아니면 실측 과소/과대 예약 교정(usage-sized). HPA-only 루프와 별개로 runner가 먼저 적용한다.
    presize = _idle_fit(snapshot)
    if not presize:
        presize = {}
        for name, app in snapshot.apps.items():
            if not app.measured:
                continue
            cur = _current_dict(app)
            sz = _usage_sized(snapshot, app, cur)
            if sz and sz["request"] != cur["request"]:
                presize[name] = sz
        presize = presize or None
    return {
        "schema_version": 1,
        "done": not candidates,
        "reason": ((cost_locked + " ") if cost_locked else "")
                  + ("개선 후보 없음 — 현재 측정에서 안전하게 공식 점수를 올릴 수 없음" if not candidates else ""),
        "score": score.to_dict(), "apps": apps,
        "cluster": asdict(snapshot.cluster),
        "idle_nodes": snapshot.idle_nodes(),
        "idle_nodes_after_presize": snapshot.idle_nodes(presize) if presize else snapshot.idle_nodes(),
        "baseline_node_count": snapshot.cluster.baseline_node_count,
        "reservation_fit": fit,
        "presize": presize,
        "cost_locked": cost_locked,
        "candidates": [c.to_dict() for c in candidates[:5]],
        "best": candidates[0].to_dict() if candidates else None,
    }
