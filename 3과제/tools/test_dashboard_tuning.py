import json
import pathlib
import subprocess
import unittest

ROOT = pathlib.Path(__file__).parent
SOURCE = pathlib.Path(__file__).with_name("dashboard.py").read_text(encoding="utf-8-sig")


def extract_function(name, next_name):
    start = SOURCE.index("function " + name + "(")
    end = SOURCE.index("\nfunction " + next_name + "(", start)
    return SOURCE[start:end]


TUNE_PARSE_JS = extract_function("tuneParse", "tuneCmds")
TUNE_CMDS_JS = extract_function("tuneCmds", "tuneRun")


def run_parser(text, with_html=False):
    script = (
        "var D={namespace:'app',apps:[{app:'user',cpu_req:'100m'},{app:'product',cpu_req:'100m'},{app:'stress',cpu_req:'250m'}],hpa:[{name:'user',tgt:'60%',min:2,max:10},{name:'product',tgt:'60%',min:2,max:10},{name:'stress',tgt:'55%',min:2,max:12}]};\n"
        "function esc(x){return String(x);}\n"
        "function pctn(s){var n=parseInt((''+(s||'')).replace('%',''));return isNaN(n)?null:n}\n"
        "function hpaOf(n){return (D.hpa||[]).find(function(h){return h.name===n})||{}}\n"
        "function tuneCmdBlock(t,c){return t+' '+c.join('\\n')}\n"
        + TUNE_PARSE_JS + "\n"
        + (TUNE_CMDS_JS + "\n" if with_html else "")
        + ("var r=tuneParse(process.argv[1]); console.log(JSON.stringify({parsed:r,html:tuneCmds(r)}));"
           if with_html else
           "console.log(JSON.stringify(tuneParse(process.argv[1])));")
    )
    result = subprocess.run(["node", "-e", script, text], capture_output=True,
                            text=True, encoding="utf-8", errors="replace", check=True)
    return json.loads(result.stdout)


class TuneParseTests(unittest.TestCase):
    def test_current_readonly_output_keeps_values_per_app_and_excludes_missing_product(self):
        text = '''stress: requests.cpu="375m", min_replicas=3, max_replicas=17, average_utilization=52
user: requests.cpu="200m", min_replicas=3, max_replicas=17, average_utilization=50
자동 적용하지 않았습니다.'''
        result = run_parser(text, with_html=True)
        self.assertEqual(result["parsed"]["items"], [
            {"app": "stress", "cpu": "375m", "util": 52, "min": 3, "max": 17},
            {"app": "user", "cpu": "200m", "util": 50, "min": 3, "max": 17},
        ])
        self.assertIn("적용 대상: stress, user", result["html"])
        self.assertIn("stress → cpu=375m util=52% min=3 max=17", result["html"])
        self.assertIn("user → cpu=200m util=50% min=3 max=17", result["html"])
        self.assertNotIn("product →", result["html"])
        self.assertIn("점수 미개선/오류 시 정확한 롤백", result["html"])
        self.assertIn("requests=cpu=250m", result["html"])
        # PowerShell 형식: 백슬래시 이스케이프(-p '{\"..\"}') 대신 임시파일 + --patch-file.
        # 롤백 patch 의 minReplicas 는 이스케이프 없는 순수 JSON 으로 나와야 한다.
        self.assertIn('"minReplicas":2', result["html"])
        self.assertNotIn('minReplicas\\":2', result["html"])
        self.assertIn("--patch-file", result["html"])
        self.assertIn("Set-Content -Path", result["html"])
        self.assertNotIn("--type=merge -p", result["html"])
        # requests 명령은 현재값과 같아도 항상 나와야 한다 (apply 쪽)
        self.assertIn("requests=cpu=375m", result["html"])
        self.assertIn("requests=cpu=200m", result["html"])
        self.assertIn("Terraform apply는 튜닝에 필요하지 않습니다", result["html"])
        self.assertNotIn("k8s_apps.tf", result["html"])


    def test_field_order_is_free(self):
        text = "user: max_replicas=9, average_utilization=44, requests.cpu=225m, min_replicas=4"
        self.assertEqual(run_parser(text)["items"], [
            {"app": "user", "cpu": "225m", "util": 44, "min": 4, "max": 9}
        ])

    def test_arrow_summary_format(self):
        text = "user → cpu=200m util=50% min=3 max=17\nstress → max=15 min=4 target=48% request=350m"
        self.assertEqual(run_parser(text)["items"], [
            {"app": "user", "cpu": "200m", "util": 50, "min": 3, "max": 17},
            {"app": "stress", "cpu": "350m", "util": 48, "min": 4, "max": 15},
        ])

    def test_advise_block_format(self):
        text = '''[stress] avail=99.0% perf=55.0%
  현재: request=300m min=2 max=13 target=70%
  권장: request=375m min=3 max=17 target=52%
[user] avail=100.0% perf=28.0%
  권장: request=200m min=3 max=17 target=50%'''
        self.assertEqual(run_parser(text)["items"], [
            {"app": "stress", "cpu": "375m", "util": 52, "min": 3, "max": 17},
            {"app": "user", "cpu": "200m", "util": 50, "min": 3, "max": 17},
        ])

    def test_unscoped_single_value_is_not_copied_to_all_apps(self):
        text = 'requests.cpu="375m", min_replicas=3, max_replicas=17, average_utilization=52'
        result = run_parser(text)
        self.assertEqual(result["items"], [])
        self.assertIn("대상 앱", result["error"])

    def test_explicit_legacy_scope_still_works(self):
        text = '''### 반영값 (stress 만):
requests.cpu = "300m", HPA averageUtilization = 45, min=3 max=12'''
        self.assertEqual(run_parser(text)["items"], [
            {"app": "stress", "cpu": "300m", "util": 45, "min": 3, "max": 12}
        ])


class SharedDashboardPlanTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import sys
        sys.path.insert(0, str(ROOT))
        import dashboard
        cls.dashboard = dashboard

    def test_demo_data_contains_shared_official_plan(self):
        data = self.dashboard._add_tuning_plan(self.dashboard.demo_data())
        self.assertIn("tuning", data)
        self.assertEqual(data["tuning"]["schema_version"], 1)
        self.assertIn("score", data["tuning"])
        for candidate in data["tuning"]["candidates"]:
            self.assertTrue(candidate["apply_commands"])
            self.assertTrue(candidate["rollback_commands"])

    def test_page_prefers_shared_engine_renderer(self):
        self.assertIn("function vEnginePlan", self.dashboard.PAGE)
        self.assertIn("공통 엔진 라이브 후보", self.dashboard.PAGE)
        self.assertIn("정확한 롤백", self.dashboard.PAGE)


if __name__ == "__main__":
    unittest.main()
