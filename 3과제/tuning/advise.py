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
import time

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


# 채점 구간(가용성/성능 공통). 넘을 때마다 0.5점. score.py 의 RATE_BANDS 와 같아야 한다.
RATE_BANDS = [90.0, 87.5, 85.0, 82.5, 80.0, 70.0, 50.0, 30.0]


# 비용 구간(채점기준). ratio 가 각 상한 이하일 때마다 1점 (누적 최대 12점).
COST_LIMITS = [1.00, 1.25, 1.50, 1.75, 2.00, 2.25, 2.50, 2.75, 3.00, 3.25, 3.50, 3.75]
COST_RATIO_FLOOR = 0.50


def cost_points_of(ratio):
    """cost ratio -> 비용 점수(하한 미달이면 0)."""
    if ratio < COST_RATIO_FLOOR:
        return 0
    return sum(1 for lim in COST_LIMITS if ratio <= lim)


def node_budget(target_points, base_nodes):
    """비용 N점을 받으려면 노드 평균이 몇 대 이하여야 하나.

    채점기준이 고정이므로 이 역산은 앱·트래픽이 바뀌어도 그대로 유효하다.
    반환: (허용 ratio, 허용 노드 평균)
    """
    cands = [lim for lim in COST_LIMITS if cost_points_of(lim) >= target_points]
    if not cands or not base_nodes:
        return None, None
    ratio = max(cands)          # 그 점수를 받는 가장 느슨한 상한
    return ratio, ratio * base_nodes


