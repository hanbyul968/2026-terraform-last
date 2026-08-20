import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).parent


def load_module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


score = load_module("score")
advise = load_module("advise")
optimize = load_module("optimize")


class ScoreTests(unittest.TestCase):
    def test_official_rate_bands(self):
        self.assertEqual(score.band_points(29.999), 0.0)
        self.assertEqual(score.band_points(30.0), 0.5)
        self.assertEqual(score.band_points(80.0), 2.0)
        self.assertEqual(score.band_points(90.0), 4.0)

    def test_cost_is_zero_below_performance_gate(self):
        points, note = score.cost_points(1.30, {"user": 29.99, "product": 90, "stress": 90})
        self.assertEqual(points, 0.0)
        self.assertIn("user", note)

    def test_cost_ratio_1_30_is_ten_points_when_gate_passes(self):
        points, note = score.cost_points(1.30, {"user": 30, "product": 30, "stress": 30})
        self.assertEqual(points, 10.0)
        self.assertEqual(note, "")

    def test_next_band(self):
        self.assertEqual(score.next_band(28.0), (30.0, 2.0))
        self.assertEqual(score.next_band(80.9), (82.5, 1.5999999999999943))
        self.assertEqual(score.next_band(90.0), (90.0, 0.0))


class RecommendationTests(unittest.TestCase):
    def test_gate_failure_with_saturated_node_changes_request_and_hpa(self):
        measurement = {"performance": 28.0, "availability": 100.0}
        # pods_max/pods_p90: 활성 부하창에서 실제로 현재 max(13)에 도달했음을 나타낸다.
        # recommendation()의 max 증가는 이 hit_max 신호가 있을 때만 발동한다.
        cpu = {"per_pod_p90": 376, "total_p90": 2170, "pods_p50": 6, "pods_p90": 13, "pods_max": 13}
        current = {"request": 150, "target": 70, "min": 2, "max": 13}
        result = advise.recommendation(measurement, cpu, current, 103)
        self.assertEqual(result["request"], 200)
        self.assertEqual(result["target"], 47)
        self.assertEqual(result["min"], 2)
        self.assertEqual(result["max"], 17)
        self.assertGreater(result["needed"], current["max"])

    def test_fast_healthy_app_does_not_expand(self):
        measurement = {"performance": 99.4, "availability": 100.0}
        cpu = {"per_pod_p90": 32, "total_p90": 53, "pods_p50": 2}
        current = {"request": 50, "target": 70, "min": 2, "max": 6}
        result = advise.recommendation(measurement, cpu, current, 103)
        self.assertEqual(result["request"], 50)
        self.assertEqual(result["target"], 70)
        self.assertEqual(result["min"], 2)
        self.assertEqual(result["max"], 6)

    def test_missing_cpu_keeps_values(self):
        current = {"request": 300, "target": 70, "min": 2, "max": 6}
        result = advise.recommendation({"performance": 20, "availability": 90}, None, current, 100)
        self.assertEqual((result["request"], result["target"], result["min"], result["max"]),
                         (300, 70, 2, 6))

    def test_cost_reclaim_raises_target_when_nodes_excess_and_perf_safe(self):
        # 성능 최상위(99%)·파드 저활용·노드 초과(ratio 1.5) -> target을 올려 비용 회수
        measurement = {"performance": 99.0, "availability": 100.0}
        cpu = {"per_pod_p90": 20, "total_p90": 60, "pods_p50": 2, "pods_p90": 2, "pods_max": 2}
        current = {"request": 70, "target": 30, "min": 2, "max": 20}
        result = advise.recommendation(measurement, cpu, current, 50, ratio=1.5)
        self.assertEqual(result["target"], 52)  # 42(성능기준) + 10(비용회수)

    def test_no_cost_reclaim_without_ratio(self):
        # ratio 미전달(단일 회차 정보 없음)이면 회수하지 않는다 -> 기존 단방향 동작 보존
        measurement = {"performance": 99.0, "availability": 100.0}
        cpu = {"per_pod_p90": 20, "total_p90": 60, "pods_p50": 2, "pods_p90": 2, "pods_max": 2}
        current = {"request": 70, "target": 30, "min": 2, "max": 20}
        result = advise.recommendation(measurement, cpu, current, 50)
        self.assertEqual(result["target"], 42)

    def test_no_cost_reclaim_when_ratio_at_or_below_one(self):
        measurement = {"performance": 99.0, "availability": 100.0}
        cpu = {"per_pod_p90": 20, "total_p90": 60, "pods_p50": 2, "pods_p90": 2, "pods_max": 2}
        current = {"request": 70, "target": 30, "min": 2, "max": 20}
        result = advise.recommendation(measurement, cpu, current, 50, ratio=1.0)
        self.assertEqual(result["target"], 42)


