import csv
import os
import tempfile
import unittest

import advise


class TuningMathTests(unittest.TestCase):
    def test_right_size_uses_dynamic_hpa_target_and_rounds_up(self):
        self.assertEqual(advise.right_size(70, 70), 100)
        self.assertEqual(advise.right_size(71, 70), 125)
        self.assertEqual(advise.right_size(50, 50), 100)
        self.assertEqual(advise.right_size(10, 80), 50)  # scheduler granularity floor

    def test_active_window_excludes_large_amount_of_idle_data(self):
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "loadwindows.csv"), "w", newline="", encoding="utf-8") as f:
                w = csv.writer(f)
                w.writerow(["name", "start_epoch", "active_end_epoch"])
                w.writerow(["alpha", 100, 104])
                w.writerow(["checkout-api-v2", 200, 204])
            with open(os.path.join(d, "podcpu.csv"), "w", newline="", encoding="utf-8") as f:
                w = csv.writer(f)
                # 유휴 표본이 수백 개여도 활성 창 밖이면 request 계산에 들어가면 안 된다.
                for ts in list(range(1, 100)) + list(range(105, 180)):
                    w.writerow([ts, "alpha-hash-pod1", 1])
                    w.writerow([ts, "alpha-hash-pod2", 1])
                for i, ts in enumerate(range(100, 105)):
                    w.writerow([ts, "alpha-hash-pod1", 100 + i * 10])
                    w.writerow([ts, "alpha-hash-pod2", 200 + i * 10])
                for i, ts in enumerate(range(200, 205)):
                    w.writerow([ts, "checkout-api-v2-hash-p1", 40 + i])
                    w.writerow([ts, "checkout-api-v2-hash-p2", 60 + i])
                    w.writerow([ts, "checkout-api-v2-hash-p3", 80 + i])

            got = advise.usage_from_window(d, {"alpha", "checkout-api-v2"})
            self.assertEqual(got["alpha"]["ticks"], 5)
            self.assertEqual(got["alpha"]["n"], 10)
            self.assertEqual(got["alpha"]["p90"], 180)       # per-tick pod average
            self.assertEqual(got["alpha"]["total_p90"], 360) # aggregate demand
            self.assertEqual(got["alpha"]["replicas_p50"], 2)
            self.assertTrue(got["alpha"]["windowed"])
            self.assertEqual(got["checkout-api-v2"]["replicas_p50"], 3)

    def test_load_plan_supports_arbitrary_app_names_and_values(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "loadplan.csv")
            with open(path, "w", newline="", encoding="utf-8") as f:
                w = csv.writer(f)
                w.writerow(["name", "duration_seconds", "concurrency", "qps_per_worker",
                            "expected_qps", "expected_requests", "jobs"])
                w.writerow(["future-app", 90, 17, 3, 51, 4590, 11])
            got = advise.load_plans(d)["future-app"]
            self.assertEqual(got["expected_qps"], 51)
            self.assertEqual(got["expected_requests"], 4590)
            self.assertEqual(got["jobs"], 11)

    def test_shared_budget_is_independent_of_app_count_and_names(self):
        reqs = {"a": 100, "b-service": 250, "new-app-v3": 75, "worker": 400}
        usage = {"a": 300, "b-service": 500, "new-app-v3": 100, "worker": 700}
        caps = advise.max_pods_in_budget(4, 1930, 900, reqs, usage)
        self.assertEqual(set(caps), set(reqs))
        self.assertLessEqual(sum(caps[k] * reqs[k] for k in caps), 4 * 1930 - 900)


if __name__ == "__main__":
    unittest.main()
