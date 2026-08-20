import pathlib
import unittest
import sys

ROOT = pathlib.Path(__file__).parent
sys.path.insert(0, str(ROOT))

import rubric
import score
import tuning_engine as engine
import optimize


class OfficialRubricTests(unittest.TestCase):
    def test_every_rate_boundary(self):
        for index, threshold in enumerate(rubric.RATE_BANDS, 1):
            self.assertEqual(rubric.band_points(threshold - .001), .5 * (index - 1))
            self.assertEqual(rubric.band_points(threshold), .5 * index)

    def test_cost_floor_and_perf_gate(self):
        self.assertEqual(rubric.cost_points(.49, {"a": 90})[0], 0)
        points, note = rubric.cost_points(1.25, {"a": 29.99, "b": 90})
        self.assertEqual(points, 0)
        self.assertIn("a", note)
        self.assertEqual(rubric.cost_points(1.25, {"a": 30})[0], 11)

    def test_official_result_replays(self):
        first = rubric.score(
            {"user": 87.4, "product": 105.3, "stress": 79.9},
            {"user": 99.9, "product": 100, "stress": 99.5}, 4.2, 2)
        self.assertEqual(first.availability_points, 12)
        self.assertEqual(first.performance_points, 8.5)
        self.assertEqual(first.cost_points, 7)
        self.assertEqual(first.total + 4, 31.5)
        second = rubric.score(
            {"user": 83.9, "product": 101, "stress": 84.9},
            {"user": 100, "product": 100, "stress": 99.6}, 3.6, 2)
        self.assertEqual(second.performance_points, 9)
        self.assertEqual(second.cost_points, 8)
        self.assertEqual(second.total + 4, 33)

    def test_score_compatibility_wrappers(self):
        self.assertEqual(score.band_points(80), 2)
        self.assertEqual(score.next_band(80.9)[0], 82.5)
        self.assertEqual(score.cost_points(1.3, {"a": 30})[0], 10)


