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
        # 이제 kubectl 이 아니라 tuning/apply.ps1 로 tfvars 에 기록한다(드리프트 방지).
        self.assertNotIn("kubectl", result["html"])
        self.assertIn(".\\apply.ps1 -App stress -Request 375 -Target 52 -Min 3 -Max 17", result["html"])
        self.assertIn(".\\apply.ps1 -App user -Request 200 -Target 50 -Min 3 -Max 17", result["html"])
        self.assertIn("terraform apply", result["html"])
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

    def test_two_value_summary_format_is_accepted(self):
        """optimize.ps1 요약 출력(request=..m target=..%)만으로도 파싱된다.

        min/max 가 없어도 거부하지 않는다 — tfvars 는 필드 단위 병합이라
        빠진 값은 apps/app_defaults 로 채워진다. (이전엔 네 값을 모두 요구해 막혔다)
        """
        text = ("  product: request=100m target=90%\n"
                "  stress: request=725m target=58%\n"
                "  user: request=350m target=29%")
        self.assertEqual(run_parser(text)["items"], [
            {"app": "product", "cpu": "100m", "util": 90, "min": None, "max": None},
            {"app": "stress", "cpu": "725m", "util": 58, "min": None, "max": None},
            {"app": "user", "cpu": "350m", "util": 29, "min": None, "max": None},
        ])
        html = run_parser(text, with_html=True)["html"]
        self.assertNotIn("kubectl", html)
        self.assertIn(".\\apply.ps1 -App product -Request 100 -Target 90", html)
        self.assertNotIn("-Min", html.split("product")[1].split("stress")[0])  # min/max 없으면 안 붙음

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
        self.assertEqual(data["tuning"]["schema_version"], 2)
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
