#!/usr/bin/env python3
"""loadtest 결과 + 라이브 클러스터 상태 → 앱별 "딱 정해주는" 권장값 + 복붙 명령 출력.

측정(perf/avail/p95)과 현재 설정(cpu request, HPA util/min/max, 현재 CPU%)을 합쳐
앱마다 [늘려 / 줄여 / 유지] 판정을 내리고, 그대로 칠 수 있는 명령을 출력한다:
  - 즉시 적용: kubectl set resources + kubectl patch hpa (임시, 재배포 시 사라짐)
  - 영구 반영: terraform/k8s_apps.tf 에 넣을 값

사용법:
  python advise.py <label|outdir> [--slos user=0.2,product=0.2,stress=1.0] [--ns app]

  <label|outdir> : loadtest.ps1 의 label (예: baseline) 또는 결과 폴더 전체 경로.
                   label 이면 %TEMP%\\tune-<label> 을 찾는다.
  --slos         : 앱별 SLO(초). 목록에 없는 앱은 --default-slo 를 쓰고 경고를 낸다.
  (loadtest.ps1 이 끝에서 자동 호출하므로 보통 직접 칠 일은 없다)

중요 — requests.cpu 는 '노드 예약량'이지 '파드 속도 상한'이 아니다:
  cpu limit 이 없는 앱은 request 를 올려도 빨라지지 않는다. 올리면 오히려
    (1) 노드당 파드 수가 줄어 노드가 늘고(비용 상승),
    (2) HPA 사용률 = 실사용/request 이 작아져 스케일업이 늦어진다(성능 악화).
  그래서 '느리다 -> cpu 올려' 는 틀린 처방이다. 아래는 실사용·노드CPU·HPA상한으로
  원인을 먼저 구분하고, 권장 request 는 항상 실사용 피크 x 1.3 으로 계산한다.

판정 기준 (가용성 > 성능 > 비용):
  avail < 99%                          → 파드 상한이면 max+2, 아니면 min+1 · util-10 (request 유지)
  느림 + 파드가 max 에 붙음            → max+2 (request 유지)
  느림 + 노드CPU >= 80%                → request 올림 (노드 경쟁 완화. 이 경우만 유효)
  느림 + 실사용 < request x 0.5        → request 유지. CPU 병목 아님 -> DB/캐시/커넥션풀 확인
  느림 + 현재사용률 < 목표             → util-15 · min+1 (스케일 지연, request 유지)
  느림 + 실사용이 request 에 근접      → request = 실사용피크 x 1.3
  통과 + request >> 실사용             → request = 실사용피크 x 1.3 (과투자 -> 비용↓)
  그 외                                 → 유지

대회날 변경 대응: 앱 목록은 결과 CSV 에서, SLO 는 --slos, 노드 할당가능 CPU 와 노드 타입은
라이브 클러스터에서 읽는다. 앱 이름·개수·인스턴스 타입이 바뀌어도 코드 수정이 필요 없다.
"""
import argparse
import csv
import json
import os
import statistics
import subprocess
import sys

# 노드 1대의 할당가능 CPU 는 어떤 상수도 두지 않는다. 특정 인스턴스 타입(t3.medium 등)을
# 가정하면 대회날 타입이 바뀔 때 노드 수 추정이 조용히 틀어진다.
# 못 읽으면 0 을 돌려주고, 호출부는 추정을 아예 생략한다(틀린 숫자보다 '미확인'이 낫다).
# 비용 기준선 노드 수 (config.ps1 의 $COST_BASELINE_NODES). terraform node_desired_size 와 동일.
BASELINE_NODES = float(os.environ.get("TUNE_BASELINE_NODES", "2"))
DEFAULT_SLO = 1.0  # --slos 에 없는 앱에 쓰는 SLO(초). 쓰이면 경고를 출력한다.


def run(cmd, timeout=20):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8",
                              errors="replace", timeout=timeout).stdout or ""
    except Exception:
        return ""


