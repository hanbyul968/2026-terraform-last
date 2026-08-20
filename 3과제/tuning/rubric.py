#!/usr/bin/env python3
"""2026 전국대회 3과제 공식 채점식의 단일 소스.

가용성/성능 24점과 비용 12점만 계산한다. 비정상 요청 4점은 verify.ps1 영역이다.
대시보드·score.py·advise.py·optimize.py가 이 모듈을 공용한다.
"""
from dataclasses import asdict, dataclass
from typing import Dict, Iterable, List, Optional, Tuple

RATE_BANDS = (30.0, 50.0, 70.0, 80.0, 82.5, 85.0, 87.5, 90.0)
COST_LIMITS = (1.00, 1.25, 1.50, 1.75, 2.00, 2.25,
               2.50, 2.75, 3.00, 3.25, 3.50, 3.75)
COST_RATIO_FLOOR = 0.50
COST_PERF_GATE = 30.0
DEFAULT_AVAILABILITY_GATE = 99.0


@dataclass(frozen=True)
class AppScore:
    app: str
    availability: float
    availability_points: float
    performance: float
    performance_points: float
    current_band: float
    next_band: float
    next_gap: float


@dataclass(frozen=True)
class RubricScore:
    availability_points: float
    performance_points: float
    cost_points: float
    total: float
    cost_ratio: float
    perf_gate_pass: bool
    avail_gate_pass: bool
    min_performance: float
    min_availability: float
    cost_note: str
    apps: Tuple[AppScore, ...]

    def to_dict(self) -> dict:
        data = asdict(self)
        data["apps"] = [asdict(item) for item in self.apps]
        return data


def band_points(value: float) -> float:
    return 0.5 * sum(1 for threshold in RATE_BANDS if value >= threshold)


def band_floor(value: float) -> float:
    passed = [threshold for threshold in RATE_BANDS if value >= threshold]
    return max(passed) if passed else 0.0


def next_band(value: float) -> Tuple[float, float]:
    for threshold in RATE_BANDS:
        if value < threshold:
            return threshold, threshold - value
    return RATE_BANDS[-1], 0.0


def cost_points(ratio: float, performances: Dict[str, float]) -> Tuple[float, str]:
    if ratio < COST_RATIO_FLOOR:
        return 0.0, "ratio %.2f < %.2f (하한 미달)" % (ratio, COST_RATIO_FLOOR)
    failed = sorted(app for app, value in performances.items() if value < COST_PERF_GATE)
    if failed:
        return 0.0, "성능 30%% 미달: %s -> 비용 전체 0점" % ", ".join(failed)
    return float(sum(1 for limit in COST_LIMITS if ratio <= limit)), ""


def score(performances: Dict[str, float], availabilities: Dict[str, float],
          node_average: float, baseline_nodes: float = 2.0,
          availability_gate: float = DEFAULT_AVAILABILITY_GATE) -> RubricScore:
    names = sorted(set(performances) | set(availabilities))
    rows: List[AppScore] = []
    for app in names:
        perf = float(performances.get(app, 0.0))
        avail = float(availabilities.get(app, 0.0))
        nxt, gap = next_band(perf)
        rows.append(AppScore(
            app=app,
            availability=avail,
            availability_points=band_points(avail),
            performance=perf,
            performance_points=band_points(perf),
            current_band=band_floor(perf),
            next_band=nxt,
            next_gap=gap,
        ))
    ratio = node_average / baseline_nodes if baseline_nodes else 0.0
    cp, note = cost_points(ratio, performances)
    ap = sum(row.availability_points for row in rows)
    pp = sum(row.performance_points for row in rows)
    min_perf = min(performances.values()) if performances else 0.0
    min_avail = min(availabilities.values()) if availabilities else 0.0
    return RubricScore(
        availability_points=ap,
        performance_points=pp,
        cost_points=cp,
        total=ap + pp + cp,
        cost_ratio=ratio,
        perf_gate_pass=bool(performances) and min_perf >= COST_PERF_GATE,
        avail_gate_pass=bool(availabilities) and min_avail >= availability_gate,
        min_performance=min_perf,
        min_availability=min_avail,
        cost_note=note,
        apps=tuple(rows),
    )


def legacy_rows(result: RubricScore):
    return [(row.app, row.availability, row.availability_points,
             row.performance, row.performance_points) for row in result.apps]
