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
  --slos         : 생략 시 user=0.2,product=0.2,stress=1.0
  (loadtest.ps1 이 끝에서 자동 호출하므로 보통 직접 칠 일은 없다)

판정 기준 (채점 순서와 동일한 우선순위):
  1) avail < 99%          → 늘려(게이트): cpu×1.5, min+1, util−5   ← 비용보다 무조건 먼저
  2) perf < 95% 또는 p95 > SLO → 늘려: cpu×1.4, util−10 (꼬리지연)
  3) perf ≥ 99.5% 이고 현재CPU ≪ 목표 (또는 p95 ≤ SLO×0.4) → 줄여: cpu×0.75, util+10 (과투자→비용↓)
  4) 그 외 → 유지
"""
import argparse
import csv
import json
import os
import statistics
import subprocess
import sys

ALLOC_M = 1900  # t3.medium 할당 가능 CPU (밀리코어) — 노드 수 추정용
# 비용 기준선 노드 수 (config.ps1 의 $COST_BASELINE_NODES). terraform node_desired_size 와 동일.
BASELINE_NODES = float(os.environ.get("TUNE_BASELINE_NODES", "1"))


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


# ---------- 측정값 (loadtest CSV) ----------
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
def judge(m, cur):
    """(방향, 권장 cpu/util/min, 근거) — m: 측정, cur: 현재 설정."""
    cpu = cur.get("cpu") or 200
    util = cur.get("util") or 60
    mn = cur.get("min") or 2
    curp = cur.get("cur")  # 현재 CPU 사용률(%)
    if m is None:
        return ("관측필요", cpu, util, mn, "측정 데이터 없음 — loadtest 먼저")
    if m["avail"] < 99:
        return ("늘려", round50(cpu * 1.5), max(40, util - 5), mn + 1,
                f"avail {m['avail']:.1f}% < 99 (게이트) — 용량부터, 비용은 나중")
    if m["perf"] < 95 or m["p95"] > m["slo"]:
        return ("늘려", round50(cpu * 1.4), max(40, util - 10), mn,
                f"perf {m['perf']:.1f}% / p95 {m['p95']:.3f}s > SLO {m['slo']}s (꼬리지연)")
    over = (curp is not None and curp < max(15, util * 0.4)) or (curp is None and m["p95"] <= m["slo"] * 0.4)
    if m["perf"] >= 99.5 and over:
        return ("줄여", round50(cpu * 0.75), min(75, util + 10), max(2, mn - 1) if mn > 2 else mn,
                f"perf {m['perf']:.1f}% 여유 + 현재CPU {curp if curp is not None else '낮음'}% ≪ 목표 {util}% (과투자)")
    return ("유지", cpu, util, mn,
            f"균형 (perf {m['perf']:.1f}%, avail {m['avail']:.1f}%, p95 {m['p95']:.3f}s)")


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
    a = ap.parse_args()

    outdir = a.target
    if not os.path.isdir(outdir):
        outdir = os.path.join(os.environ.get("TEMP", "/tmp"), "tune-" + a.target)
    if not os.path.isdir(outdir):
        sys.exit(f"결과 폴더 없음: {outdir} — .\\loadtest.ps1 <ep> 180s <label> 먼저")

    slos = {kv.split("=")[0]: float(kv.split("=")[1]) for kv in a.slos.split(",") if kv}
    meas = load_measures(outdir, slos)
    live = live_state(a.ns)
    have_live = bool(live)

    print("\n" + "=" * 72)
    print("  앱별 권장값 (측정: %s%s)" % (outdir, "" if have_live else " · [!] kubectl 조회 실패 - 현재값은 기본 가정"))
    print("=" * 72)

    tf_lines = []
    sum_cpu = 0
    for api in slos:
        cur = live.get(api, {})
        d, rcpu, rutil, rmn, why = judge(meas.get(api), cur)
        cpu, util = cur.get("cpu") or "?", cur.get("util") or "?"
        mn, mx = cur.get("min") or "?", cur.get("max") or 10
        mark = {"늘려": "↑", "줄여": "↓", "유지": "=", "관측필요": "?"}[d]
        print(f"\n[{api}]  판정: {d} {mark}   ({why})")
        print(f"  현재: cpu={cpu}{'m' if cpu != '?' else ''} util={util}% min={mn} max={mx}"
              + (f" 파드={cur.get('replicas')}" if cur.get("replicas") else ""))
        changed = (cur.get("cpu") != rcpu) or (cur.get("util") != rutil) or (cur.get("min") != rmn)
        if d in ("유지", "관측필요") or not changed:
            print("  → 변경 없음")
            sum_cpu += (cur.get("min") or 2) * (cur.get("cpu") or 200)
            continue
        print(f"  권장: cpu={rcpu}m util={rutil}% min={rmn} max={mx}")
        patch = json.dumps({"spec": {"minReplicas": rmn, "maxReplicas": mx if mx != "?" else 10,
                                     "metrics": [{"type": "Resource", "resource": {"name": "cpu",
                                                  "target": {"type": "Utilization", "averageUtilization": rutil}}}]}},
                           separators=(",", ":"))
        print("  즉시 적용 (임시 - 재배포 시 사라짐):")
        print(f"    kubectl -n {a.ns} set resources deploy/{api} --requests=cpu={rcpu}m")
        print(f"    kubectl -n {a.ns} patch hpa {api} --type=merge -p '{patch}'")
        print(f"    kubectl -n {a.ns} rollout status deploy/{api}")
        tf_lines.append(f"  {api:8}: requests.cpu = \"{rcpu}m\"   average_utilization = {rutil}   min_replicas = {rmn}")
        sum_cpu += rmn * rcpu

    ns_hist = load_nodes(outdir)
    est = -(-sum_cpu // ALLOC_M) if sum_cpu else 0  # ceil
    print("\n" + "-" * 72)
    if ns_hist:
        print(f"  측정 중 노드: min={min(ns_hist)} max={max(ns_hist)} avg={sum(ns_hist)/len(ns_hist):.2f}"
              f"   (권장 min 반영 시 정상부하 노드 추정 ≈ {est})")
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