def cpu_m(s):
    """'200m' | '0.5' → 밀리코어 정수."""
    if not s:
        return None
    s = str(s)
    return int(s[:-1]) if s.endswith("m") else int(float(s) * 1000)


def round50(v):
    return max(100, int(round(v / 50.0)) * 50)


def pct_nearest(sorted_vals, q):
    """보간 없는 순위 기반 백분위 (nearest-rank).

    statistics.quantiles(n=100) 는 보간을 하므로 표본이 적을 때 상위 백분위가 최댓값 쪽으로
    끌려간다. 실측: 120~150m 표본 19개 + 400m 스파이크 1개(총 20개)에서 p95 가 388m 로
    나왔다(기대값 ~152m). 부하 창 샘플은 5초 간격이라 180초면 36개 수준으로 적기 때문에
    보간형 백분위를 쓰면 스파이크 1회가 그대로 권고값을 흔든다.
    """
    if not sorted_vals:
        return 0
    if len(sorted_vals) == 1:
        return sorted_vals[0]
    idx = int(q / 100.0 * (len(sorted_vals) - 1))
    return sorted_vals[idx]


def right_size(peak_m):
    """권장 request = 실사용 피크 x 1.3, 25m 단위 상향, 하한 50m.

    임의 배수(x1.4 등)가 아니라 실측 피크에 헤드룸만 얹는다. request 는 예약량이라
    실사용보다 크게 잡을수록 노드가 그만큼 늘어난다(비용).
    """
    if not peak_m:
        return None
    return max(50, -(-int(peak_m * 1.3) // 25) * 25)


# ---------- 측정값 (loadtest CSV) ----------
# 결과 폴더의 CSV 중 '앱 측정 결과가 아닌' 파일들. 앱으로 오인하면 안 된다.
#   nodes.csv  : 노드/파드 수 타임라인
#   podcpu.csv : 파드 CPU 실사용 타임라인
# 실측 사고: podcpu.csv 를 추가했더니 앱 이름 'podcpu' 로 잡혀 load_measures 가
# hey CSV 로 읽다가 KeyError: 'response-time' 로 죽었다.
META_CSV = {"nodes", "podcpu"}


def is_app_csv(path):
    """hey 결과 CSV 인지 헤더로 판별. 이름 규칙에만 의존하지 않는 2차 방어.

    앞으로 어떤 메타 CSV 가 추가돼도 헤더에 response-time 이 없으면 앱으로 보지 않는다.
    """
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            head = f.readline()
    except OSError:
        return False
    return "response-time" in head


def discover_apps(outdir, slos):
    """결과 폴더의 <앱>.csv 로 앱 목록을 만든다 (메타 CSV 제외).

    대회날 앱 이름/개수가 바뀌어도 코드를 고치지 않아도 되게 하드코딩하지 않는다.
    --slos 에 없는 앱은 DEFAULT_SLO 를 쓰고 호출부에서 경고를 낸다.
    """
    apps, assumed = [], []
    try:
        files = sorted(f for f in os.listdir(outdir) if f.endswith(".csv"))
    except OSError:
        files = []
    for f in files:
        name = os.path.splitext(f)[0]
        if name in META_CSV:
            continue
        if not is_app_csv(os.path.join(outdir, f)):
            continue
        apps.append(name)
        if name not in slos:
            assumed.append(name)
    # CSV 가 없으면 --slos 에 적힌 앱이라도 시도
    if not apps:
        apps = list(slos.keys())
    return apps, assumed


def load_measures(outdir, slos):
    out = {}
    for api, slo in slos.items():
        try:
            rows = list(csv.DictReader(open(os.path.join(outdir, api + ".csv"))))
        except FileNotFoundError:
            rows = []
        if not rows:
            out[api] = None
            continue
        if rows and "response-time" not in rows[0]:
            # 앱 CSV 가 아니다(메타 파일 등). 죽지 말고 측정 없음으로 넘긴다.
            out[api] = None
            continue
        lat = [float(r["response-time"]) for r in rows]
        ok = [r for r in rows if r["status-code"].startswith("2") and float(r["response-time"]) <= 5.0]
        good = [r for r in ok if float(r["response-time"]) <= slo]
        p95 = statistics.quantiles(lat, n=100)[94] if len(lat) >= 2 else (lat[0] if lat else 0)
        out[api] = {"n": len(rows), "avail": 100.0 * len(ok) / len(rows),
                    "perf": 100.0 * len(good) / len(rows), "p95": p95, "slo": slo}
    return out


def load_nodes(outdir):
    try:
        ns = [int(l.split(",")[1]) for l in open(os.path.join(outdir, "nodes.csv")) if l.strip()]
    except FileNotFoundError:
        ns = []
    return ns


# ---------- 라이브 상태 (kubectl) ----------
def usage_from_window(outdir):
    """{앱: {p95, max, n}} — loadtest 가 부하 중 5초마다 남긴 podcpu.csv 에서 계산.

    request 권장값의 근거는 반드시 '부하 창 전체' 여야 한다. 부하가 끝난 뒤 kubectl top 을
    한 번 찍는 방식은 찍히는 순간에 따라 값이 요동친다:
      실측 사고 — 실사용이 132m 인데 스파이크 순간에 400m 로 읽혀 request 300m 를 권고했다.
    p95 를 기준으로 삼는 이유: 최대값 하나는 단발 스파이크에 끌려가고, 평균은 피크를 놓친다.
    """
    f = os.path.join(outdir, "podcpu.csv")
    if not os.path.exists(f):
        return {}
    per = {}
    try:
        for line in open(f, encoding="utf-8", errors="replace"):
            c = line.strip().split(",")
            if len(c) < 3:
                continue
            app = c[1].rsplit("-", 2)[0]
            try:
                v = int(c[2])
            except ValueError:
                continue
            per.setdefault(app, []).append(v)
    except OSError:
        return {}
    out = {}
    for app, vals in per.items():
        vals.sort()
        out[app] = {"p95": pct_nearest(vals, 95), "max": vals[-1], "n": len(vals)}
    return out


def pod_usage_live(ns):
    """{앱: 파드 CPU(밀리코어)} — 지금 순간값 1회. podcpu.csv 가 없을 때만 쓰는 폴백.

    순간값은 스파이크/휴지에 그대로 끌려가므로 request 산정 근거로는 약하다. 호출부에서
    이 값을 쓸 때 경고를 출력한다.
    """
    peak = {}
    out = run(["kubectl", "-n", ns, "top", "pods", "--no-headers"])
    for line in out.splitlines():
        f = line.split()
        if len(f) < 2:
            continue
        app = f[0].rsplit("-", 2)[0]
        v = cpu_m(f[1])
        if v is None:
            continue
        if v > peak.get(app, 0):
            peak[app] = v
    return peak


def node_cpu_max():
    """노드 실사용 CPU 최대치(%) — '노드 경쟁' 판단용. 못 읽으면 None."""
    mx = None
    for line in run(["kubectl", "top", "nodes", "--no-headers"]).splitlines():
        for tok in line.split():
            if tok.endswith("%"):
                try:
                    v = int(tok[:-1])
                except ValueError:
                    continue
                if mx is None or v > mx:
                    mx = v
                break
    return mx


def node_alloc_m():
    """노드 1대의 할당가능 CPU(밀리코어). 여러 타입이 섞이면 '가장 작은 노드' 기준.

    대회날 인스턴스 타입이 바뀔 수 있으므로 상수를 쓰지 않고 라이브에서 읽는다.
    작은 쪽을 쓰는 이유: 노드 수를 과소추정하지 않기 위해서다.
    """
    vals = []
    data = json.loads(run(["kubectl", "get", "nodes", "-o", "json"]) or "{}")
    for it in data.get("items", []):
        c = (it.get("status", {}).get("allocatable", {}) or {}).get("cpu")
        v = cpu_m(c) if c else None
        if v:
            vals.append(v)
    return min(vals) if vals else 0


def node_types():
    """노드 타입 구성 문자열 (추정 근거 표시용)."""
    m = {}
    data = json.loads(run(["kubectl", "get", "nodes", "-o", "json"]) or "{}")
    for it in data.get("items", []):
        lab = it.get("metadata", {}).get("labels", {})
        k = lab.get("node.kubernetes.io/instance-type", "?")
        m[k] = m.get(k, 0) + 1
    return ", ".join("%s x%d" % (k, v) for k, v in sorted(m.items())) or "-"

def live_state(ns):
    """앱별 {cpu(밀리코어), util, min, max, cur(현재CPU%)}; kubectl 실패 시 {}"""
    state = {}
    try:
        deps = json.loads(run(["kubectl", "-n", ns, "get", "deploy", "-o", "json"]) or "{}")
        for it in deps.get("items", []):
            name = it["metadata"]["name"]
            for c in it["spec"]["template"]["spec"]["containers"]:
                req = (c.get("resources", {}).get("requests", {}) or {}).get("cpu")
                if req:
                    state.setdefault(name, {})["cpu"] = cpu_m(req)
                    break
        hpas = json.loads(run(["kubectl", "-n", ns, "get", "hpa", "-o", "json"]) or "{}")
        for it in hpas.get("items", []):
            name = it["metadata"]["name"]
            sp, st = it.get("spec", {}), it.get("status", {})
            d = state.setdefault(name, {})
            d["min"], d["max"] = sp.get("minReplicas"), sp.get("maxReplicas")
            for m in sp.get("metrics") or []:
                r = m.get("resource", {})
                if r.get("name") == "cpu":
                    d["util"] = r.get("target", {}).get("averageUtilization")
            for m in st.get("currentMetrics") or []:
                r = m.get("resource", {})
                if r.get("name") == "cpu":
                    d["cur"] = r.get("current", {}).get("averageUtilization")
            d["replicas"] = st.get("currentReplicas")
    except Exception:
        pass
    return state


# ---------- 판정 ----------
def judge(m, cur, peak_m=None, node_cpu=None):
    """(방향, 원인, 권장 cpu/util/min/max, 근거, 다음확인) 을 돌려준다.

    m       : 측정 {avail, perf, p95, slo}
    cur     : 현재 설정 {cpu, util, min, max, replicas, cur}
    peak_m  : 이 앱 파드의 실사용 CPU 피크(밀리코어) — request 판단의 핵심 근거
    node_cpu: 노드 실사용 CPU 최대치(%) — '노드 경쟁' 여부

    핵심: request 는 예약량이지 속도 상한이 아니다. 그래서 '느리다'만으로 올리지 않고,
    노드 경쟁 / 파드 상한 / 스케일 지연 / CPU 병목 아님 을 먼저 가른다.
    """
    cpu = cur.get("cpu") or 200
    util = cur.get("util") or 70
    mn = cur.get("min") or 2
    mx = cur.get("max") or 10
    rep = cur.get("replicas") or mn
    curp = cur.get("cur")
    fit = right_size(peak_m)
    at_max = bool(mx) and rep >= mx
    nc = node_cpu if node_cpu is not None else -1

    if m is None:
        return ("관측필요", "측정 없음", cpu, util, mn, mx,
                "측정 데이터 없음 - loadtest 먼저", "")
    if peak_m is None:
        return ("관측필요", "실사용 측정 불가", cpu, util, mn, mx,
                "파드 CPU 실측이 없다(metrics-server). 실사용 없이 request 판단은 추측이 된다",
                "kubectl top pods 가 되는지 확인")

    bad_avail = m["avail"] < 99
    bad_perf = m["perf"] < 95 or m["p95"] > m["slo"]

    if bad_avail:
        # 가용성 실패는 보통 파드 수 부족/롤아웃이지 request 부족이 아니다 -> request 유지
        if at_max:
            return ("늘려", "파드 상한 도달", cpu, util, mn, mx + 2,
                    f"avail {m['avail']:.1f}% < 99 이고 파드가 상한 {mx}개에 붙었다. 더 못 늘려 실패한 것",
                    "부하 중 롤아웃이 있었는지도 확인(롤아웃 자체가 504 를 만든다)")
        return ("늘려", "파드 부족/스케일 지연", cpu, max(40, util - 10), mn + 1, mx,
                f"avail {m['avail']:.1f}% < 99. 상한엔 안 붙었으니 초기 여유(min)와 스케일 속도(util) 문제",
                "부하 중 롤아웃이 있었는지도 확인(롤아웃 자체가 504 를 만든다)")

    if bad_perf:
        if at_max:
            return ("늘려", "파드 상한 도달", cpu, util, mn, mx + 2,
                    f"p95 {m['p95']:.3f}s > SLO {m['slo']}s 인데 파드가 상한 {mx}개다. request 를 올리면 사용률이 낮아져 스케일이 더 늦어진다",
                    "")
        if nc >= 80:
            return ("늘려", "노드 CPU 포화", max(cpu, fit or cpu), util, mn, mx,
                    f"노드 실사용 CPU {nc}%. 파드를 늘려도 같은 노드에서 경쟁한다. 이 경우에만 request 상향이 유효(노드당 파드↓, cpu.shares↑)",
                    "노드를 늘리는 쪽이 더 직접적이다. Karpenter limits.cpu 와 노드그룹 크기를 함께 본다")
        if peak_m < cpu * 0.5:
            return ("유지", "CPU 병목 아님", cpu, util, mn, mx,
                    f"p95 {m['p95']:.3f}s > SLO 인데 실사용 피크 {peak_m}m 이 request {cpu}m 의 절반도 안 된다"
                    + (f", 노드도 {nc}%" if nc >= 0 else "") + ". CPU 가 병목이 아니라 request 를 올려도 안 나아진다(노드만 늘어 비용 손실)",
                    "DB(RDS CPU/커넥션/쿼리지연), CloudFront 캐시 히트율, 커넥션풀 borrow 대기, 외부 호출 지연을 본다")
        if curp is not None and curp < util:
            return ("늘려", "스케일 지연", cpu, max(40, util - 15), mn + 1, mx,
                    f"p95 초과인데 현재 사용률 {curp}% 가 목표 {util}% 아래다 = HPA 가 아직 안 늘린 상태에서 지연 발생",
                    "")
        return ("늘려", "파드 CPU 포화", fit or cpu, util, mn, mx,
                f"실사용 피크 {peak_m}m 이 request {cpu}m 에 근접/초과, 노드는 여유. 피크x1.3 = {fit}m 으로 맞춘다",
                "")

    # 성능·가용성 통과 -> 비용 관점
    if fit and fit < cpu * 0.9:
        return ("줄여", "과투자", fit, util, mn, mx,
                f"통과(perf {m['perf']:.1f}%, avail {m['avail']:.1f}%). 실사용 피크 {peak_m}m 인데 request {cpu}m 로 과예약 -> 예약이 곧 노드 수",
                "")
    return ("유지", "균형", cpu, util, mn, mx,
            f"통과(perf {m['perf']:.1f}%, avail {m['avail']:.1f}%, p95 {m['p95']:.3f}s), request {cpu}m 가 실사용 피크 {peak_m}m 대비 적정",
            "")


def main():
    # Windows cp949 콘솔에서 특수문자로 죽지 않게 (표현 불가 문자는 ? 로)
    try:
        sys.stdout.reconfigure(errors="replace")
    except Exception:
        pass
    ap = argparse.ArgumentParser(description="loadtest 결과 → 앱별 권장값 + 복붙 명령")
    ap.add_argument("target", help="loadtest label 또는 결과 폴더 경로")
    ap.add_argument("--slos", default="user=0.2,product=0.2,stress=1.0")
    ap.add_argument("--ns", default="app")
    ap.add_argument("--default-slo", type=float, default=DEFAULT_SLO,
                    help="--slos 에 없는 앱에 쓸 SLO(초). 대회날 새 앱이 나와도 죽지 않게 하는 폴백")
    a = ap.parse_args()

    outdir = a.target
    if not os.path.isdir(outdir):
        outdir = os.path.join(os.environ.get("TEMP", "/tmp"), "tune-" + a.target)
    if not os.path.isdir(outdir):
        sys.exit(f"결과 폴더 없음: {outdir} — .\\loadtest.ps1 <ep> 180s <label> 먼저")

    slos = {kv.split("=")[0]: float(kv.split("=")[1]) for kv in a.slos.split(",") if kv}
    # 앱 목록을 결과 CSV 에서 만든다(하드코딩 금지). --slos 에 없는 앱은 기본 SLO + 경고.
    apps, assumed = discover_apps(outdir, slos)
    for name in apps:
        slos.setdefault(name, a.default_slo)
    meas = load_measures(outdir, {k: slos[k] for k in apps})
    live = live_state(a.ns)
    # request 산정 근거: 부하 창 전체(podcpu.csv) 를 1순위로 쓴다. 순간값은 스파이크에
    # 끌려가 과대/과소 권고를 만든다(실측: 132m 를 400m 로 읽어 request 300m 권고).
    win = usage_from_window(outdir)
    if win:
        peaks = {k: v["p95"] for k, v in win.items()}
        basis = "부하 창 p95 (podcpu.csv)"
    else:
        peaks = pod_usage_live(a.ns)
        basis = "지금 순간값 1회 [!] 근거 약함"
    node_cpu = node_cpu_max()        # 노드 실사용 CPU 최대 % (노드 경쟁 판단)
    alloc_m = node_alloc_m()         # 노드 할당가능 CPU (0 이면 추정 생략)
    ntypes = node_types()
    have_live = bool(live)

    print("\n" + "=" * 72)
    print("  앱별 권장값 (측정: %s%s)" % (outdir, "" if have_live else " · [!] kubectl 조회 실패 - 현재값은 기본 가정"))
    print("  노드: %s · 할당가능 %s (라이브)   노드CPU최대: %s" % (
        ntypes,
        ("%dm/대" % alloc_m) if alloc_m else "미확인(추정 생략)",
        ("%d%%" % node_cpu) if node_cpu is not None else "미확인"))
    print("  실사용 근거: %s" % basis)
    if not win:
        print("      podcpu.csv 가 없다. 최신 loadtest.ps1 로 다시 측정하면 부하 창 p95 로 판정한다")
    if assumed:
        print("  [!] SLO 미지정 앱: %s -> %.2fs 로 가정했다. 문제지 SLO 로 --slos 를 지정할 것"
              % (", ".join(assumed), a.default_slo))
    if not peaks:
        print("  [!] 파드 CPU 실측 없음(metrics-server?) - request 권장은 보류된다")
    print("=" * 72)

    tf_lines = []
    sum_cpu = 0
    for api in apps:
        cur = live.get(api, {})
        peak = peaks.get(api)
        d, cause, rcpu, rutil, rmn, rmx, why, nextchk = judge(meas.get(api), cur, peak, node_cpu)
        cpu, util = cur.get("cpu") or "?", cur.get("util") or "?"
        mn, mx = cur.get("min") or "?", cur.get("max") or 10
        mark = {"늘려": "↑", "줄여": "↓", "유지": "=", "관측필요": "?"}[d]
        print(f"\n[{api}]  판정: {d} {mark}  원인: {cause}")
        print(f"  현재: cpu={cpu}{'m' if cpu != '?' else ''} util={util}% min={mn} max={mx}"
              + (f" 파드={cur.get('replicas')}" if cur.get("replicas") else ""))
        w = win.get(api)
        if w:
            print(f"  실사용: p95 {w['p95']}m · 최대 {w['max']}m · 표본 {w['n']}개"
                  + (f" · 적정 request {right_size(peak)}m" if peak else ""))
        else:
            print(f"  실사용: {peak if peak is not None else '-'}m (순간값)"
                  + (f" · 적정 request {right_size(peak)}m" if peak else ""))
        print(f"  근거: {why}")
        if nextchk:
            print(f"  다음 확인: {nextchk}")
        if d == "유지" and cause == "CPU 병목 아님":
            print("  [!] request 를 올리지 않는다 - 올리면 HPA 사용률이 낮아져 스케일업이 늦어지고 노드만 늘어난다")
        changed = (cur.get("cpu") != rcpu) or (cur.get("util") != rutil) or (cur.get("min") != rmn) or (cur.get("max") != rmx)
        if d in ("유지", "관측필요") or not changed:
            print("  → 변경 없음")
            sum_cpu += (cur.get("min") or 2) * (cur.get("cpu") or 200)
            continue
        print(f"  권장: cpu={rcpu}m util={rutil}% min={rmn} max={rmx}")
        patch = json.dumps({"spec": {"minReplicas": rmn, "maxReplicas": rmx if rmx != "?" else 10,
                                     "metrics": [{"type": "Resource", "resource": {"name": "cpu",
                                                  "target": {"type": "Utilization", "averageUtilization": rutil}}}]}},
                           separators=(",", ":"))
        # PowerShell 은 네이티브 exe 로 넘길 때 큰따옴표를 벗겨버려서 -p '{"spec":...}' 가
        # kubectl 에 {spec:...} 로 도착한다 → "invalid character 's' looking for beginning
        # of object key string". 큰따옴표를 \" 로 이스케이프하면 그대로 전달된다.
        patch_ps = patch.replace('"', '\\"')
        req_changed = cur.get("cpu") != rcpu
        print("  즉시 적용 (임시 - apply 하면 사라짐):")
        if req_changed:
            # requests 변경은 파드 롤아웃을 유발한다 = 부하 중이면 504 위험
            print(f"    [주의] 아래 set resources 는 롤아웃을 일으킨다. 부하 측정 중이면 HPA 만 먼저 적용할 것")
            print(f"    kubectl -n {a.ns} set resources deploy/{api} --requests=cpu={rcpu}m")
        print(f"    kubectl -n {a.ns} patch hpa {api} --type=merge -p '{patch_ps}'")
        if req_changed:
            print(f"    kubectl -n {a.ns} rollout status deploy/{api}")
        tf_lines.append(f"  {api:8}: requests.cpu = \"{rcpu}m\"   average_utilization = {rutil}   min_replicas = {rmn}   max_replicas = {rmx}")
        sum_cpu += rmn * rcpu

    ns_hist = load_nodes(outdir)
    est = -(-sum_cpu // alloc_m) if (sum_cpu and alloc_m) else 0  # ceil, 노드 할당량은 라이브 값
    print("\n" + "-" * 72)
    if ns_hist:
        line = (f"  측정 중 노드: min={min(ns_hist)} max={max(ns_hist)} "
                f"avg={sum(ns_hist)/len(ns_hist):.2f}")
        if alloc_m and est:
            line += f"   (권장 min 반영 시 정상부하 노드 추정 ~ {est})"
        else:
            line += "   (노드 할당가능 CPU 미확인 -> 노드 추정 생략)"
        print(line)
        print(f"  비용 비율: {sum(ns_hist)/len(ns_hist)/BASELINE_NODES:.2f}배 (기준 {BASELINE_NODES:g}대)")
    if tf_lines:
        print("  영구 반영 → terraform/k8s_apps.tf 해당 앱 수정 후:")
        for l in tf_lines:
            print(l)
        print("    cd ..\\terraform ; terraform apply -auto-approve")
    else:
        print("  변경 권장 없음 — 현 설정 유지.")
    print("  검증: 적용 후  .\\loadtest.ps1 <ep> 180s after  로 재측정 (한 번에 한 앱만 바꾸면 원인 추적 쉬움)")
    print("-" * 72)


if __name__ == "__main__":
    main()