class SharedEngineTests(unittest.TestCase):
    def app(self, name="worker", **kw):
        values = dict(
            name=name, slo_seconds=.2, samples=1000, availability=100,
            performance=99, request_m=750, target=55, min_replicas=2,
            max_replicas=8, replicas=6, per_pod_p50=400, per_pod_p90=700,
            per_pod_p95=900, total_cpu_p90=2400, total_cpu_p95=2700,
            pods_p50=5, pods_p90=6, pods_max=6, cpu_samples=120,
        )
        values.update(kw)
        return engine.AppSnapshot(**values)

    def snapshot(self, app=None, **cluster):
        values = dict(baseline_nodes=2, node_average=4, node_count=4,
                      node_alloc_m=2000, node_cpu_p95=70,
                      cluster_cpu_p95_m=3000)
        values.update(cluster)
        app = app or self.app()
        return engine.TuningSnapshot({app.name: app}, engine.ClusterSnapshot(**values))

    def latencies(self, count=600, low=.10, high=2.80):
        step = (high - low) / (count - 1)
        return tuple(round(low + step * i, 4) for i in range(count))

    def test_request_optimum_lowers_reservation_and_never_inflates(self):
        app = self.app(latencies=self.latencies(low=.02, high=.30))
        candidates = engine.generate_candidates(self.snapshot(app))
        optimal = next(c for c in candidates if c.kind == "request-optimal")
        self.assertLess(optimal.proposed["request"], 750)
        self.assertGreaterEqual(optimal.proposed["estimated_replicas"], 6)
        self.assertLess(optimal.predicted_nodes, 4)
        for candidate in candidates:
            self.assertLessEqual(candidate.proposed["request"], 750)
            self.assertLessEqual(candidate.cpu_supply_ratio, engine.MAX_EXTRAPOLATED_SLOWDOWN)

    def test_untrusted_extrapolation_is_not_proposed(self):
        app = self.app(latencies=self.latencies(low=.02, high=.30))
        snapshot = self.snapshot(app, cluster_cpu_p95_m=7900, node_alloc_m=2000)
        for candidate in engine.generate_candidates(snapshot):
            self.assertLessEqual(candidate.cpu_supply_ratio, engine.MAX_EXTRAPOLATED_SLOWDOWN)
            self.assertGreaterEqual(candidate.predicted_nodes, 3)

    def test_gate_recovery_is_first_and_does_not_raise_request(self):
        app = self.app(performance=29, availability=100, request_m=300,
                       target=70, replicas=8, pods_max=8, max_replicas=8)
        candidate = engine.generate_candidates(self.snapshot(app))[0]
        self.assertEqual(candidate.kind, "gate-recovery")
        self.assertEqual(candidate.proposed["request"], 300)
        self.assertLess(candidate.proposed["target"], 70)
        self.assertGreater(candidate.proposed["max"], 8)

    def test_cpu_bound_fraction_is_measured_not_assumed(self):
        """앱이 바뀌어도 CPU 민감도를 매 측정에서 다시 구한다."""
        latencies = tuple(round(.30 + .60 * i / 99, 4) for i in range(100))
        # CPU 바운드: 요청당 CPU 0.54s / 평균 지연 0.60s
        cpu_bound = self.app(name="burn", slo_seconds=1.0, samples=100,
                             window_seconds=100.0, total_cpu_p90=540, latencies=latencies)
        self.assertAlmostEqual(cpu_bound.cpu_bound_fraction, .9, places=2)
        # DB 대기형: 요청당 CPU 0.06s / 평균 지연 0.60s
        db_bound = self.app(name="lookup", slo_seconds=1.0, samples=100,
                            window_seconds=100.0, total_cpu_p90=60, latencies=latencies)
        self.assertAlmostEqual(db_bound.cpu_bound_fraction, .1, places=2)
        # 같은 CPU 공급 부족(2배)에서 CPU 바운드 앱만 성능이 크게 깎인다.
        self.assertLess(cpu_bound.performance_at(2.0)[0], db_bound.performance_at(2.0)[0] - 20)
        self.assertEqual(db_bound.performance_at(1.0), cpu_bound.performance_at(1.0))
        # 측정이 없으면 보수적으로 CPU 바운드로 간주한다.
        self.assertEqual(self.app(window_seconds=0.0).cpu_bound_fraction, 1.0)

    def test_usage_sized_request_is_one_division_not_a_search(self):
        """500m 예약에 250m만 쓰면 250m로, 750m에 1800m 쓰면 올린다."""
        over = self.app(name="over", slo_seconds=1.0, samples=1000, window_seconds=120.0,
                        request_m=500, target=50, min_replicas=2, max_replicas=8,
                        replicas=4, pods_p90=4, pods_max=4, per_pod_p90=250,
                        per_pod_p95=250, total_cpu_p90=1000, total_cpu_p95=1000,
                        cpu_samples=60, latencies=tuple([.10] * 200))
        self.assertEqual(engine._usage_sized(over, engine._current_dict(over))["request"], 250)
        under = self.app(name="under", request_m=750, target=55, pods_p90=8,
                         per_pod_p90=1800, per_pod_p95=1956, total_cpu_p90=6600,
                         total_cpu_p95=7392, cpu_limit_m=2000)
        self.assertEqual(engine._usage_sized(under, engine._current_dict(under))["request"], 925)

    def test_cost_lock_is_detected_in_one_measurement(self):
        """수요가 이미 노드를 채우면 시험 없이 즉시 알린다."""
        app = self.app(name="svc", slo_seconds=1.0, samples=2000, window_seconds=120.0,
                       request_m=750, cpu_limit_m=2000, target=55, min_replicas=2,
                       max_replicas=8, replicas=8, pods_p90=8, pods_max=8,
                       per_pod_p90=1400, per_pod_p95=1450, total_cpu_p90=11000,
                       total_cpu_p95=11298, cpu_samples=60,
                       latencies=tuple([.40] * 400))
        snapshot = engine.TuningSnapshot(
            {"svc": app}, engine.ClusterSnapshot(baseline_nodes=2, node_average=7,
                                                 node_count=7, node_alloc_m=1930,
                                                 cluster_cpu_p95_m=11122,
                                                 system_reserved_m=900))
        fit = engine.deterministic_reservation(snapshot)
        self.assertEqual(fit["nodes"], 7)
        self.assertEqual(fit["knobs"]["svc"]["request"], 1600)
        result = engine.plan(snapshot)
        self.assertTrue(result["cost_locked"])
        self.assertIn("비용을 더 줄일 수 없다", result["reason"])
        for candidate in result["candidates"]:
            self.assertGreaterEqual(candidate["predicted_nodes"], 7)

    def test_latest_stress_measurement_lowers_request_within_safe_nodes(self):
        """2026-08-20 17:56 실측 재현.

        stress는 CPU 바운드(요청당 약 0.4 CPU-s, limit 2 CPU)이므로 request를 내려도
        Pod가 느려지지 않는다. 노드는 예약량으로 정해지므로 750m 예약은 과투자다.
        """
        # 실측 히스토그램(0.1s 버킷, 2288개 2xx)을 그대로 재구성한다.
        buckets = [(.15, 73), (.25, 243), (.35, 391), (.45, 385), (.55, 271),
                   (.65, 257), (.75, 186), (.85, 137), (.95, 95), (1.05, 61),
                   (1.15, 34), (1.25, 28)]
        measured = []
        for value, count in buckets:
            measured.extend([value] * count)
        measured.extend(round(1.35 + i * .01, 3) for i in range(127))
        measured = tuple(measured)
        stress = self.app(
            name="stress", slo_seconds=1.0, performance=90.026, availability=99.652,
            request_m=750, cpu_limit_m=2000, target=55, min_replicas=2,
            max_replicas=8, replicas=2, per_pod_p90=992, per_pod_p95=1003,
            total_cpu_p90=6940, total_cpu_p95=7000, pods_p90=8, pods_max=8,
            cpu_samples=61, latencies=measured, samples=2296, window_seconds=120.0,
        )
        user = self.app(
            name="user", performance=77.941, request_m=100, target=33,
            min_replicas=2, max_replicas=25, replicas=2, total_cpu_p90=3863,
            pods_p90=25, pods_max=25, latencies=tuple(round(.02 + .3 * i / 299, 4) for i in range(300)),
        )
        product = self.app(
            name="product", performance=99.454, request_m=50, target=60,
            min_replicas=2, max_replicas=20, replicas=2, total_cpu_p90=72,
            pods_p90=2, pods_max=2, latencies=tuple([.01] * 100),
        )
        snapshot = engine.TuningSnapshot(
            {"product": product, "stress": stress, "user": user},
            engine.ClusterSnapshot(baseline_nodes=2, node_average=7.222,
                                   node_count=8, node_alloc_m=1930,
                                   cluster_cpu_p95_m=10695, system_reserved_m=900),
        )
        result = engine.plan(snapshot)
        # 실측 수요(12400m+900m)는 7대분이고 관측 평균은 7.22대이므로 여유가 1대 미만이다.
        self.assertEqual(result["reservation_fit"]["nodes"], 7)
        for candidate in result["candidates"]:
            self.assertGreaterEqual(candidate["predicted_nodes"], 7)
        # 과소예약(750m에 파드당 992m 사용)은 나눗셈으로 바로 교정값이 나온다: 7000m ÷ 8파드.
        self.assertEqual(engine._usage_sized(stress, engine._current_dict(stress))["request"], 875)

    def test_measured_rejection_blocks_repeating_the_same_node_count(self):
        measured = tuple([.45] * 400)
        app = self.app(name="svc", slo_seconds=1.0, samples=1000, window_seconds=120.0,
                       request_m=750, cpu_limit_m=2000, target=55, min_replicas=2,
                       max_replicas=8, replicas=8, pods_p90=8, pods_max=8,
                       total_cpu_p90=4000, cpu_samples=60, latencies=measured)
        snapshot = engine.TuningSnapshot(
            {"svc": app}, engine.ClusterSnapshot(baseline_nodes=2, node_average=5,
                                                 node_count=5, node_alloc_m=1930,
                                                 cluster_cpu_p95_m=5000,
                                                 system_reserved_m=900))
        first = next(c for c in engine.generate_candidates(snapshot)
                     if c.kind == "request-optimal")
        again = [c for c in engine.generate_candidates(
            snapshot, rejected_nodes=[first.predicted_nodes])
            if c.kind == "request-optimal"]
        for candidate in again:
            self.assertGreater(candidate.predicted_nodes, first.predicted_nodes)

    def test_dynamic_app_names_and_no_hardcoded_min(self):
        app = self.app(name="checkout-v2", min_replicas=4, max_replicas=9,
                       replicas=4, pods_max=4)
        plan = engine.plan(self.snapshot(app))
        self.assertEqual(plan["apps"][0]["app"], "checkout-v2")
        for candidate in plan["candidates"]:
            self.assertEqual(candidate["proposed"]["min"], 4)

    def test_commands_include_exact_rollback(self):
        app = self.app(latencies=self.latencies(low=.02, high=.30))
        optimal = next(c for c in engine.generate_candidates(self.snapshot(app))
                       if c.kind == "request-optimal")
        self.assertTrue(any("requests=cpu=750m" in command for command in optimal.rollback_commands))
        self.assertTrue(any("patch hpa worker" in command for command in optimal.rollback_commands))
        self.assertTrue(optimal.disruptive)

    def test_dashboard_adapter_uses_arbitrary_apps(self):
        data = {
            "apps": [{"app": "api-x", "total": 1000, "ok_rate": 100,
                      "slo_rate": 90, "slo_ms": 250, "p95": 200, "cpu_req": "200m"}],
            "pods": [{"app": "api-x", "phase": "Running", "cpu": "100m"}],
            "nodes": [{"cpu_alloc": 1900, "cpu_pct": "40%", "type": "t3.medium"}],
            "hpa": [{"name": "api-x", "min": 3, "max": 9, "replicas": 3,
                     "tgt": "60%", "cur": "50%"}],
        }
        snapshot = engine.snapshot_from_dashboard(data, cpu_history={"api-x": ["100m"] * 20})
        self.assertIn("api-x", snapshot.apps)
        self.assertEqual(snapshot.apps["api-x"].min_replicas, 3)
        self.assertEqual(snapshot.apps["api-x"].cpu_samples, 20)

    def test_commands_use_exact_live_resource_names(self):
        app = self.app(name="checkout", deployment_name="checkout-api",
                       hpa_name="checkout-scaler",
                       latencies=self.latencies(low=.02, high=.30))
        optimal = next(c for c in engine.generate_candidates(self.snapshot(app))
                       if c.kind == "request-optimal")
        all_commands = optimal.apply_commands + optimal.rollback_commands
        self.assertTrue(any("patch hpa checkout-scaler" in command for command in all_commands))
        self.assertTrue(any("deploy/checkout-api" in command for command in all_commands))

    def test_cpu_not_root_classification(self):
        app = self.app(performance=80, request_m=500, per_pod_p90=100)
        self.assertEqual(engine.classify_bottleneck(app, self.snapshot(app).cluster), "cpu-not-root")