class OptimizerTests(unittest.TestCase):
    def _summary(self, perfs, avails, ratio):
        return {"perfs": perfs, "availability": avails, "cost_ratio": ratio, "total": 0.0}

    def test_emergency_takes_priority(self):
        knobs = {"user": {"target": 60, "min": 2, "max": 6},
                 "product": {"target": 60, "min": 2, "max": 6}}
        summary = self._summary({"user": 25.0, "product": 100.0},
                                {"user": 100.0, "product": 100.0}, 1.5)
        step = optimize.plan_step(knobs, summary, avail_gate=99.0)
        self.assertFalse(step["done"])
        self.assertEqual(step["kind"], "emergency")
        self.assertEqual(step["app"], "user")
        self.assertLess(step["knob"]["target"], 60)

    def test_perf_up_near_band_edge(self):
        knobs = {"user": {"target": 40, "min": 2, "max": 20}}
        summary = self._summary({"user": 86.0}, {"user": 100.0}, 1.0)  # 87.5까지 1.5%p
        step = optimize.plan_step(knobs, summary, avail_gate=99.0)
        self.assertEqual(step["kind"], "perf-up")
        self.assertEqual(step["knob"]["target"], 30)

    def test_cost_reclaim_when_margin_and_ratio(self):
        knobs = {"product": {"target": 40, "min": 2, "max": 20}}
        summary = self._summary({"product": 100.0}, {"product": 100.0}, 1.5)
        step = optimize.plan_step(knobs, summary, avail_gate=99.0)
        self.assertEqual(step["kind"], "cost-reclaim")
        self.assertEqual(step["knob"]["target"], 50)

    def test_perf_up_beats_cost_reclaim(self):
        # 확실한 성능 경계(+0.5)를 비용 회수보다 먼저 확정한다
        knobs = {"user": {"target": 40, "min": 2, "max": 20},
                 "product": {"target": 40, "min": 2, "max": 20}}
        summary = self._summary({"user": 86.0, "product": 100.0},
                                {"user": 100.0, "product": 100.0}, 1.5)
        step = optimize.plan_step(knobs, summary, avail_gate=99.0)
        self.assertEqual(step["kind"], "perf-up")
        self.assertEqual(step["app"], "user")

    def test_converged_when_nothing_to_do(self):
        knobs = {"user": {"target": 60, "min": 2, "max": 6}}
        summary = self._summary({"user": 100.0}, {"user": 100.0}, 1.0)
        step = optimize.plan_step(knobs, summary, avail_gate=99.0)
        self.assertTrue(step["done"])

    def test_rejected_move_is_not_reproposed(self):
        knobs = {"product": {"target": 40, "min": 2, "max": 20}}
        summary = self._summary({"product": 100.0}, {"product": 100.0}, 1.5)
        rejected = [{"app": "product", "kind": "cost-reclaim"}]
        step = optimize.plan_step(knobs, summary, rejected, avail_gate=99.0)
        self.assertTrue(step["done"])


if __name__ == "__main__":
    unittest.main()
