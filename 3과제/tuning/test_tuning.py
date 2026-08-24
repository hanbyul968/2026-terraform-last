import pathlib
import unittest
import sys

ROOT = pathlib.Path(__file__).parent
sys.path.insert(0, str(ROOT))

import rubric
import score
import tuning_engine as engine
import optimize


def _tfvars_payload(commands):
    """튜너가 만든 PowerShell 명령에서 tfvars JSON 을 되꺼낸다.

    엔진은 인용/인코딩 사고를 피하려고 base64 로 감싼 WriteAllText 한 줄을 낸다.
    테스트는 그 payload 를 디코딩해 '무엇을 쓰려 했는지' 검증한다.
    """
    import base64
    import json
    import re

    for command in commands:
        m = re.search(r'FromBase64String\("([A-Za-z0-9+/=]+)"\)', command)
        if m:
            return json.loads(base64.b64decode(m.group(1)).decode("utf-8"))
    raise AssertionError(f"tfvars 기록 명령을 찾지 못했습니다: {commands}")


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

    def test_severe_performance_shortfall_triggers_aggressive_recovery(self):
        """user 성능 14.8%처럼 심한 미달이면 target을 크게 낮추고 replica를 늘린다(비용보다 우선)."""
        u = engine.AppSnapshot(
            name="user", slo_seconds=.2, samples=32000, window_seconds=120.0,
            availability=99.8, performance=14.8, request_m=175, memory_request_mi=128,
            target=90, min_replicas=2, max_replicas=9, replicas=9, pods_p90=9, pods_max=9,
            per_pod_p90=170, per_pod_p95=400, total_cpu_p90=1530, total_cpu_p95=3600,
            cpu_samples=60, latencies=tuple([.05] * 44 + [.25] * 256))
        snapshot = engine.TuningSnapshot(
            {"user": u}, engine.ClusterSnapshot(node_alloc_m=1930, node_mem_alloc_mi=3292,
                                                cluster_cpu_p95_m=1530, system_reserved_m=900,
                                                baseline_node_count=2, zone_count=2, node_average=3))
        gr = next(c for c in engine.generate_candidates(snapshot) if c.kind == "gate-recovery")
        self.assertEqual(gr.proposed["target"], engine.TARGET_MIN)   # 심한 미달 -> 최저 target
        self.assertGreater(gr.proposed["max"], 9)                    # 스케일아웃 여지 확대
        self.assertGreaterEqual(gr.proposed["min"], 3)               # 초기 파드 증가
        self.assertFalse(gr.disruptive)                              # HPA-only (부하 중 적용 가능)
        # gate-recovery가 후보 최상위(비용보다 우선).
        self.assertEqual(engine.generate_candidates(snapshot)[0].kind, "gate-recovery")

    def test_sizing_stays_below_computed_need_with_headroom(self):
        """request는 노드를 꽉 채우는 계산 최대치가 아니라 그보다 낮게(HEADROOM) 나온다."""
        self.assertLess(engine.REQUEST_HEADROOM, 1.0)
        app = self.app(name="svc", slo_seconds=1.0, samples=2000, window_seconds=120.0,
                       request_m=900, cpu_limit_m=2000, target=55, min_replicas=2,
                       max_replicas=8, replicas=4, pods_p90=4, pods_max=4,
                       per_pod_p90=400, per_pod_p95=450, total_cpu_p90=1600,
                       total_cpu_p95=1600, cpu_samples=60, latencies=tuple([.3] * 200))
        snapshot = engine.TuningSnapshot(
            {"svc": app}, engine.ClusterSnapshot(node_alloc_m=1930, node_mem_alloc_mi=3292,
                                                 cluster_cpu_p95_m=1600, system_reserved_m=900,
                                                 baseline_node_count=2, zone_count=2, node_average=4))
        need_per_pod = snapshot.app_required_cpu_m("svc") / app.pods_p90
        sized = engine._usage_sized(snapshot, app, engine._current_dict(app))
        self.assertIsNotNone(sized)
        self.assertLess(sized["request"], need_per_pod)  # 계산 필요치보다 낮다

    def test_hpa_only_mode_excludes_request_changes(self):
        """부하 중 루프는 rollout을 일으키는 request 변경 후보를 내지 않는다."""
        def app(name, perf, avail, req, tgt, pods, cpu, mx):
            return engine.AppSnapshot(
                name=name, slo_seconds=1.0, samples=2000, window_seconds=120.0,
                availability=avail, performance=perf, request_m=req, memory_request_mi=128,
                cpu_limit_m=2000, target=tgt, min_replicas=2, max_replicas=mx, replicas=pods,
                pods_p90=pods, pods_max=pods, per_pod_p90=int(cpu / pods), per_pod_p95=int(cpu / pods),
                total_cpu_p90=cpu, total_cpu_p95=cpu, cpu_samples=60, latencies=tuple([.3] * 300))
        snapshot = engine.TuningSnapshot(
            {"stress": app("stress", 24, 63, 750, 40, 8, 7000, 10),
             "user": app("user", 82, 99.9, 600, 90, 6, 3000, 9),
             "product": app("product", 99.5, 100, 250, 70, 4, 700, 8)},
            engine.ClusterSnapshot(baseline_nodes=2, node_average=6, node_count=6,
                                   node_alloc_m=1930, node_mem_alloc_mi=3292,
                                   cluster_cpu_p95_m=9700, system_reserved_m=1200,
                                   baseline_node_count=2))
        for c in engine.generate_candidates(snapshot, hpa_only=True):
            for name, v in c.knobs.items():
                self.assertEqual(v["request"], engine._current_dict(snapshot.apps[name])["request"])
            self.assertFalse(c.disruptive)
        # 전체 모드에서는 request 변경 후보도 나온다(부하 전 사이징용).
        full = engine.generate_candidates(snapshot, hpa_only=False)
        self.assertTrue(any(c.disruptive for c in full))

    def test_bin_packing_idle_nodes_and_baseline_guard(self):
        """유휴 노드는 총 예약이 아니라 AZ별 bin-packing으로 정해진다(Karpenter 잔존 재현)."""
        self.assertEqual(engine.bin_pack_nodes([775, 775, 750, 750, 50, 50], 1480), 4)
        self.assertEqual(engine.bin_pack_nodes([600, 600, 750, 750, 50, 50], 1480), 2)

        def app(name, req, mn):
            return engine.AppSnapshot(
                name=name, slo_seconds=1.0, samples=2000, window_seconds=120.0,
                availability=100, performance=95, request_m=req, memory_request_mi=128,
                cpu_limit_m=2000, target=55, min_replicas=mn, max_replicas=8, replicas=mn,
                pods_p90=mn, pods_max=mn, per_pod_p90=int(req * .5), per_pod_p95=int(req * .6),
                total_cpu_p90=req * mn, total_cpu_p95=req * mn, cpu_samples=60,
                latencies=tuple([.3] * 200))
        cl = dict(node_alloc_m=1930, node_mem_alloc_mi=3292, cluster_cpu_p95_m=1700,
                  system_reserved_m=900, baseline_node_count=2, zone_count=2, node_average=3)
        # AZ당 user+stress+product = 600+750+250 = 1600 > 1480 -> AZ당 2노드 -> 유휴 4노드
        stuck = engine.TuningSnapshot(
            {"user": app("user", 600, 2), "stress": app("stress", 750, 2),
             "product": app("product", 250, 2)}, engine.ClusterSnapshot(**cl))
        self.assertGreater(stuck.idle_nodes(), 2)
        # 600+600+250 = 1450 <= 1480 -> 유휴 2노드
        fit = engine.TuningSnapshot(
            {"user": app("user", 600, 2), "stress": app("stress", 600, 2),
             "product": app("product", 250, 2)}, engine.ClusterSnapshot(**cl))
        self.assertEqual(fit.idle_nodes(), 2)
        # idle-fit이 유휴 초과 상태를 baseline로 되돌리는 request 축소 묶음을 낸다.
        recovered = engine._idle_fit(stuck)
        self.assertIsNotNone(recovered)
        self.assertLessEqual(stuck.idle_nodes(recovered), 2)
        for name, v in recovered.items():
            self.assertLessEqual(v["request"], engine._current_dict(stuck.apps[name])["request"])
        # plan은 이 축소 묶음을 presize(부하 전 1회 적용)로 노출한다.
        plan = engine.plan(stuck)
        self.assertIsNotNone(plan["presize"])
        self.assertLessEqual(plan["idle_nodes_after_presize"], 2)

    def test_one_failing_app_does_not_block_other_apps(self):
        """한 앱이 기준 미달이어도 다른 앱 후보가 나와야 한다(회차 독식 방지)."""
        def app(name, perf, avail, req, tgt, pods, cpu, mx):
            return engine.AppSnapshot(
                name=name, slo_seconds=1.0, samples=2000, window_seconds=120.0,
                availability=avail, performance=perf, request_m=req, memory_request_mi=128,
                cpu_limit_m=2000, target=tgt, min_replicas=2, max_replicas=mx,
                replicas=pods, pods_p90=pods, pods_max=pods, cpu_samples=60,
                per_pod_p90=int(cpu / pods), per_pod_p95=int(cpu / pods),
                total_cpu_p90=cpu, total_cpu_p95=cpu, latencies=tuple([.30] * 300))
        snapshot = engine.TuningSnapshot(
            {"stress": app("stress", 24.0, 63.0, 750, 55, 8, 6000, 8),
             "user": app("user", 82.0, 99.9, 775, 90, 6, 3000, 9),
             "product": app("product", 99.5, 100.0, 250, 70, 4, 700, 8)},
            engine.ClusterSnapshot(baseline_nodes=2, node_average=6, node_count=6,
                                   node_alloc_m=1930, node_mem_alloc_mi=3292,
                                   cluster_cpu_p95_m=9700, system_reserved_m=1200))
        result = engine.plan(snapshot)
        covered = {a for c in result["candidates"][:3] for a in c["knobs"]}
        self.assertEqual(covered, {"stress", "user", "product"})
        # 기준 미달 앱이 섞인 묶음도 후보로 남는다(한 회차로 여러 앱 처리).
        bundle = next(c for c in result["candidates"] if c["kind"] == "bundle")
        self.assertEqual(set(bundle["knobs"]), {"stress", "user", "product"})

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
        # 두 앱의 목표값이 tfvars(app_tuning)에 모두 들어 있다.
        # kubectl 명령이 아니라 terraform 경유여야 한다(드리프트 방지).
        joined = " ".join(bundle.apply_commands + bundle.rollback_commands)
        self.assertNotIn("kubectl", joined)
        self.assertIn("terraform apply", joined)
        payload = _tfvars_payload(bundle.apply_commands)
        self.assertIn("a", payload["app_tuning"])
        self.assertIn("b", payload["app_tuning"])
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
        # 측정 부하(10 rps): 요청당 CPU 100ms x 10rps = 1000m / 4파드 = 250m이 '필요치'.
        # 사이징은 HEADROOM(0.7)을 곱해 그보다 낮게, 실사용 절반(125m) 이상으로 잡는다.
        self.assertAlmostEqual(over.cpu_seconds_per_request, .1, places=3)
        sized = engine._usage_sized(snapshot, over, current)["request"]
        self.assertLess(sized, 250)                 # 필요치보다 낮다
        self.assertGreaterEqual(sized, 125)         # 실사용 절반 이상
        # 목표 부하를 절반으로 두면 필요치도 절반(125m) → 하한(125m) 근처로 더 낮아진다.
        snapshot.load_scale = .5
        low = engine._usage_sized(snapshot, over, current)
        self.assertTrue(low is None or low["request"] <= sized)

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
        # 예산을 꽉 채우는 값(2000m)이 아니라 HEADROOM을 둔 낮은 값으로 나온다.
        self.assertLess(fit["knobs"]["svc"]["request"], 2000)
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
        # 과소예약 교정값도 목표 부하 기준으로 계산되되 HEADROOM을 둔 낮은 값이다.
        sized = engine._usage_sized(snapshot, stress, engine._current_dict(stress))
        need_per_pod = snapshot.app_required_cpu_m("stress") / stress.pods_p90
        self.assertLessEqual(sized["request"], engine.ceil_to(need_per_pod))
        self.assertGreaterEqual(sized["request"], engine.ceil_to(need_per_pod * engine.REQUEST_HEADROOM) - engine.REQUEST_UNIT_M)

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
        # 되돌리기는 '현재 값'을 tfvars 에 다시 쓰는 형태여야 한다(kubectl 금지).
        self.assertNotIn("kubectl", " ".join(optimal.rollback_commands))
        rollback_payload = _tfvars_payload(optimal.rollback_commands)
        self.assertEqual(rollback_payload["app_tuning"]["worker"]["cpu_request_m"], 750)
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

    def test_tfvars_is_keyed_by_app_name(self):
        """Terraform 의 for_each 키가 앱 이름이므로 tfvars 도 앱 이름으로 적어야 한다.

        이전에는 라이브 Deployment/HPA 이름(checkout-api / checkout-scaler)으로
        kubectl 명령을 만들었다. 지금은 Terraform 이 리소스 이름을 소유하므로
        (kubernetes_deployment.app["checkout"]) 튜너는 앱 키만 알면 된다.
        """
        app = self.app(name="checkout", deployment_name="checkout-api",
                       hpa_name="checkout-scaler",
                       latencies=self.latencies())
        optimal = next(c for c in engine.generate_candidates(self.snapshot(app))
                       if c.kind == "request-optimal")
        all_commands = optimal.apply_commands + optimal.rollback_commands
        self.assertNotIn("kubectl", " ".join(all_commands))
        payload = _tfvars_payload(optimal.apply_commands)
        self.assertIn("checkout", payload["app_tuning"])

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

    def test_hard_20_minute_budget_is_enforced(self):
        """20분 예산을 넘기지 않도록, 비싼 단계마다 남은 시간을 확인해야 한다.

        terraform apply 는 kubectl patch 보다 느려(회당 60~90s) 예산 초과가 실제 위험이다.
        옛 설계의 후보 반복 루프(for $i -le $candidateLimit)는 제거됐고, 지금은
        단발 검증 + 예산 가드 구조다.
        """
        self.assertIn("[int]$BudgetMinutes = 20", self.script)
        self.assertIn("[string]$Duration = '90s'", self.script)
        self.assertIn("[int]$WarmupSeconds = 30", self.script)
        # 남은 시간 계산과 단계별 가드
        self.assertIn("function Get-SecondsLeft", self.script)
        self.assertIn("function Test-TimeFor", self.script)
        self.assertIn("Test-TimeFor $needPresize", self.script)
        self.assertIn("Test-TimeFor $needCand", self.script)
        # apply 실측으로 예측을 갱신
        self.assertIn("function Measure-Apply", self.script)
        self.assertIn("$script:ApplyCostSeconds", self.script)
        self.assertIn("안전선 미달", self.script)

    def test_accepts_on_official_band_floors_not_a_stricter_gate(self):
        self.assertIn("[ValidateSet('cost','balanced')][string]$Objective = 'cost'", self.script)
        self.assertIn("[double]$AvailFloor = 90", self.script)
        self.assertIn("[double]$PerfFloor = 80", self.script)
        self.assertIn("($score.min_avail -ge $availFloor) -and ($score.min_perf -ge $perfFloor)",
                      self.script)
        self.assertNotIn("$score.perf_gate_pass -and $score.avail_gate_pass", self.script)

    def test_plans_from_accepted_snapshot_and_settles_after_rollback(self):
        self.assertIn("Save-Snapshot $out $bestOut", self.script)
        self.assertIn("Get-NextStep $bestOut $rejFile", self.script)
        # 롤백은 여러 앱을 한 번의 apply 로 되돌린다(앱마다 apply 하면 예산을 태운다).
        self.assertIn("Set-TuningMany $touched $bestKnobs", self.script)
        self.assertIn("robocopy", self.script)  # 잠긴 CSV에 견디는 복사
        self.assertNotIn("CPU하한", self.script)

    def test_presize_applied_once_before_hpa_loop(self):
        self.assertIn("부하 전 request 사이징", self.script)
        self.assertIn("if($first.presize){", self.script)
        self.assertIn("Set-TuningSet $first.presize", self.script)

    def test_live_loop_is_hpa_only_and_applies_via_terraform(self):
        self.assertIn("[switch]$AllowRequestChange", self.script)
        self.assertIn("if(-not $AllowRequestChange){$a+=@('--hpa-only')}", self.script)
        # rollout 대기는 더 이상 필요 없다: terraform 이 apply 완료까지 블로킹한다.
        # 대신 클러스터를 직접 변형하지 않는지를 검증한다.
        self.assertNotIn("kubectl -n $NS patch", self.script)
        self.assertNotIn("kubectl -n $NS set resources", self.script)

    def test_does_not_spend_budget_on_a_single_app(self):
        """한 앱만 붙잡고 예산을 태우지 않아야 한다.

        옛 설계는 회차를 돌며 앱을 로테이션했다(triedApps / Test-Untried). 지금은
        엔진이 전 앱을 한 묶음(knob_set)으로 계산해 1회 apply 로 끝내므로, 애초에
        한 앱에 회차가 몰릴 구조가 아니다. 20분 예산에도 이 쪽이 유리하다.
        """
        self.assertIn("$knobSet=if($step.knob_set){$step.knob_set}else{$null}", self.script)
        self.assertIn("전 앱 HPA 한 번에 적용", self.script)
        self.assertIn("Measure-Apply { Set-TuningSet $knobSet }", self.script)

    def test_applies_through_terraform_never_mutates_cluster_directly(self):
        """튜닝은 반드시 Terraform 경유. kubectl 직접 변형은 드리프트를 만든다.

        이전 정책은 정반대였다("Terraform은 건드리지 않는다"). 그 결과 채점 회차의
        라이브 값이 .tf 파일값과 전부 달라져, 무엇이 채점된 구성인지 알 수 없었고
        누군가 terraform apply 를 하면 튜닝이 조용히 원복되는 상태였다.
        """
        self.assertIn("finally {", self.script)
        self.assertIn("function Set-TuningSet", self.script)
        # tfvars 에 쓰고 terraform 이 반영한다.
        self.assertIn("tuning.auto.tfvars.json", self.script)
        self.assertIn("terraform apply", self.script)
        # 클러스터를 직접 고치는 경로가 남아 있으면 안 된다.
        self.assertNotIn("kubectl -n $NS patch", self.script)
        self.assertNotIn("kubectl -n $NS set resources", self.script)



