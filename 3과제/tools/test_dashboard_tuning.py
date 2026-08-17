import json
import pathlib
import subprocess
import unittest

SOURCE = pathlib.Path(__file__).with_name("dashboard.py").read_text(encoding="utf-8-sig")


def extract_function(name, next_name):
    start = SOURCE.index("function " + name + "(")
    end = SOURCE.index("\nfunction " + next_name + "(", start)
    return SOURCE[start:end]


TUNE_PARSE_JS = extract_function("tuneParse", "tuneCmds")
TUNE_CMDS_JS = extract_function("tuneCmds", "tuneRun")


def run_parser(text, with_html=False):
    script = (
        "var D={apps:[{app:'user'},{app:'product'},{app:'stress'}]};\n"
        "function esc(x){return String(x);}\n"
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


if __name__ == "__main__":
    unittest.main()