class OptimizerCompatibilityTests(unittest.TestCase):
    def test_plan_step_gate(self):
        knobs = {"api": {"request": 100, "target": 60, "min": 2, "max": 6}}
        summary = {"perfs": {"api": 20}, "availability": {"api": 100},
                   "cost_ratio": 1.5, "total": 0}
        result = optimize.plan_step(knobs, summary)
        self.assertFalse(result["done"])
        self.assertEqual(result["kind"], "gate-recovery")

    def test_plan_step_converges_when_max_score_and_ratio(self):
        knobs = {"api": {"request": 100, "target": 90, "min": 2, "max": 6}}
        summary = {"perfs": {"api": 100}, "availability": {"api": 100},
                   "cost_ratio": 1.0, "total": 20}
        self.assertTrue(optimize.plan_step(knobs, summary)["done"])


class PowerShellRunnerContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.script = (ROOT / "optimize.ps1").read_text(encoding="utf-8-sig")

    def test_default_search_budget_and_hard_candidate_cap(self):
        self.assertIn("[int]$BudgetMinutes = 18", self.script)
        self.assertIn("[string]$Duration = '120s'", self.script)
        self.assertIn("[int]$WarmupSeconds = 60", self.script)
        self.assertIn("$candidateLimit=[Math]::Min([Math]::Max($Iterations,0),3)", self.script)
        self.assertIn("for($i=1;$i -le $candidateLimit;$i++)", self.script)
        self.assertIn("$safetyImproved -or ($gate -and $score.total -gt $bestScore.total)", self.script)
        self.assertIn("안전 게이트 미복구", self.script)
        self.assertIn("$durationSec=ConvertTo-DurationSeconds $Duration", self.script)
        self.assertIn("$settle*2+$durationSec+150", self.script)

    def test_plans_from_accepted_snapshot_and_settles_after_rollback(self):
        self.assertIn("Save-Snapshot $out $bestOut", self.script)
        self.assertIn("$step=Get-NextStep $bestOut $rejFile", self.script)
        self.assertIn("nodes=[int]$candidate.predicted_nodes", self.script)
        self.assertNotIn("CPU하한", self.script)

    def test_transactional_rollback_and_no_terraform_mutation(self):
        self.assertIn("finally {", self.script)
        self.assertIn("Set-Tuning $pending $bestKnobs.$pending", self.script)
        self.assertIn("Set-Tuning $app $bestKnobs.$app", self.script)
        self.assertNotIn("& terraform", self.script.lower())



if __name__ == "__main__":
    unittest.main()