class CostBaselineUncertaintyTests(unittest.TestCase):
    """비용 ratio의 분모(B)는 비공개다. 그 불확실성 아래에서 총점을 최대화하는지 검증한다."""

    def lat(self, count, low, high):
        return tuple(round(low + (high - low) * i / (count - 1), 4) for i in range(count))

    def snapshot(self, **cluster):
        values = dict(baseline_nodes=2, node_average=4, node_count=4, node_alloc_m=1930,
                      node_mem_alloc_mi=3292, cluster_cpu_p95_m=6000,
                      system_reserved_m=1200, baseline_node_count=2, zone_count=2)
        values.update(cluster)
        apps = {
            "user": engine.AppSnapshot(
                name="user", slo_seconds=.2, samples=20000, window_seconds=120.0,
                availability=99.5, performance=86.0, request_m=600, memory_request_mi=128,
                target=90, min_replicas=2, max_replicas=9, replicas=6, pods_p90=6, pods_max=6,
                per_pod_p90=300, per_pod_p95=420, total_cpu_p90=1800, total_cpu_p95=2100,
                cpu_samples=90, success_ratio=.995, latencies=self.lat(400, .04, .34)),
            "stress": engine.AppSnapshot(
                name="stress", slo_seconds=1.0, samples=2400, window_seconds=120.0,
                availability=99.0, performance=84.0, request_m=750, memory_request_mi=128,
                cpu_limit_m=2000, target=55, min_replicas=2, max_replicas=8, replicas=6,
                pods_p90=6, pods_max=6, per_pod_p90=900, per_pod_p95=1400,
                total_cpu_p90=5400, total_cpu_p95=6200, cpu_samples=90,
                success_ratio=.99, latencies=self.lat(400, .20, 1.30)),
        }
        return engine.TuningSnapshot(apps, engine.ClusterSnapshot(**values))

    def test_performance_prediction_uses_all_requests_as_denominator(self):
        """latencies 에는 2xx 만 담기므로 그대로 나누면 실패분이 분모에서 빠져 낙관 편향이 된다."""
        app = engine.AppSnapshot(
            name="a", slo_seconds=1.0, samples=1000, window_seconds=100.0,
            availability=90.0, performance=90.0, success_ratio=.90,
            latencies=tuple([.10] * 900))
        perf, avail = app.performance_at(1.0)
        # 전부 SLO 안이지만 10% 는 애초에 실패했다 -> 90% 이지 100% 가 아니다.
        self.assertAlmostEqual(perf, 90.0, places=6)
        self.assertAlmostEqual(avail, 90.0, places=6)

    def test_quality_curve_does_not_depend_on_secret_baseline(self):
        """성능+가용성 24점은 B와 무관하다. 이게 성립해야 B를 몰라도 곡선을 그릴 수 있다."""
        snapshot = self.snapshot()
        snapshot.cost_baselines = (2.0,)
        a = {row["nodes"]: row["quality"] for row in engine.score_frontier(snapshot)}
        snapshot.cost_baselines = (3.0, 5.0, 9.0)
        b = {row["nodes"]: row["quality"] for row in engine.score_frontier(snapshot)}
        shared = set(a) & set(b)
        self.assertTrue(shared)
        for nodes in shared:
            self.assertEqual(a[nodes], b[nodes])

    def test_cost_floor_means_fewer_nodes_is_not_always_better(self):
        """ratio<0.50 이면 비용 12점이 통째로 0이다. 저구간에서는 노드를 늘리는 쪽이 이득이다.

        이 성질 때문에 '적은 노드가 항상 우월'이라는 가지치기를 쓸 수 없다.
        """
        self.assertEqual(rubric.cost_points_for_nodes(2, 5.0), 0.0)   # ratio 0.40 -> 하한 미달
        self.assertEqual(rubric.cost_points_for_nodes(3, 5.0), 12.0)  # ratio 0.60 -> 만점
        # 프론티어는 하한 절벽이 보이도록 0.5*maxB 아래까지 훑어야 한다.
        snapshot = self.snapshot()
        snapshot.cost_baselines = (8.0,)
        nodes = [row["nodes"] for row in engine.score_frontier(snapshot)]
        self.assertGreaterEqual(max(nodes), 5)

    def test_report_picks_operating_point_and_flags_baseline_sensitivity(self):
        snapshot = self.snapshot()
        report = engine.frontier_report(snapshot)
        self.assertTrue(report["knees"])
        self.assertIn(report["recommended_nodes"], [r["nodes"] for r in report["knees"]])
        self.assertEqual(report["recommended_nodes"], report["minimax_nodes"])
        # 추천값의 최악 손해는 모든 후보 중 최소여야 한다.
        worst = {r["nodes"]: r["max_regret"] for r in report["knees"]}
        self.assertEqual(worst[report["recommended_nodes"]], min(worst.values()))
        # B별 최적이 모두 같을 때만 robust 로 보고한다.
        self.assertEqual(report["robust"], len(set(report["picks"].values())) == 1)

    def test_plan_exposes_frontier_and_targets_it(self):
        snapshot = self.snapshot()
        result = engine.plan(snapshot)
        self.assertIn("frontier", result)
        self.assertEqual(result["target_nodes"], result["frontier"]["recommended_nodes"])


