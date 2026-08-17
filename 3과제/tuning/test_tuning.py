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
        cpu = {"per_pod_p90": 376, "total_p90": 2170, "pods_p50": 6}
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


if __name__ == "__main__":
    unittest.main()