def max_pods_in_budget(nodes_allowed, alloc_m, sys_m, reqs, usage, app=None):
    """비용 예산을 앱들에게 나눠 각 앱의 max_replicas 를 정한다.

    max_replicas 를 임의 숫자로 두면 안 되는 이유: HPA 는 부하가 요구하면 상한까지 파드를
    만들고 Karpenter 가 노드를 공급한다. 즉 '천장이 곧 비용'이다.
      실측: max 6 -> 비용 8점(ratio 1.91) / max 30 -> 비용 4점(ratio 2.81).
            성능 +0.5 를 얻고 비용 -4.0 을 잃어 순손실이었다.

    ⚠ 예산은 '클러스터 전체' 하나다. 앱마다 '나 혼자 예산을 다 쓴다'고 계산하면
    앱 수만큼 초과한다(실측: 3개 앱이 각자 43/130/21 로 계산되어 예산의 3.0배).
    그래서 앱의 '실제 CPU 수요 비중'으로 예산을 쪼갠 뒤 각자의 request 로 나눈다.

    reqs  : {앱: request(m)}
    usage : {앱: 부하 중 실사용 기준값(m)}  — 비중 계산에 쓴다. 없으면 request 로 대체.
    반환  : app 을 주면 그 앱의 max, 안 주면 {앱: max}
    """
    if not (nodes_allowed and alloc_m and reqs):
        return None
    budget = alloc_m * nodes_allowed - sys_m
    if budget <= 0:
        return None
    # 비중: 실사용이 있으면 실사용, 없으면 request 기준
    w = {a: (usage.get(a) or reqs.get(a) or 0) for a in reqs}
    tot_w = sum(w.values())
    out = {}
    for a, q in reqs.items():
        if not q:
            continue
        share = (budget * (w[a] / tot_w)) if tot_w else (budget / len(reqs))
        out[a] = max(1, int(share // q))
    return out.get(app) if app else out


def band_of(v):
    """현재 값이 몇 점인지(0.5 단위)."""
    return 0.5 * sum(1 for b in RATE_BANDS if v >= b)


def next_band(v):
    """(다음 구간 값, 그때까지 필요한 %p). 이미 최상위면 (None, None).

    구간 사이에는 점수가 없다. 70.0~80.0 처럼 넓은 죽은 구간이 있어서
    79.9% 는 70.1% 와 같은 점수다. '조금 나아짐'이 점수로 안 바뀌므로,
    개선 노력은 반드시 '다음 구간'을 넘기는 것을 목표로 해야 한다.
    """
    below = [b for b in RATE_BANDS if b > v]
    if not below:
        return None, None
    tgt = min(below)
    return tgt, round(tgt - v, 2)


def right_size(base_m):
    """권장 request = 기준 사용량 x 1.2, 25m 단위 상향, 하한 50m.

    기준값으로 p95 를 쓰지 않는 이유(실측):
      stress 의 분포가 p50 382m / p95 1064m / max 1343m 로 꼬리가 두꺼웠다.
      p95x1.3 = 1400m 을 권고하면 파드 하나가 t3.medium 의 70% 를 예약해 노드가 폭증한다.
      p95 는 개별 파드가 어쩌다 도달하는 값이고 모든 파드가 동시에 그 값을 쓰지 않는다
      (동시 총사용량 실측: stress 10파드 합계 3.6코어 = 파드당 평균 360m).
    HPA 가 있으면 총 예약량은 '총실사용 / target%' 로 수렴하므로 request 는 노드 수를
    좌우하지 않고 '파드 크기'만 정한다. 그래서 전형값(p90)에 얇은 헤드룸만 얹는다.
    request 가 실사용보다 지나치게 작을 때만 문제가 되는데(사용률이 수백 % 로 튀어
    HPA 가 max 에 붙어 평형에 도달하지 못한다), p90x1.2 면 그 구간을 피한다.
    """
    if not base_m:
        return None
    return max(50, -(-int(base_m * 1.2) // 25) * 25)


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
    """노드 수 표본. 0(= kubectl 조회 실패)은 제외한다.

    노드 0대는 존재하지 않는다. 0 을 평균에 섞으면 비용 비율이 실제보다 낮게 나와
    비용 점수를 과대평가한다(실측: 40% 가 0 이라 1.14배로 보였지만 실제 1.91배).
    """
    try:
        ns = [int(l.split(",")[1]) for l in open(os.path.join(outdir, "nodes.csv")) if l.strip()]
    except FileNotFoundError:
        ns = []
    return [v for v in ns if v > 0]


# ---------- 라이브 상태 (kubectl) ----------
def usage_from_window(outdir, apps=None):
    """{앱: {p50, p90, p95, max, n}} — 부하 중 5초마다 남긴 podcpu.csv 에서 계산.

    apps 를 주면 그 목록에 있는 앱만 집계한다. podcpu.csv 는 네임스페이스의 '모든' 파드를
    담기 때문에, 진단용으로 띄운 파드까지 앱으로 잡힌다(실측: latprobe 라는 앱이 생겼다).
    대회날에도 디버그 파드·Job·사이드카가 있으면 같은 오염이 생긴다.

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
            if apps is not None and app not in apps:
                continue  # 측정 대상 앱이 아닌 파드(진단용 등)는 버린다
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
        out[app] = {"p50": pct_nearest(vals, 50), "p90": pct_nearest(vals, 90),
                    "p95": pct_nearest(vals, 95), "max": vals[-1], "n": len(vals)}
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


def system_cpu_req(ns):
    """app 네임스페이스 밖(kube-system 등) 파드의 CPU request 합계(밀리코어).

    min_replicas 상한을 계산할 때 노드 용량에서 먼저 빼야 하는 몫이다.
    """
    tot = 0
    data = json.loads(run(["kubectl", "get", "pods", "-A", "-o", "json"]) or "{}")
    for p in data.get("items", []):
        md, st = p.get("metadata", {}), p.get("status", {})
        if md.get("namespace") == ns or st.get("phase") != "Running":
            continue
        for c in p.get("spec", {}).get("containers", []):
            v = (c.get("resources", {}).get("requests", {}) or {}).get("cpu")
            m = cpu_m(v) if v else None
            if m:
                tot += m
    return tot


def min_headroom_per_app(alloc_m, nodes, sys_m, reqs, usage):
    """앱별로 '노드를 늘리지 않는' min 상한을 나눠 준다.

    모든 앱에 같은 min 을 가정하면 가장 무거운 앱 때문에 전체 상한이 낮아져 기회를 잃는다
    (실측: product 는 성능 만점이라 min 2 로 충분한데 stress 300m 때문에 전체가 5 로 묶였다).
    예산을 실사용 비중으로 쪼개면 앱마다 필요한 만큼 올릴 수 있다.
    """
    if not (alloc_m and nodes and reqs):
        return {}, None
    avail = alloc_m * nodes - sys_m
    if avail <= 0:
        return {}, avail
    w = {a: (usage.get(a) or reqs.get(a) or 0) for a in reqs}
    tot = sum(w.values())
    out = {}
    for a, q in reqs.items():
        if not q:
            continue
        share = (avail * (w[a] / tot)) if tot else (avail / len(reqs))
        out[a] = max(1, int(share // q))
    return out, avail


def fits_per_node(req_m, alloc_m, sys_per_node_m=400):
    """request 가 노드당 몇 개 들어가나. 1 이면 '노드당 파드 1개'라 사실상 노드 전용이다."""
    if not (req_m and alloc_m):
        return None
    return max(0, int((alloc_m - sys_per_node_m) // req_m))


def min_headroom(alloc_m, nodes, sys_m, reqs):
    """'노드를 늘리지 않고' 각 앱 min 을 몇 개까지 올릴 수 있나.

    min 을 올리면 트래픽이 계단처럼 들어올 때의 HPA 램프 구간이 사라진다(실측: min 2 -> 8
    까지 1분 45초. 그 구간의 지연/실패가 누적 로그에 그대로 박힌다). 공짜는 아니지만,
    아래 부등식 안에서는 노드가 늘지 않으므로 비용이 그대로다:

        sum(min_i x request_i) + 시스템요청  <=  노드수 x 노드당 할당가능

    반환: (앱마다 동일하게 줄 수 있는 최대 min, 여유 밀리코어)
    앱별 request 가 다르면 '모든 앱을 같은 수로' 올릴 때의 상한이다(보수적).
    """
    if not alloc_m or not nodes or not reqs:
        return None, None
    avail = alloc_m * nodes - sys_m
    per_set = sum(reqs.values())
    if per_set <= 0:
        return None, avail
    return max(1, avail // per_set), avail


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


# ---------- 회차 이력 (max 판단에 필요) ----------
# "파드를 늘리면 성능이 좋아지는가"는 한 회차만 보면 알 수 없다. 이전 회차보다 파드가
# 많았는데 성능이 나아지지 않았다면, max 를 더 열어도 노드만 늘고 점수는 그대로다.
#   실측(stress): 5개 76.9% -> 7개 75.0% 로 오히려 하락. 초당 1건 트래픽이라 p95 는
#   동시성이 아니라 '단건 처리 시간'이 결정하기 때문이다.
# 그래서 회차마다 (앱, 파드수, perf) 를 남겨 두고 다음 판정에서 참고한다.
HIST_PATH = os.path.join(os.environ.get("TEMP", "/tmp"), "tune-history.jsonl")


def hist_append(label, app, replicas, perf, avail, p95, ratio=None, nodes_avg=None):
    try:
        with open(HIST_PATH, "a", encoding="utf-8") as f:
            f.write(json.dumps({"ts": int(time.time()), "label": label, "app": app,
                                "replicas": replicas, "perf": perf, "avail": avail,
                                "p95": p95, "ratio": ratio, "nodes_avg": nodes_avg},
                               ensure_ascii=False) + "\n")
    except OSError:
        pass


def hist_runs():
    """회차별로 묶어 (label, {앱: (perf, avail)}, ratio) 를 돌려준다.

    성능과 비용은 서로 교환 관계라 '어느 방향이 이득인가'는 한 회차만 보면 알 수 없다.
    회차들을 모아 실제 채점 총점으로 줄세우면 측정된 최적점이 드러난다.
    """
    runs = {}
    try:
        for line in open(HIST_PATH, encoding="utf-8", errors="replace"):
            try:
                d = json.loads(line)
            except ValueError:
                continue
            lb = d.get("label")
            if not lb or d.get("perf") is None:
                continue
            r = runs.setdefault(lb, {"perf": {}, "avail": {}, "ratio": None, "nodes": None})
            r["perf"][d["app"]] = d["perf"]
            r["avail"][d["app"]] = d.get("avail")
            if d.get("ratio"):
                r["ratio"] = d["ratio"]
            if d.get("nodes_avg"):
                r["nodes"] = d["nodes_avg"]
    except OSError:
        return {}
    return runs


def run_total(perf, avail, ratio):
    """회차의 채점 소계(비정상요청 4점 제외). score.py 의 rubric 과 같은 규칙."""
    if not perf or not avail or not ratio:
        return None
    bad = [a for a, v in perf.items() if v < 30.0]
    cp = 0 if bad else cost_points_of(ratio)
    return sum(band_of(v) for v in avail.values()) + sum(band_of(v) for v in perf.values()) + cp


def hist_load(app, limit=12):
    out = []
    try:
        for line in open(HIST_PATH, encoding="utf-8", errors="replace"):
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if d.get("app") == app:
                out.append(d)
    except OSError:
        return []
    return out[-limit:]


def pods_helped(app, cur_replicas, cur_perf):
    """더 많은 파드가 성능에 도움이 됐나? (도움됨 / 무의미 / 판단불가)

    반환: (verdict, 근거문자열)
      "no"      : 과거에 더 많은 파드로 돌렸는데 perf 가 나아지지 않았다 -> max 를 더 열지 말 것
      "yes"     : 파드가 많을 때 perf 가 유의하게 높았다
      "unknown" : 비교할 이력이 없다
    """
    h = [d for d in hist_load(app) if d.get("replicas") and d.get("perf") is not None]
    more = [d for d in h if d["replicas"] > cur_replicas]
    if not more:
        return "unknown", ""
    best = max(more, key=lambda d: d["perf"])
    if best["perf"] <= cur_perf + 1.0:      # 1%p 이내면 개선 없음으로 본다
        return "no", "과거 파드 %d개에서 perf %.1f%% (현재 %d개 %.1f%%) - 파드를 늘려도 개선 없음" % (
            best["replicas"], best["perf"], cur_replicas, cur_perf)
    return "yes", "과거 파드 %d개에서 perf %.1f%% (현재 %d개 %.1f%%)" % (
        best["replicas"], best["perf"], cur_replicas, cur_perf)


# ---------- 판정 ----------
def keep_req_note(s):
    """request 를 그대로 두는 판정의 근거 문구."""
    return s


def judge(m, cur, peak_m=None, node_cpu=None, pods_verdict=("unknown", "")):
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
            # 상한이 병목이면 +2 로는 부족한 경우가 많다. 50% 증량(최소 +2).
            # HPA 는 '총실사용/target%' 로 평형을 찾는데 max 에 막히면 평형에 도달하지 못해
            # 파드마다 과부하가 걸린 채로 지연이 난다. 여유를 충분히 줘야 평형이 잡힌다.
            newmx = max(mx + 2, int(mx * 1.5))
            return ("늘려", "파드 상한 도달", cpu, util, mn, newmx,
                    f"avail {m['avail']:.1f}% < 99 이고 파드가 상한 {mx}개에 붙었다. 더 못 늘려 실패한 것",
                    "부하 중 롤아웃이 있었는지도 확인(롤아웃 자체가 504 를 만든다)")
        return ("늘려", "파드 부족/스케일 지연", cpu, max(40, util - 10), mn + 1, mx,
                f"avail {m['avail']:.1f}% < 99. 상한엔 안 붙었으니 초기 여유(min)와 스케일 속도(util) 문제",
                "부하 중 롤아웃이 있었는지도 확인(롤아웃 자체가 504 를 만든다)")

    if bad_perf:
        if at_max:
            pv, pwhy = pods_verdict
            if pv == "no":
                # 파드를 늘려도 성능이 안 나아진 이력이 있으면 max 를 더 열지 않는다.
                # 열어두면 노드만 늘어 비용을 깎고 점수는 그대로다.
                #   실측(stress): 5개 76.9% -> 7개 75.0%. 초당 1건 트래픽이라 p95 는
                #   동시성이 아니라 '단건 처리 시간'이 결정하기 때문이다.
                capped = max(mn + 1, min(mx, rep))
                return ("유지 (max 묶기)", "파드 증설 무효", cpu, util, mn, capped,
                        f"p95 {m['p95']:.3f}s > SLO {m['slo']}s 이지만 {pwhy}. 파드/노드를 더 쓰면 비용만 늘어난다",
                        "단건 처리 시간이 병목이면 파드 수로는 못 고친다. 앱 처리 경로(DB/외부호출/캐시)를 본다")
            # 상한이 병목이면 +2 로는 부족한 경우가 많다. 50% 증량(최소 +2).
            # HPA 는 '총실사용/target%' 로 평형을 찾는데 max 에 막히면 평형에 도달하지 못해
            # 파드마다 과부하가 걸린 채로 지연이 난다. 여유를 충분히 줘야 평형이 잡힌다.
            newmx = max(mx + 2, int(mx * 1.5))
            return ("늘려", "파드 상한 도달", cpu, util, mn, newmx,
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
        # curp(HPA 현재 사용률)가 0 이면 '부하가 없는 지금 시점'을 읽은 것이다.
        # 측정은 과거 창(부하 중)인데 curp 는 라이브 스냅샷이라 시점이 다르다.
        # 0 을 근거로 목표를 내리면 근거 없이 25% 같은 값이 나온다(실측 사고).
        # 부하 중 실사용(peak_m)과 request 로 '측정 창의 사용률'을 복원해 쓴다.
        util_measured = None
        if peak_m and cpu:
            util_measured = int(round(100.0 * peak_m / cpu))
        eff = util_measured if (curp is None or curp <= 0) else curp
        if eff is not None and eff < util:
            # 이 분기가 'CPU 기반 HPA 가 안 맞는 앱'을 다루는 곳이다.
            # user 처럼 요청 시간의 대부분이 대기(DB/외부호출)인 앱은 지연이 나빠도 CPU 는
            # 안 올라간다. 목표를 70% 로 두면 HPA 가 가만히 있는다(실측: 64%/70%, SLA 59.7%).
            # 정공법은 응답시간 기반 스케일링이지만 ALB TargetResponseTime 은 CloudWatch
            # 경유라 1~3분 지연이 있어, 손실이 몰리는 '스파이크 진입 3~4분'에는 이미 늦다.
            # 그래서 실효 수단은 '목표를 실측 사용률 아래로 내려' HPA 가 반응하게 만드는 것이다.
            # 현재 사용률보다 확실히 낮게(10%p 아래) 잡아야 즉시 반응한다. 하한 25%.
            newutil = max(25, min(util - 15, eff - 10))
            src = "HPA 현재" if (curp and curp > 0) else "부하 창 실사용/request 로 복원"
            return ("늘려", "스케일 지연 (CPU 기반 HPA 부적합)", cpu, newutil, mn + 1, mx,
                    f"p95 초과인데 사용률 {eff}%({src}) 가 목표 {util}% 아래다 = HPA 가 안 늘리는 상태에서 지연 발생. "
                    f"대기 위주 앱이면 CPU 사용률이 부하를 대표하지 못한다 -> 목표를 {newutil}% 로 내려 반응하게 만든다",
                    "목표를 내려도 안 되면 응답시간 기반 스케일링(KEDA + CloudWatch)을 검토하되, CloudWatch 지연(1~3분) 때문에 진입 구간은 min 상향으로 덮어야 한다")
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
    ap.add_argument("--cost-points", type=int, default=8,
                    help="비용에서 최소 몇 점을 확보할지(1~12). 이 예산에서 노드 상한과 "
                         "max_replicas 를 역산한다. 채점기준이 고정이라 앱이 바뀌어도 유효하다.")
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
    win = usage_from_window(outdir, set(apps))
    if win:
        # 기준은 p90. p95/max 는 참고로만 보여준다(꼬리 1회에 권고가 끌려가지 않게).
        peaks = {k: v["p90"] for k, v in win.items()}
        basis = "부하 창 p90 (podcpu.csv, 앱 파드만)"
    else:
        peaks = pod_usage_live(a.ns)
        basis = "지금 순간값 1회 [!] 근거 약함"
    node_cpu = node_cpu_max()        # 노드 실사용 CPU 최대 % (노드 경쟁 판단)
    alloc_m = node_alloc_m()         # 노드 할당가능 CPU (0 이면 추정 생략)
    ntypes = node_types()
    # '노드를 늘리지 않고' 올릴 수 있는 min 상한. 트래픽이 계단으로 들어올 때
    # HPA 램프 구간을 없애는 가장 값싼 수단이다.
    base_nodes = int(BASELINE_NODES) if BASELINE_NODES else 0
    sys_m = system_cpu_req(a.ns)
    reqs_now = {k: v.get("cpu") for k, v in live.items() if v.get("cpu")}
    min_cap, avail_m = min_headroom(alloc_m, base_nodes, sys_m, reqs_now)
    # 비용 예산 -> 허용 노드 -> 앱별 max_replicas 역산
    ns_hist_pre = load_nodes(outdir)
    nodes_avg = (sum(ns_hist_pre) / len(ns_hist_pre)) if ns_hist_pre else None
    ratio_now = (nodes_avg / BASELINE_NODES) if (nodes_avg and BASELINE_NODES) else None
    budget_ratio, budget_nodes = node_budget(a.cost_points, base_nodes)
    # 예산 분배 비중에 쓸 '앱별 실사용 기준값'. 부하 창 p90 이 있으면 그것을 쓴다.
    usage_base = {k: (win[k]["p90"] if k in win else peaks.get(k)) for k in set(list(peaks) + list(win))}
    # 앱별 min 상한(균등 가정이 아니라 실사용 비중으로 분배)
    min_cap_app, _ = min_headroom_per_app(alloc_m, base_nodes, sys_m, reqs_now, usage_base)
    have_live = bool(live)

    print("\n" + "=" * 72)
    print("  앱별 권장값 (측정: %s%s)" % (outdir, "" if have_live else " · [!] kubectl 조회 실패 - 현재값은 기본 가정"))
    print("  노드: %s · 할당가능 %s (라이브)   노드CPU최대: %s" % (
        ntypes,
        ("%dm/대" % alloc_m) if alloc_m else "미확인(추정 생략)",
        ("%d%%" % node_cpu) if node_cpu is not None else "미확인"))
    print("  실사용 근거: %s" % basis)
    if ratio_now:
        cp = cost_points_of(ratio_now)
        print("  비용 현황: 노드 평균 %.2f대 -> ratio %.2f -> %d/12점" % (nodes_avg, ratio_now, cp))
        print("      [가정] ratio 분모(기준 %g대)는 node_desired_size 로 가정한 값이다."
              % BASELINE_NODES)
        print("             채점기준의 '인스턴스 비용 ratio' 기준값 정의가 문제지에 없으므로,"
              " 실제 채점기가 다른 기준을 쓰면 이 점수는 어긋난다.")
        if budget_nodes:
            print("      목표 %d점을 받으려면 노드 평균 %.1f대 이하 (ratio <= %.2f)"
                  % (a.cost_points, budget_nodes, budget_ratio))
    if min_cap:
        cur_min = sum((v.get("min") or 0) for v in live.values())
        print("  min 여유: 기준 %d노드(%dm) - 시스템 %dm = %dm 여유"
              % (base_nodes, alloc_m * base_nodes, sys_m, avail_m))
        print("      -> 균등 기준: 각 앱 min 최대 %d (현재 합계 %d)" % (min_cap, cur_min))
        if min_cap_app:
            detail = ", ".join("%s %d" % (a, v) for a, v in sorted(min_cap_app.items()))
            print("      -> 실사용 비중 배분: %s   (무거운 앱 때문에 전체가 묶이지 않게)" % detail)
        print("         트래픽이 계단처럼 들어오면 HPA 램프(실측 1분 45초)가 그대로 실패로 잡힌다.")
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
        mm = meas.get(api)
        rep_now = cur.get("replicas") or cur.get("min") or 0
        pv = pods_helped(api, rep_now, mm["perf"]) if (mm and rep_now) else ("unknown", "")
        d, cause, rcpu, rutil, rmn, rmx, why, nextchk = judge(mm, cur, peak, node_cpu, pv)
        if mm and rep_now:
            hist_append(os.path.basename(outdir), api, rep_now, mm["perf"], mm["avail"],
                        mm["p95"], ratio_now, nodes_avg)
        cpu, util = cur.get("cpu") or "?", cur.get("util") or "?"
        mn, mx = cur.get("min") or "?", cur.get("max") or 10
        mark = {"늘려": "↑", "줄여": "↓", "유지": "=", "관측필요": "?"}[d]
        print(f"\n[{api}]  판정: {d} {mark}  원인: {cause}")
        print(f"  현재: cpu={cpu}{'m' if cpu != '?' else ''} util={util}% min={mn} max={mx}"
              + (f" 파드={cur.get('replicas')}" if cur.get("replicas") else ""))
        w = win.get(api)
        if w:
            print(f"  실사용: p50 {w['p50']}m · p90 {w['p90']}m · p95 {w['p95']}m · 최대 {w['max']}m"
                  f" · 표본 {w['n']}개"
                  + (f" · 적정 request {right_size(peak)}m (p90x1.2)" if peak else ""))
        else:
            print(f"  실사용: {peak if peak is not None else '-'}m (순간값)"
                  + (f" · 적정 request {right_size(peak)}m" if peak else ""))
        if mm:
            for label, val in (("perf", mm["perf"]), ("avail", mm["avail"])):
                nb, gap = next_band(val)
                cur_pt = band_of(val)
                if nb is None:
                    print(f"  {label:5} {val:5.1f}% -> {cur_pt:.1f}/4.0 (최상위 구간)")
                else:
                    print(f"  {label:5} {val:5.1f}% -> {cur_pt:.1f}/4.0   다음 구간 {nb}% 까지 +{gap}%p (넘기면 +0.5점)")
            if pv[0] != "unknown":
                print(f"  파드 효과: {pv[1]}")
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
        # max 는 비용 예산에서 역산한 값으로 덮는다. HPA 는 부하가 요구하면 상한까지
        # 파드를 만들고 Karpenter 가 노드를 공급하므로 '천장이 곧 비용'이다.
        # 예산을 세 앱에 나눈 뒤 이 앱 몫으로 상한을 계산한다.
        # 이 앱의 request 는 권장값(rcpu)을 반영해야 하므로 사본에 덮어쓴다.
        reqs_for_cap = dict(reqs_now)
        reqs_for_cap[api] = rcpu
        # request 가 너무 커서 노드당 1개밖에 안 들어가면 노드를 전용으로 먹는다 -> 비용 폭증.
        fpn = fits_per_node(rcpu, alloc_m)
        if fpn is not None and fpn <= 1 and rcpu > (cur.get("cpu") or 0):
            safe = max(50, int((alloc_m - 400) // 2 // 25) * 25)
            print(f"  [!] request {rcpu}m 는 노드당 {fpn}개만 들어간다(노드 전용화) -> {safe}m 로 제한")
            rcpu = safe
        cap = max_pods_in_budget(budget_nodes, alloc_m, sys_m, reqs_for_cap, usage_base, api)
        if cap and rmx > cap:
            print(f"  [!] max {rmx} 는 비용 예산({a.cost_points}점, 노드 {budget_nodes:.1f}대)을 넘긴다"
                  f" -> max {cap} 로 제한 (request {rcpu}m 기준)")
            rmx = cap
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
    # ---- 회차 비교: 성능과 비용은 교환 관계라 총점으로 줄세워야 방향이 보인다 ----
    runs = hist_runs()
    scored = []
    for lb, r in runs.items():
        tot = run_total(r["perf"], r["avail"], r["ratio"])
        if tot is not None:
            scored.append((tot, lb, r))
    if len(scored) >= 2:
        scored.sort(reverse=True)
        print("")
        print("  회차 비교 (채점 소계 = 가용성+성능+비용, 비정상요청 4점 제외)")
        print("  %-16s %7s %7s %7s %7s  %s" % ("회차", "가용성", "성능", "비용", "소계", "노드평균"))
        for tot, lb, r in scored:
            av = sum(band_of(v) for v in r["avail"].values() if v is not None)
            pf = sum(band_of(v) for v in r["perf"].values())
            cp = cost_points_of(r["ratio"]) if r["ratio"] else 0
            mark = "  <== 최고" if (tot, lb, r) == scored[0] else ""
            print("  %-16s %7.1f %7.1f %7.1f %7.1f  %8s%s"
                  % (lb, av, pf, cp, tot, ("%.2f" % r["nodes"]) if r["nodes"] else "-", mark))
        best = scored[0]
        print("")
        print("  성능 1구간(+0.5)과 비용 1구간(+1.0)의 교환비를 보십시오.")
        print("  비용 구간은 노드 평균 0.5대마다 1점입니다 — 성능 한 구간보다 크게 움직입니다.")
        # 지금 상태에서 각 방향의 기대 점수를 실제로 계산해 나란히 보여준다.
        if ratio_now and meas:
            perf_now = {k: v["perf"] for k, v in meas.items() if v}
            avail_now = {k: v["avail"] for k, v in meas.items() if v}
            base_tot = run_total(perf_now, avail_now, ratio_now)
            print("")
            print("  지금 소계 %.1f점. 각 방향의 기대치:" % base_tot)
            # 비용만 개선
            for step in (0.5, 1.0, 1.5):
                nn = max(0.1, nodes_avg - step)
                r2 = nn / BASELINE_NODES
                tot = run_total(perf_now, avail_now, r2)
                print("    노드 평균 -%.1f대 (%.2f -> %.2f대, ratio %.2f) -> %.1f점  (%+.1f)"
                      % (step, nodes_avg, nn, r2, tot, tot - base_tot))
            # 성능만 개선: 각 앱을 다음 구간까지 올렸을 때
            for app, mv in sorted(meas.items()):
                if not mv:
                    continue
                nb, gap = next_band(mv["perf"])
                if nb is None:
                    continue
                p2 = dict(perf_now)
                p2[app] = nb
                tot = run_total(p2, avail_now, ratio_now)
                print("    %s perf %.1f%% -> %.1f%% (+%.2f%%p) -> %.1f점  (%+.1f)"
                      % (app, mv["perf"], nb, gap, tot, tot - base_tot))
        if best[2]["nodes"]:
            print("  최고 회차 '%s' 의 노드 평균은 %.2f대였습니다." % (best[1], best[2]["nodes"]))
    print("  검증: 적용 후  .\\loadtest.ps1 <ep> 180s after  로 재측정 (한 번에 한 앱만 바꾸면 원인 추적 쉬움)")
    print("-" * 72)


if __name__ == "__main__":
    main()
