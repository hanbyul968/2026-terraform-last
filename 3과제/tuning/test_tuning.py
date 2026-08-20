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

    def latencies(self, count=600, low=.02, high=.10):
        step = (high - low) / (count - 1)
        return tuple(round(low + step * i, 4) for i in range(count))

    def test_pod_count_and_memory_drive_nodes(self):
        """작은 파드 다수는 CPU 예약뿐 아니라 파드당 메모리 요청으로도 노드를 만든다."""
        app = self.app(name="user", slo_seconds=.2, samples=20000, window_seconds=120.0,
                       availability=100, performance=95, request_m=100, memory_request_mi=128,
                       target=25, min_replicas=2, max_replicas=32, replicas=32,
                       pods_p90=32, pods_max=32, per_pod_p90=61, per_pod_p95=90,
                       total_cpu_p90=1950, total_cpu_p95=2000, cpu_samples=60,
                       latencies=tuple([.05] * 300))
        snapshot = engine.TuningSnapshot(
            {"user": app}, engine.ClusterSnapshot(baseline_nodes=2, node_average=6, node_count=6,
                                                  node_alloc_m=1930, node_mem_alloc_mi=3292,
                                                  cluster_cpu_p95_m=2000, system_reserved_m=1400))
        # 32파드 x 128Mi = 4096Mi -> 메모리만으로 2노드가 필요하다(CPU 예약 3200m은 2노드분).
        self.assertEqual(engine._reservation_nodes(snapshot, "", {}), 2)
        merged = engine._consolidated(snapshot, app, engine._current_dict(app))
        self.assertIsNotNone(merged)
        proposed, pods_now, target_pods, required = merged
        self.assertEqual(pods_now, 32)
        self.assertLess(target_pods, 32)
        self.assertGreater(proposed["request"], 100)
        self.assertLess(proposed["max"], 32)
        # 파드가 줄면 메모리 예약도 줄어 노드 압력이 낮아진다.
        proposed["estimated_replicas"] = engine._predicted_replicas(app, proposed)
        after_mem = target_pods * app.memory_request_mi
        self.assertLess(after_mem, 32 * app.memory_request_mi)

    def test_request_optimum_lowers_reservation_and_never_inflates(self):
        app = self.app(latencies=self.latencies())
        candidates = engine.generate_candidates(self.snapshot(app))
        optimal = next(c for c in candidates if c.kind == "request-optimal")
        self.assertLess(optimal.proposed["request"], 750)
        self.assertGreaterEqual(optimal.proposed["estimated_replicas"], 6)
        self.assertLess(optimal.predicted_nodes, 4)
        for candidate in candidates:
            if candidate.kind == "pod-consolidate":
                # 파드 정리는 파드 수를 줄이면서 파드당 request를 올리는 후보다.
                self.assertLess(candidate.proposed["max"], 8)
                continue
            self.assertLessEqual(candidate.proposed["request"], 750)
            self.assertLessEqual(candidate.cpu_supply_ratio, engine.COST_FIRST_MAX_SLOWDOWN)

    def test_untrusted_extrapolation_is_not_proposed(self):
        app = self.app(latencies=self.latencies())
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

    def test_request_never_drops_far_below_measured_usage(self):
        """1800m 쓰는 파드에 50m 같은 값이 나오면 안 된다."""
        app = self.app(name="burn", slo_seconds=1.0, samples=2000, window_seconds=120.0,
                       availability=100, performance=95, request_m=750, cpu_limit_m=2000,
                       target=55, min_replicas=2, max_replicas=8, replicas=8,
                       pods_p90=8, pods_max=8, per_pod_p90=1800, per_pod_p95=1956,
                       total_cpu_p90=14000, total_cpu_p95=14400, cpu_samples=60,
                       latencies=tuple([.30] * 300))
        snapshot = engine.TuningSnapshot(
            {"burn": app}, engine.ClusterSnapshot(baseline_nodes=2, node_average=8,
                                                  node_count=8, node_alloc_m=1930,
                                                  cluster_cpu_p95_m=13000,
                                                  system_reserved_m=1600))
        for candidate in engine.generate_candidates(snapshot):
            for name, values in candidate.knobs.items():
                # 파드당 실사용 1800m의 절반(900m) 미만은 제안하지 않는다.
                self.assertGreaterEqual(values["request"], 900)
                # 한 회차에 현재값의 절반 아래로 떨어지지 않는다.
                self.assertGreaterEqual(values["request"], 375)

    def test_cost_first_floors_follow_official_bands(self):
        self.assertEqual(engine.COST_FIRST_AVAIL_FLOOR, 90.0)
        self.assertEqual(engine.COST_FIRST_PERF_FLOOR, 80.0)
        snapshot = self.snapshot(self.app(latencies=self.latencies()))
        self.assertTrue(snapshot.cost_first)
        self.assertEqual(snapshot.avail_floor, 90.0)
        self.assertEqual(snapshot.perf_floor, 80.0)

    def test_bundle_applies_all_apps_in_one_trial(self):
        """회차당 4~5분이므로 앱별로 나누면 한 앱이 예산을 다 쓴다. 한 회차에 묶는다."""
        def app(name, cpu_total, request_m, pods):
            return self.app(name=name, slo_seconds=1.0, samples=1000, window_seconds=120.0,
                            availability=100, performance=95, request_m=request_m,
                            cpu_limit_m=2000, target=55, min_replicas=2, max_replicas=pods,
                            replicas=pods, pods_p90=pods, pods_max=pods, cpu_samples=60,
                            total_cpu_p90=cpu_total, total_cpu_p95=cpu_total,
                            latencies=tuple([.20] * 200))
        snapshot = engine.TuningSnapshot(
            {"a": app("a", 1200, 600, 4), "b": app("b", 900, 500, 4)},
            engine.ClusterSnapshot(baseline_nodes=2, node_average=5, node_count=5,
                                   node_alloc_m=1930, cluster_cpu_p95_m=2100,
                                   system_reserved_m=1000))
        candidates = engine.generate_candidates(snapshot)
        bundle = next(c for c in candidates if c.kind == "bundle")
        self.assertEqual(candidates[0].kind, "bundle")
        self.assertEqual(set(bundle.knobs), {"a", "b"})
        # 두 앱의 적용/롤백 명령이 모두 들어 있다.
        joined = " ".join(bundle.apply_commands + bundle.rollback_commands)
        self.assertIn("patch hpa a", joined)
        self.assertIn("patch hpa b", joined)
        # 한 앱이 상위 후보를 독식하지 않는다.
        top_apps = [tuple(sorted(c.knobs)) for c in candidates[:3]]
        self.assertGreater(len({a for group in top_apps for a in group}), 1)

    def test_usage_sized_request_follows_target_load_not_measurement_load(self):
        """부하를 세게 넣고 측정했다고 request가 과대해지면 안 된다."""
        over = self.app(name="over", slo_seconds=1.0, samples=1200, window_seconds=120.0,
                        request_m=500, target=50, min_replicas=2, max_replicas=8,
                        replicas=4, pods_p90=4, pods_max=4, per_pod_p90=250,
                        per_pod_p95=250, total_cpu_p90=1000, total_cpu_p95=1000,
                        cpu_samples=60, latencies=tuple([.10] * 200))
        snapshot = engine.TuningSnapshot(
            {"over": over}, engine.ClusterSnapshot(baseline_nodes=2, node_average=4,
                                                   node_count=4, node_alloc_m=1930,
                                                   cluster_cpu_p95_m=1000,
                                                   system_reserved_m=800))
        current = engine._current_dict(over)
        # 측정 부하(10 rps) 기준: 요청당 CPU 100ms x 10rps = 1000m / 4파드 = 250m
        self.assertAlmostEqual(over.cpu_seconds_per_request, .1, places=3)
        self.assertEqual(engine._usage_sized(snapshot, over, current)["request"], 250)
        # 목표 부하를 절반으로 두면 request도 절반이 된다.
        snapshot.load_scale = .5
        self.assertEqual(engine._usage_sized(snapshot, over, current)["request"], 125)
        # 목표 rps를 직접 지정하면 측정 부하와 무관하게 그 값으로 사이징한다.
        # 20 rps면 필요 CPU 2000m / 4파드 = 500m = 현재값이므로 변경 제안이 없다.
        snapshot.load_scale = 1.0
        snapshot.target_rps = {"over": 20.0}
        self.assertIsNone(engine._usage_sized(snapshot, over, current))
        snapshot.target_rps = {"over": 40.0}
        self.assertEqual(engine._usage_sized(snapshot, over, current)["request"], 1000)

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
        # 균형 모드: 실측 수요보다 적은 노드는 제안하지 않는다.
        snapshot.cost_first = False
        balanced = engine.plan(snapshot)
        for candidate in balanced["candidates"]:
            self.assertGreaterEqual(candidate["predicted_nodes"], 7)
        # 비용 우선 모드: 공식 밴드 기준(가용성 92%, 성능 35%)만 지키고 노드를 더 줄인다.
        snapshot.cost_first = True
        cost = engine.plan(snapshot)
        self.assertTrue(cost["cost_locked"])
        for candidate in cost["candidates"]:
            self.assertLessEqual(candidate["cpu_supply_ratio"], engine.COST_FIRST_MAX_SLOWDOWN)

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
        # 성능 유지선 80%: stress는 p90이 이미 SLO(1.0s) 경계라 request를 깎을 여지가 없다.
        cost = engine.plan(snapshot)
        for candidate in cost["candidates"]:
            for name, values in candidate["knobs"].items():
                current = snapshot.apps[name].request_m
                self.assertGreaterEqual(values["request"], current * .5)
        self.assertFalse([c for c in cost["candidates"]
                          if c["app"] == "stress" and c["kind"] == "request-optimal"])
        # 균형 모드: 실측 수요를 밑도는 노드는 제안하지 않는다.
        snapshot.cost_first = False
        for candidate in engine.plan(snapshot)["candidates"]:
            self.assertGreaterEqual(candidate["predicted_nodes"], 6)
        # 과소예약 교정값도 목표 부하 기준으로 계산된다(요청당 CPU x 목표 rps ÷ 파드수).
        sized = engine._usage_sized(snapshot, stress, engine._current_dict(stress))
        self.assertEqual(sized["request"], engine.ceil_to(
            snapshot.app_required_cpu_m("stress") / stress.pods_p90))

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
        app = self.app(latencies=self.latencies())
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
                       latencies=self.latencies())
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
        self.assertIn("안전선 미달", self.script)
        self.assertIn("$durationSec=ConvertTo-DurationSeconds $Duration", self.script)
        self.assertIn("$settle*2+$durationSec+150", self.script)

    def test_accepts_on_official_band_floors_not_a_stricter_gate(self):
        self.assertIn("[ValidateSet('cost','balanced')][string]$Objective = 'cost'", self.script)
        self.assertIn("[double]$AvailFloor = 90", self.script)
        self.assertIn("[double]$PerfFloor = 80", self.script)
        self.assertIn("($score.min_avail -ge $availFloor) -and ($score.min_perf -ge $perfFloor)",
                      self.script)
        self.assertNotIn("$score.perf_gate_pass -and $score.avail_gate_pass", self.script)

    def test_plans_from_accepted_snapshot_and_settles_after_rollback(self):
        self.assertIn("Save-Snapshot $out $bestOut", self.script)
        self.assertIn("$step=Get-NextStep $bestOut $rejFile", self.script)
        self.assertIn("nodes=[int]$candidate.predicted_nodes", self.script)
        self.assertNotIn("CPU하한", self.script)

    def test_transactional_rollback_and_no_terraform_mutation(self):
        self.assertIn("finally {", self.script)
        self.assertIn("Set-Tuning $pending $bestKnobs.$pending", self.script)
        self.assertIn("function Set-TuningSet", self.script)
        self.assertIn("if($knobSet){Set-TuningSet $knobSet}else{Set-Tuning $app $step.knob}",
                      self.script)
        self.assertIn("foreach($name in $touched){ if($bestKnobs.$name){ Set-Tuning $name $bestKnobs.$name } }",
                      self.script)
        self.assertNotIn("& terraform", self.script.lower())



if __name__ == "__main__":
    unittest.main()
