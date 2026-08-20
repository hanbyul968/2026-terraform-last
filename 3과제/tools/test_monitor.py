import unittest
from unittest import mock

import monitor


class OfficialMetricTests(unittest.TestCase):
    def test_availability_and_performance_use_official_denominator(self):
        records = [
            {"status": 200, "path": "/v1/api", "method": "GET", "dur": 100, "ip": "x", "ts": "", "raw": ""},
            {"status": 200, "path": "/v1/api", "method": "GET", "dur": 300, "ip": "x", "ts": "", "raw": ""},
            {"status": 200, "path": "/v1/api", "method": "GET", "dur": 6000, "ip": "x", "ts": "", "raw": ""},
            {"status": 500, "path": "/v1/api", "method": "GET", "dur": 50, "ip": "x", "ts": "", "raw": ""},
            {"status": 200, "path": "/v1/api", "method": "GET", "dur": None, "ip": "x", "ts": "", "raw": ""},
        ]
        with mock.patch.object(monitor, "collect_app", return_value=records):
            row = monitor.app_detail("api", "2m", selector="api-label", slo_ms=200)
        self.assertEqual(row["total"], 5)
        self.assertEqual(row["c2"], 4)
        self.assertEqual(row["http_2xx_rate"], 80.0)
        self.assertEqual(row["ok_rate"], 40.0)   # 2xx and <= 5 seconds
        self.assertEqual(row["slo_rate"], 20.0)  # 2xx and <= 200ms / all requests


class DynamicInventoryTests(unittest.TestCase):
    def test_hpa_targets_labels_and_deployment_slos_are_discovered(self):
        deployments = {"items": [
            {"metadata": {"name": "alpha", "annotations": {"competition/slo-ms": "350"}},
             "spec": {"template": {"metadata": {"labels": {"app": "api-alpha"}},
                                    "spec": {"containers": [{}]}}}},
            {"metadata": {"name": "beta"},
             "spec": {"template": {"metadata": {"labels": {"app": "api-beta"}},
                                    "spec": {"containers": [{"env": [{"name": "SLO_MS", "value": "800"}]}]}}}},
        ]}
        hpas = {"items": [
            {"metadata": {"name": "beta-autoscaler"},
             "spec": {"scaleTargetRef": {"kind": "Deployment", "name": "beta"}}},
            {"metadata": {"name": "alpha-autoscaler"},
             "spec": {"scaleTargetRef": {"kind": "Deployment", "name": "alpha"}}},
        ]}
        specs = monitor.discover_app_specs(deployments, hpas)
        self.assertEqual([x["name"] for x in specs], ["beta", "alpha"])
        self.assertEqual(specs[0]["selector"], "api-beta")
        self.assertEqual(specs[0]["slo_ms"], 800.0)
        self.assertEqual(specs[1]["selector"], "api-alpha")
        self.assertEqual(specs[1]["slo_ms"], 350.0)

    def test_cli_slo_parser_accepts_changed_apps_and_rejects_bad_values(self):
        self.assertEqual(monitor.parse_slos_ms("checkout=125,search=750"),
                         {"checkout": 125.0, "search": 750.0})
        with self.assertRaises(ValueError):
            monitor.parse_slos_ms("checkout")
        with self.assertRaises(ValueError):
            monitor.parse_slos_ms("checkout=0")


if __name__ == "__main__":
    unittest.main()