class InstanceTypeFlexibilityTests(unittest.TestCase):
    """인스턴스 타입이 바뀌어도 사이징과 비용 축이 따라가야 한다."""

    def test_size_units_cover_every_aws_size_suffix(self):
        self.assertEqual(engine.instance_size_units("t3.medium"), 2.0)
        self.assertEqual(engine.instance_size_units("t3.large"), 4.0)
        self.assertEqual(engine.instance_size_units("c6i.xlarge"), 8.0)
        self.assertEqual(engine.instance_size_units("m5.2xlarge"), 16.0)
        self.assertEqual(engine.instance_size_units("m5.24xlarge"), 192.0)
        self.assertEqual(engine.instance_size_units("t3.nano"), .25)
        # 모르는 형식은 0 -> 가중치 1.0(현상 유지)로 떨어진다.
        self.assertEqual(engine.instance_size_units("weird"), 0.0)
        self.assertEqual(engine.node_cost_weight("weird"), 1.0)

    def test_cost_weight_is_relative_to_reference_type(self):
        """비용은 '대수'가 아니라 인스턴스 비용의 비율이다. large 1대 = medium 2대분."""
        self.assertEqual(engine.node_cost_weight("t3.medium"), 1.0)
        self.assertEqual(engine.node_cost_weight("t3.large"), 2.0)
        self.assertEqual(engine.node_cost_weight("t3.small"), .5)
        self.assertEqual(engine.node_cost_weight("m5.xlarge", "m5.large"), 2.0)

    def test_cost_units_convert_node_count_to_reference_instances(self):
        cluster = engine.ClusterSnapshot(node_average=3, instance_type="t3.large",
                                         node_cost_weight=2.0)
        self.assertEqual(cluster.cost_units(), 6.0)
        self.assertEqual(cluster.cost_units(2), 4.0)
        # 가중치가 없으면 대수가 곧 단위다(기존 동작).
        self.assertEqual(engine.ClusterSnapshot(node_average=3).cost_units(), 3.0)

    def test_bigger_instances_score_as_more_expensive_at_same_node_count(self):
        """같은 대수라도 큰 타입이면 비용 점수가 낮아야 한다."""
        def snap(itype, weight):
            app = engine.AppSnapshot(
                name="a", slo_seconds=1.0, samples=2000, window_seconds=120.0,
                availability=99.0, performance=90.0, request_m=500, target=70,
                min_replicas=2, max_replicas=8, replicas=4, pods_p90=4, pods_max=4,
                per_pod_p90=300, per_pod_p95=400, total_cpu_p90=1200, total_cpu_p95=1400,
                cpu_samples=90, success_ratio=1.0, latencies=tuple([.30] * 300))
            return engine.TuningSnapshot({"a": app}, engine.ClusterSnapshot(
                baseline_nodes=2, node_average=4, node_count=4, node_alloc_m=1930,
                cluster_cpu_p95_m=1400, system_reserved_m=400,
                instance_type=itype, node_cost_weight=weight))
        medium = snap("t3.medium", 1.0).score()
        large = snap("t3.large", 2.0).score()
        self.assertEqual(medium.cost_ratio * 2, large.cost_ratio)
        self.assertGreater(medium.cost_points, large.cost_points)

    def test_node_capacity_comes_from_live_cluster_not_constants(self):
        """노드 CPU/메모리/AZ는 실측값이라 타입이 바뀌어도 사이징이 따라간다."""
        small = engine.ClusterSnapshot(node_alloc_m=940, node_count=2, system_reserved_m=300)
        big = engine.ClusterSnapshot(node_alloc_m=7810, node_count=2, system_reserved_m=300)
        self.assertLess(small.usable_cpu_per_node_m, big.usable_cpu_per_node_m)
        # 노드당 시스템 예약은 총합/노드수로 나눠 쓰므로 노드가 늘어도 부풀지 않는다.
        self.assertEqual(small.daemonset_per_node_m, 150)


if __name__ == "__main__":
    unittest.main()
