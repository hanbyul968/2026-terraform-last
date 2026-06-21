#!/usr/bin/env python3
"""3과제 모니터링 대시보드 (단일 파일 · 표준 라이브러리만).

수집원:
  - kubectl : pods/nodes/hpa/deploy + top(리소스) + logs(앱 JSON 액세스로그)
  - aws logs: WAF 블락(403) 로그 (CloudWatch, 로깅 활성화된 경우)

보여주는 것: 앱/Pod별 요청·리소스·개수·오류원인, 노드 수·리소스,
요청 block/allow, 2xx/4xx/5xx 카운트 + 최근요청(상태별), 4xx/5xx 원인·해결.

실행: python3 monitor.py [--port 8080] [--namespace app] [--waf-log-group ...] [--waf-region ap-northeast-2]
요구: kubectl(현재 컨텍스트=대상 EKS), aws CLI, python3
"""
import argparse, json, subprocess, time, re
from collections import Counter
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

APPS = ("user", "product", "stress")
SLO_MS = {"user": 200, "product": 200, "stress": 1000}
CFG = {"ns": "app", "waf_group": "aws-waf-logs-wsi2026", "waf_region": "ap-northeast-2"}


def run(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace").stdout or ""
    except Exception:
        return ""


def kjson(args):
    try:
        return json.loads(run(["kubectl"] + args + ["-o", "json"]) or "{}")
    except Exception:
        return {}


def pctl(v, q):
    if not v:
        return 0
    s = sorted(v)
    return s[min(len(s) - 1, int(round(q / 100.0 * (len(s) - 1))))]


def cls(st):
    return "2" if 200 <= st < 300 else "4" if 400 <= st < 500 else "5" if st >= 500 else "x"


# ----------------------- 앱 액세스 로그 -----------------------
def parse_rec(line):
    line = line.strip()
    if not line or line[0] != "{":
        return None
    try:
        d = json.loads(line)
    except Exception:
        return None

    def g(*ks):
        for k in ks:
            if k in d and d[k] not in (None, ""):
                return d[k]
        return None

    st = g("status", "code", "status_code", "resp_status")
    try:
        st = int(st)
    except Exception:
        return None
    dur = g("dur_ms", "duration_ms", "latency_ms", "took_ms", "elapsed_ms")
    if dur is None:
        sec = g("dur_s", "duration", "latency", "elapsed")
        try:
            dur = float(sec) * 1000 if sec is not None else None
        except Exception:
            dur = None
    try:
        dur = float(dur) if dur is not None else None
    except Exception:
        dur = None
    return {"status": st,
            "path": (str(g("path", "uri", "url", "route") or "")).split("?")[0],
            "method": str(g("method", "verb") or ""),
            "dur": dur,
            "ip": str(g("client_ip", "ip", "remote_addr", "remoteIp", "x_forwarded_for") or "?"),
            "ts": str(g("ts", "time", "timestamp", "@timestamp") or "")}


def collect_app(app, since):
    out = run(["kubectl", "logs", "-n", CFG["ns"], "-l", "app=" + app,
               "--since=" + since, "--tail=-1", "--prefix=false"])
    recs = []
    for ln in out.splitlines():
        r = parse_rec(ln)
        if r:
            recs.append(r)
    return recs


def app_detail(app, since):
    recs = collect_app(app, since)
    ur = [r for r in recs if r["path"] != "/healthcheck"]
    total = len(ur)
    c = Counter(cls(r["status"]) for r in ur)
    durs = [r["dur"] for r in ur if isinstance(r["dur"], (int, float))]
    slo = SLO_MS.get(app, 200)
    within = sum(1 for d in durs if d <= slo)

    def recent(k, n=50):
        rows = [{"ts": (r["ts"][11:23] if len(r["ts"]) >= 19 else r["ts"]),
                 "m": r["method"], "path": r["path"], "st": r["status"],
                 "dur": round(r["dur"]) if isinstance(r["dur"], (int, float)) else "-",
                 "ip": r["ip"]} for r in ur if cls(r["status"]) == k]
        return rows[-n:][::-1]

    return {"app": app, "total": total, "hc": len(recs) - total,
            "c2": c["2"], "c4": c["4"], "c5": c["5"],
            "ok_rate": round(100.0 * c["2"] / total, 1) if total else 0,
            "err_rate": round(100.0 * (c["4"] + c["5"]) / total, 1) if total else 0,
            "status": dict(sorted(Counter(r["status"] for r in ur).items())),
            "slo_ms": slo, "slo_rate": round(100.0 * within / len(durs), 1) if durs else 0,
            "p50": pctl(durs, 50), "p95": pctl(durs, 95), "p99": pctl(durs, 99),
            "max": round(max(durs)) if durs else 0,
            "paths": Counter(r["path"] for r in ur).most_common(10),
            "err_paths": Counter((r["path"], r["status"]) for r in ur if cls(r["status"]) in ("4", "5")).most_common(10),
            "top_ips": Counter(r["ip"] for r in ur).most_common(8),
            "recent2": recent("2"), "recent4": recent("4"), "recent5": recent("5")}


# ----------------------- Pod / 노드 / HPA -----------------------
def top_map(args):
    m = {}
    for ln in run(["kubectl", "top"] + args + ["--no-headers"]).splitlines():
        x = ln.split()
        if x:
            m[x[0]] = x[1:]
    return m


def pods_detail():
    ns = CFG["ns"]
    tp = top_map(["pods", "-n", ns])
    out = []
    for it in kjson(["get", "pods", "-n", ns]).get("items", []):
        md = it["metadata"]
        st = it.get("status", {})
        name = md["name"]
        restarts = 0
        reason = ""
        ready = False
        for csx in st.get("containerStatuses", []) or []:
            restarts += csx.get("restartCount", 0)
            ready = ready or csx.get("ready", False)
            state = csx.get("state", {})
            last = csx.get("lastState", {})
            if "waiting" in state:
                reason = state["waiting"].get("reason", "") or reason
            elif "terminated" in state:
                reason = state["terminated"].get("reason", "") or reason
            if not reason and "terminated" in last:
                reason = last["terminated"].get("reason", "")
            msg = ""
            if "terminated" in last:
                msg = (last["terminated"].get("message", "") or "")[:160]
            if msg:
                reason = (reason + " : " + msg).strip(" :")
        t = tp.get(name, [])
        out.append({"name": name, "app": md.get("labels", {}).get("app", "-"),
                    "phase": st.get("phase", "?"), "ready": ready, "restarts": restarts,
                    "reason": reason, "node": (it.get("spec", {}).get("nodeName") or "-"),
                    "cpu": t[0] if len(t) > 0 else "-", "mem": t[1] if len(t) > 1 else "-"})
    return out


def nodes_detail():
    tp = top_map(["nodes"])
    out = []
    for it in kjson(["get", "nodes"]).get("items", []):
        md = it["metadata"]
        lab = md.get("labels", {})
        name = md["name"]
        ready = "?"
        for cc in it.get("status", {}).get("conditions", []):
            if cc.get("type") == "Ready":
                ready = "Ready" if cc.get("status") == "True" else "NotReady"
        t = tp.get(name, [])
        out.append({"name": name, "type": lab.get("node.kubernetes.io/instance-type", "?"),
                    "karpenter": "karpenter.sh/nodepool" in lab, "ready": ready,
                    "cpu": t[0] if len(t) > 0 else "-", "cpu_pct": t[1] if len(t) > 1 else "-",
                    "mem": t[2] if len(t) > 2 else "-", "mem_pct": t[3] if len(t) > 3 else "-"})
    return out


def hpa_detail():
    ns = CFG["ns"]
    out = []
    for it in kjson(["get", "hpa", "-n", ns]).get("items", []):
        sp = it.get("spec", {})
        st = it.get("status", {})
        cur = "-"
        for m in st.get("currentMetrics") or []:
            if m.get("resource", {}).get("name") == "cpu":
                cur = str(m["resource"].get("current", {}).get("averageUtilization", "?")) + "%"
        tgt = "-"
        for m in sp.get("metrics") or []:
            if m.get("resource", {}).get("name") == "cpu":
                tgt = str(m["resource"].get("target", {}).get("averageUtilization", "?")) + "%"
        out.append({"name": it["metadata"]["name"], "cur": cur, "tgt": tgt,
                    "min": sp.get("minReplicas"), "max": sp.get("maxReplicas"),
                    "replicas": st.get("currentReplicas")})
    return out


# ----------------------- WAF 블락 -----------------------
def _g(e, *k):
    x = e
    for kk in k:
        x = x.get(kk, {}) if isinstance(x, dict) else {}
    return x if x not in ({}, None) else "?"


def waf_detail(minutes):
    grp = CFG["waf_group"]
    region = CFG["waf_region"]
    chk = run(["aws", "logs", "describe-log-groups", "--log-group-name-prefix", grp,
               "--region", region, "--output", "json"])
    exists = False
    try:
        exists = any(g.get("logGroupName") == grp for g in json.loads(chk or "{}").get("logGroups", []))
    except Exception:
        pass
    if not exists:
        return {"enabled": False, "total": 0, "by_rule": [], "by_ip": [], "by_uri": [], "by_method": [], "recent": []}
    start = int((time.time() - minutes * 60) * 1000)
    ev = []
    tok = None
    for _ in range(20):
        cmd = ["aws", "logs", "filter-log-events", "--log-group-name", grp, "--region", region,
               "--start-time", str(start), "--limit", "10000", "--output", "json"]
        if tok:
            cmd += ["--next-token", tok]
        out = run(cmd)
        if not out:
            break
        try:
            data = json.loads(out)
        except Exception:
            break
        for e in data.get("events", []):
            try:
                ev.append(json.loads(e["message"]))
            except Exception:
                pass
        tok = data.get("nextToken")
        if not tok:
            break
    recent = [{"ts": datetime.fromtimestamp(e.get("timestamp", 0) / 1000, timezone.utc).astimezone().strftime("%H:%M:%S"),
               "ip": _g(e, "httpRequest", "clientIp"), "m": _g(e, "httpRequest", "httpMethod"),
               "uri": _g(e, "httpRequest", "uri"), "rule": e.get("terminatingRuleId", "?")} for e in ev[-60:]][::-1]
    return {"enabled": True, "total": len(ev),
            "by_rule": Counter(e.get("terminatingRuleId", "?") for e in ev).most_common(10),
            "by_ip": Counter(_g(e, "httpRequest", "clientIp") for e in ev).most_common(10),
            "by_uri": Counter(_g(e, "httpRequest", "uri") for e in ev).most_common(10),
            "by_method": Counter(_g(e, "httpRequest", "httpMethod") for e in ev).most_common(),
            "recent": recent}
# ----------------------- 진단(원인·해결) -----------------------
POD_REASONS = {
    "CrashLoopBackOff": ("컨테이너가 시작 직후 반복 종료됨",
        "kubectl -n app logs <pod> --previous 로 원인 확인. 흔한 원인: 바이너리 실행권한(exec /app: permission denied)→빌드 시 chmod +x, DB 접속 실패(secret/host), 필수 env 누락."),
    "ImagePullBackOff": ("이미지 풀 실패",
        "ECR 이미지/태그 존재 확인. build_push 가 정상 push 됐는지, app_image_tag/이미지 경로 확인."),
    "ErrImagePull": ("이미지 풀 실패", "ECR 이미지 경로/권한/태그 확인."),
    "OOMKilled": ("메모리 한도 초과로 강제 종료",
        "해당 Deployment resources.limits.memory 상향 (terraform/k8s_apps.tf) 후 apply."),
    "CreateContainerConfigError": ("컨테이너 설정 오류(Secret/ConfigMap 누락)",
        "참조하는 Secret/ConfigMap 존재 확인: kubectl -n app get secret,cm."),
    "Pending": ("스케줄 불가(자원 부족 등)",
        "kubectl -n app describe pod <pod> 의 Events 확인. Insufficient cpu 면 Karpenter 노드 증설 대기 또는 요청량/HPA 조정."),
}


def diagnose(apps, pods, waf):
    out = []
    for p in pods:
        key = None
        for r in POD_REASONS:
            if r in (p["reason"] or ""):
                key = r
                break
        if not key and p["phase"] == "Pending" and not p["ready"]:
            key = "Pending"
        if not key and p["restarts"] >= 3 and not p["ready"]:
            key = "CrashLoopBackOff"
        if key:
            why, fix = POD_REASONS[key]
            detail = why + (("\n현재 상태: " + p["reason"]) if p["reason"] else "")
            out.append(["bad", p["app"] + "/" + p["name"] + " · " + key, detail, fix])
    for a in apps:
        if a["total"] == 0:
            continue
        if a["c5"] > 0:
            tops = ", ".join(str(s) + "×" + str(c) for (pp, s), c in a["err_paths"] if str(s).startswith("5")) or "-"
            out.append(["bad", a["app"] + " · 5xx " + str(a["c5"]) + "건",
                        "서버/DB 오류 또는 정상 타깃 없음(503=헬시 Pod 없음). 앱이 죽었거나 RDS 접속/쿼리 실패 가능. (" + tops + ")",
                        "kubectl -n app get pods | grep " + a["app"] + " 로 Pod 상태 → 죽었으면 위 Pod 진단 참고. 503이면 readiness 실패/타깃그룹 미등록 확인, 500이면 logs deploy/" + a["app"] + " 와 RDS 접속·테이블 확인."])
        if a["c4"] and a["total"] and 100.0 * a["c4"] / a["total"] >= 5:
            out.append(["warn", a["app"] + " · 4xx " + str(a["c4"]) + "건 (" + str(round(100.0 * a["c4"] / a["total"], 1)) + "%)",
                        "400=요청 형식 오류(JSON/필드 누락) · 404=미정의 경로 또는 데이터 미적재. 아래 '에러 경로' 표에서 어떤 경로/상태인지 확인.",
                        "정상 요청인데 404면 load_user.dump 적재 확인. 400이면 클라이언트 본문/Content-Type 확인. 미정의 경로 404는 정상(WAF/ALB 설계)."])
        if a["slo_rate"] < 90:
            out.append(["warn", a["app"] + " · 성능 SLO " + str(a["slo_rate"]) + "% (목표 ≤" + str(a["slo_ms"]) + "ms, p99 " + str(a["p99"]) + "ms)",
                        "부하 대비 CPU/replica 부족으로 꼬리지연 발생.",
                        a["app"] + " requests.cpu↑ 또는 HPA averageUtilization↓ / min↑ (terraform/k8s_apps.tf) 후 apply. 급하면 kubectl -n app scale deploy/" + a["app"] + " --replicas=N."])
    if waf.get("enabled") and waf.get("total"):
        legit = any(re.match(r"^/(v1/(user|product|stress)|healthcheck)$", (u[0] or "")) for u in waf["by_uri"])
        if legit:
            out.append(["warn", "WAF가 정상 경로 차단 의심 (" + str(waf["total"]) + "건)",
                        "정상 /v1/* 가 403 차단되면 가용성 점수↓.",
                        "해당 룰을 waf.tf 에서 count 또는 예외(override)로 완화 후 apply."])
        else:
            out.append(["good", "WAF 정상 차단 (" + str(waf["total"]) + "건)", "비정상 요청만 403 차단 중. 정상 경로 차단 없음.", ""])
    if not waf.get("enabled"):
        out.append(["dim", "WAF 로깅 미설정", "WAF 블락(403) 데이터가 없습니다. CloudWatch 로그그룹(" + CFG["waf_group"] + ")이 없어요.",
                    "terraform waf.tf 에 aws_cloudwatch_log_group + aws_wafv2_web_acl_logging_configuration 추가 후 apply. 또는 --waf-log-group 으로 실제 그룹 지정."])
    if not out:
        out.append(["good", "이상 없음", "모든 Pod 정상, HTTP 오류/지연 문제 없음.", ""])
    return out


def build_data(since, waf_minutes):
    apps = [app_detail(a, since) for a in APPS]
    pods = pods_detail()
    nodes = nodes_detail()
    hpa = hpa_detail()
    waf = waf_detail(waf_minutes)
    allow_total = sum(a["total"] for a in apps)
    summary = {"allow": allow_total, "block": waf.get("total", 0),
               "c2": sum(a["c2"] for a in apps), "c4": sum(a["c4"] for a in apps),
               "c5": sum(a["c5"] for a in apps),
               "pods_total": len(pods), "pods_ready": sum(1 for p in pods if p["ready"]),
               "nodes_total": len(nodes), "nodes_karp": sum(1 for n in nodes if n["karpenter"])}
    return {"apps": apps, "pods": pods, "nodes": nodes, "hpa": hpa, "waf": waf,
            "summary": summary, "diag": diagnose(apps, pods, waf),
            "ts": datetime.now(timezone.utc).astimezone().strftime("%H:%M:%S")}
# ----------------------- 웹 UI -----------------------
HTML = r"""<!doctype html><html lang="ko"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>3과제 모니터링</title>
<style>
:root{--bg:#070b14;--panel:#0f1626;--panel2:#131c30;--line:#1f2c44;--muted:#7e93b4;--txt:#e8eefb}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--txt);font-family:'Segoe UI','Malgun Gothic',sans-serif;font-size:14px}
header{background:rgba(10,16,28,.9);border-bottom:1px solid var(--line);padding:12px 22px;display:flex;gap:16px;align-items:center;position:sticky;top:0;z-index:10}
header h1{font-size:16px;margin:0;font-weight:600}
.ctl{color:var(--muted);font-size:13px;display:flex;gap:6px;align-items:center}
select,button{background:var(--panel2);color:var(--txt);border:1px solid var(--line);border-radius:8px;padding:6px 11px;font-size:13px;cursor:pointer}
#st{margin-left:auto;font-size:12px;color:var(--muted)}.dot{width:7px;height:7px;border-radius:50%;display:inline-block;margin-right:6px}
nav{display:flex;gap:4px;padding:12px 22px 0;flex-wrap:wrap}
.tab{padding:8px 16px;border-radius:9px 9px 0 0;color:var(--muted);cursor:pointer;border:1px solid transparent;font-size:13px}
.tab.on{background:var(--panel);border-color:var(--line);border-bottom-color:var(--panel);color:var(--txt)}
main{padding:16px 22px 50px}.grid{display:grid;gap:14px}
.g2{grid-template-columns:repeat(auto-fit,minmax(420px,1fr))}.g3{grid-template-columns:repeat(auto-fit,minmax(300px,1fr))}
.g4{grid-template-columns:repeat(auto-fit,minmax(200px,1fr))}
.card{background:linear-gradient(180deg,var(--panel),var(--panel2));border:1px solid var(--line);border-radius:13px;padding:16px}
.card h2{margin:0 0 12px;font-size:14px;font-weight:600;color:#cdd9ef}
.lbl{font-size:11px;color:var(--muted);text-transform:uppercase;letter-spacing:.7px;margin-bottom:5px}
.kpi{font-size:30px;font-weight:700;line-height:1}.kpi.sm{font-size:20px}
.row{display:flex;justify-content:space-between;padding:5px 0;border-bottom:1px solid var(--line);font-size:13px}.row:last-child{border:0}
.good{color:#46e3a0}.warn{color:#ffcb57}.bad{color:#ff6b81}.muted{color:var(--muted)}
table{width:100%;border-collapse:collapse;font-size:12.5px}th,td{text-align:left;padding:5px 8px;border-bottom:1px solid var(--line)}
th{color:var(--muted);font-size:11px;text-transform:uppercase}td.n{text-align:right;font-variant-numeric:tabular-nums;color:var(--muted)}
.pill{padding:2px 8px;border-radius:20px;font-size:11px;font-weight:600}.p2{background:rgba(70,227,160,.15);color:#46e3a0}.p4{background:rgba(255,203,87,.15);color:#ffcb57}.p5{background:rgba(255,107,129,.15);color:#ff6b81}
.box{background:#060a12;border:1px solid var(--line);border-radius:10px;max-height:340px;overflow:auto}
.tip{border-left:3px solid;border-radius:9px;padding:12px 15px;background:var(--panel);margin-bottom:10px}
.tip.bad{border-color:#ff6b81}.tip.warn{border-color:#ffcb57}.tip.good{border-color:#46e3a0}.tip.dim{border-color:#3b4d70}
.tip h3{margin:0 0 5px;font-size:13.5px}.tip .why{color:#cdd9ef;font-size:13px;white-space:pre-wrap}
.tip pre{margin:7px 0 0;background:#060a12;border:1px solid var(--line);border-radius:7px;padding:9px 11px;font-size:12px;white-space:pre-wrap;color:#bcd0ef;overflow-x:auto}
.bar{height:7px;background:#0a1220;border-radius:5px;overflow:hidden;margin:7px 0}.bar>div{height:100%}
</style></head><body><header><h1>3과제 모니터링</h1>
<span class="ctl">기간 <select id="since"><option>5m</option><option selected>15m</option><option>30m</option><option>1h</option></select></span>
<span class="ctl">자동 <select id="auto"><option value="0">수동</option><option value="10" selected>10s</option><option value="30">30s</option></select></span>
<button onclick="load()">새로고침</button><span id="st"></span></header>
<nav id="tabs"></nav><main id="view"></main>
<script>
var D=null,TAB='overview';
function cr(v,g,w){return v>=g?'good':v>=w?'warn':'bad'}
function stp(s){s=''+s;var c=s[0]==='2'?'p2':s[0]==='4'?'p4':'p5';return '<span class="pill '+c+'">'+s+'</span>'}
function tbl(rows,cols){if(!rows||!rows.length)return '<div class=muted style="padding:8px">없음</div>';
 var h='<table><tr>'+cols.map(function(c){return '<th'+(c[2]?' style="text-align:right"':'')+'>'+c[0]+'</th>'}).join('')+'</tr>';
 return h+rows.map(function(r){return '<tr>'+cols.map(function(c){return '<td'+(c[2]?' class=n':'')+'>'+c[1](r)+'</td>'}).join('')+'</tr>'}).join('')+'</table>'}
function recTbl(rows){return '<div class=box>'+tbl(rows,[['시각',function(r){return r.ts}],['M',function(r){return r.m}],['경로',function(r){return r.path}],['상태',function(r){return stp(r.st)}],['ms',function(r){return r.dur},1],['IP',function(r){return r.ip}]])+'</div>'}

function appCard(a){var s=cr(a.slo_rate,90,70),o=cr(a.ok_rate,90,70);
 return '<div class=card><div class=lbl>'+a.app+'</div><div class="kpi '+s+'">'+a.slo_rate+'%<span class=muted style="font-size:12px"> SLO≤'+a.slo_ms+'ms</span></div>'
 +'<div class=bar><div class="'+s+'" style="width:'+a.slo_rate+'%;background:currentColor"></div></div>'
 +'<div class=row><span>요청수</span><b>'+a.total+'</b></div>'
 +'<div class=row><span>2xx / 4xx / 5xx</span><span><span class=good>'+a.c2+'</span> / <span class=warn>'+a.c4+'</span> / <span class=bad>'+a.c5+'</span></span></div>'
 +'<div class=row><span>성공률</span><span class="'+o+'">'+a.ok_rate+'%</span></div>'
 +'<div class=row><span>p50/p95/p99</span><span>'+a.p50+'/'+a.p95+'/'+a.p99+'ms</span></div></div>'}

function vOverview(){var s=D.summary;
 var k='<div class="grid g4">'
 +'<div class=card><div class=lbl>통과(allow)</div><div class="kpi good">'+s.allow+'</div></div>'
 +'<div class=card><div class=lbl>차단(block·403)</div><div class="kpi bad">'+s.block+'</div></div>'
 +'<div class=card><div class=lbl>2xx / 4xx / 5xx</div><div class="kpi sm"><span class=good>'+s.c2+'</span>/<span class=warn>'+s.c4+'</span>/<span class=bad>'+s.c5+'</span></div></div>'
 +'<div class=card><div class=lbl>Pod ready / 노드</div><div class="kpi sm">'+s.pods_ready+'/'+s.pods_total+' · '+s.nodes_total+'노드</div></div></div>';
 var cards='<div class="grid g3" style="margin-top:14px">'+D.apps.map(appCard).join('')+'</div>';
 var diag='<div class=lbl style="margin:20px 0 8px">진단 · 원인 & 해결</div>'+D.diag.map(function(t){return '<div class="tip '+t[0]+'"><h3>'+t[1]+'</h3><div class=why>'+t[2]+'</div>'+(t[3]?'<pre>'+t[3]+'</pre>':'')+'</div>'}).join('');
 return k+cards+diag}

function vApp(a){var s=cr(a.slo_rate,90,70),o=cr(a.ok_rate,90,70);
 var k='<div class="grid g4">'
 +'<div class=card><div class=lbl>SLO ≤'+a.slo_ms+'ms</div><div class="kpi '+s+'">'+a.slo_rate+'%</div></div>'
 +'<div class=card><div class=lbl>성공률 2xx</div><div class="kpi '+o+'">'+a.ok_rate+'%</div></div>'
 +'<div class=card><div class=lbl>요청수 (+hc)</div><div class="kpi sm">'+a.total+' <span class=muted style="font-size:13px">+'+a.hc+'</span></div></div>'
 +'<div class=card><div class=lbl>p99 / max</div><div class="kpi sm">'+a.p99+' / '+a.max+'ms</div></div></div>';
 var cnt='<div class="grid g3" style="margin-top:14px">'
 +'<div class=card><div class=lbl>2xx</div><div class="kpi good">'+a.c2+'</div></div>'
 +'<div class=card><div class=lbl>4xx</div><div class="kpi warn">'+a.c4+'</div></div>'
 +'<div class=card><div class=lbl>5xx</div><div class="kpi bad">'+a.c5+'</div></div></div>';
 var pth='<div class="grid g2" style="margin-top:14px"><div class=card><h2>경로별 요청</h2>'+tbl(a.paths,[['경로',function(r){return r[0]}],['건수',function(r){return r[1]},1]])+'</div>'
 +'<div class=card><h2>에러 경로 (4xx/5xx)</h2>'+tbl(a.err_paths,[['상태',function(r){return stp(r[0][1])}],['경로',function(r){return r[0][0]}],['건수',function(r){return r[1]},1]])+'</div></div>';
 var rec='<div class="grid g3" style="margin-top:14px">'
 +'<div class=card><h2 class=good>최근 2xx</h2>'+recTbl(a.recent2)+'</div>'
 +'<div class=card><h2 class=warn>최근 4xx</h2>'+recTbl(a.recent4)+'</div>'
 +'<div class=card><h2 class=bad>최근 5xx</h2>'+recTbl(a.recent5)+'</div></div>';
 return k+cnt+pth+rec}

function vPods(){return '<div class=card><h2>Pod ('+D.pods.length+'개)</h2><div class=box>'+tbl(D.pods,[
 ['app',function(r){return r.app}],['Pod',function(r){return r.name}],
 ['상태',function(r){return (r.phase==='Running'&&r.ready)?'<span class="pill p2">Running</span>':'<span class="pill p5">'+r.phase+(r.ready?'':'/NotReady')+'</span>'}],
 ['재시작',function(r){return r.restarts},1],['CPU',function(r){return r.cpu},1],['MEM',function(r){return r.mem},1],
 ['노드',function(r){return (r.node||'-').split('.')[0]}],['사유',function(r){return r.reason?'<span class=bad>'+r.reason+'</span>':'-'}]])+'</div></div>'}

function vNodes(){return '<div class=card><h2>노드 ('+D.nodes.length+'대)</h2>'+tbl(D.nodes,[
 ['노드',function(r){return r.name.split('.')[0]}],
 ['타입',function(r){return r.type+(r.karpenter?' <span class="pill p2">karpenter</span>':' <span class="pill p4">base</span>')}],
 ['상태',function(r){return r.ready==='Ready'?'<span class=good>Ready</span>':'<span class=bad>'+r.ready+'</span>'}],
 ['CPU',function(r){return r.cpu+' ('+r.cpu_pct+')'}],['MEM',function(r){return r.mem+' ('+r.mem_pct+')'}]])+'</div>'
 +'<div class=card style="margin-top:14px"><h2>HPA</h2>'+tbl(D.hpa,[['이름',function(r){return r.name}],['CPU 현재/목표',function(r){return r.cur+' / '+r.tgt}],['min/max',function(r){return r.min+' / '+r.max}],['replicas',function(r){return r.replicas},1]])+'</div>'}

function vWaf(){var w=D.waf;if(!w.enabled)return '<div class="tip dim"><h3>WAF 로깅이 켜져 있지 않음</h3><div class=why>CloudWatch 로그그룹이 없어 블락(403) 데이터를 못 가져옵니다.</div><pre>terraform waf.tf 에 로깅 추가(aws_cloudwatch_log_group + aws_wafv2_web_acl_logging_configuration) 후 apply\n또는: python3 monitor.py --waf-log-group <실제그룹명> --waf-region ap-northeast-2</pre></div>';
 var k='<div class="grid g3"><div class=card><div class=lbl>차단(403)</div><div class="kpi bad">'+w.total+'</div></div>'
 +'<div class=card><div class=lbl>통과(앱 도달)</div><div class="kpi good">'+D.summary.allow+'</div></div>'
 +'<div class=card><h2>차단 메서드</h2>'+tbl(w.by_method,[['M',function(r){return r[0]}],['건수',function(r){return r[1]},1]])+'</div></div>';
 var t='<div class="grid g3" style="margin-top:14px"><div class=card><h2>차단 룰</h2>'+tbl(w.by_rule,[['룰',function(r){return r[0]}],['건수',function(r){return r[1]},1]])+'</div>'
 +'<div class=card><h2>차단 IP</h2>'+tbl(w.by_ip,[['IP',function(r){return r[0]}],['건수',function(r){return r[1]},1]])+'</div>'
 +'<div class=card><h2>차단 URI</h2>'+tbl(w.by_uri,[['URI',function(r){return r[0]}],['건수',function(r){return r[1]},1]])+'</div></div>';
 var rec='<div class=card style="margin-top:14px"><h2>최근 차단</h2><div class=box>'+tbl(w.recent,[['시각',function(r){return r.ts}],['M',function(r){return r.m}],['URI',function(r){return r.uri}],['룰',function(r){return r.rule}],['IP',function(r){return r.ip}]])+'</div></div>';
 return k+t+rec}

function vDiag(){return D.diag.map(function(t){return '<div class="tip '+t[0]+'"><h3>'+t[1]+'</h3><div class=why>'+t[2]+'</div>'+(t[3]?'<pre>'+t[3]+'</pre>':'')+'</div>'}).join('')}

function tabs(){var t=[['overview','개요']].concat(D.apps.map(function(a){return [a.app,a.app]})).concat([['pods','Pod'],['nodes','노드'],['waf','WAF'],['diag','진단']]);
 document.getElementById('tabs').innerHTML=t.map(function(x){return '<div class="tab'+(x[0]===TAB?' on':'')+'" onclick="setTab(\''+x[0]+'\')">'+x[1]+'</div>'}).join('')}
function render(){if(!D)return;var v=document.getElementById('view');
 if(TAB==='overview')v.innerHTML=vOverview();else if(TAB==='pods')v.innerHTML=vPods();else if(TAB==='nodes')v.innerHTML=vNodes();
 else if(TAB==='waf')v.innerHTML=vWaf();else if(TAB==='diag')v.innerHTML=vDiag();
 else{var a=D.apps.find(function(x){return x.app===TAB});v.innerHTML=a?vApp(a):''}}
function setTab(t){TAB=t;tabs();render()}
function setSt(x,c){document.getElementById('st').innerHTML='<span class=dot style="background:'+c+'"></span>'+x}
async function load(){setSt('불러오는 중','#ffcb57');var s=document.getElementById('since').value;
 try{var r=await fetch('/api/data?since='+s+'&waf_minutes='+parseInt(s));D=await r.json();tabs();render();setSt('갱신 '+D.ts,'#46e3a0')}
 catch(e){setSt('연결 오류','#ff6b81')}}
var tm=null;function setAuto(){if(tm)clearInterval(tm);var s=+document.getElementById('auto').value;if(s)tm=setInterval(load,s*1000)}
document.getElementById('auto').onchange=setAuto;document.getElementById('since').onchange=load;
load();setAuto();
</script></body></html>"""


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        u = urlparse(self.path)
        if u.path == "/":
            self._s(200, "text/html; charset=utf-8", HTML.encode("utf-8"))
        elif u.path == "/api/data":
            q = parse_qs(u.query)
            since = q.get("since", ["15m"])[0]
            wm = int(q.get("waf_minutes", ["15"])[0])
            try:
                body = json.dumps(build_data(since, wm)).encode("utf-8")
                self._s(200, "application/json; charset=utf-8", body)
            except Exception as e:
                self._s(500, "application/json", json.dumps({"error": str(e)}).encode("utf-8"))
        else:
            self._s(404, "text/plain", b"not found")

    def _s(self, code, ctype, body):
        try:
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except Exception:
            pass


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, *a):
        pass


def _mins(since):
    try:
        return int(since[:-1]) * (60 if since.endswith("h") else 1)
    except Exception:
        return 15


def render_text(d):
    L = []
    s = d["summary"]
    L.append("=" * 70)
    L.append("  3과제 모니터링  %s  | allow %d  block %d | 2xx %d 4xx %d 5xx %d | pod %d/%d  node %d" % (
        d["ts"], s["allow"], s["block"], s["c2"], s["c4"], s["c5"], s["pods_ready"], s["pods_total"], s["nodes_total"]))
    L.append("=" * 70)
    for a in d["apps"]:
        L.append("[%-7s] req %-6d 2xx/4xx/5xx %d/%d/%d  ok %.0f%%  SLO<=%dms %.0f%%  p50/95/99 %d/%d/%d ms" % (
            a["app"], a["total"], a["c2"], a["c4"], a["c5"], a["ok_rate"], a["slo_ms"], a["slo_rate"], a["p50"], a["p95"], a["p99"]))
        for r in a["recent5"][:3]:
            L.append("    5xx  %s %s %s  %sms  %s" % (r["ts"], r["m"], r["path"], r["dur"], r["ip"]))
        for r in a["recent4"][:2]:
            L.append("    4xx  %s %s %s  %sms  %s" % (r["ts"], r["m"], r["path"], r["dur"], r["ip"]))
    L.append("- Pods " + "-" * 60)
    for p in d["pods"]:
        st = p["phase"] + ("/Ready" if p["ready"] else "/NotReady")
        L.append("  %-26s %-14s rst%-3s cpu %-6s mem %-8s %-22s %s" % (
            p["name"], st, p["restarts"], p["cpu"], p["mem"], p["node"].split(".")[0], ("!! " + p["reason"]) if p["reason"] else ""))
    L.append("- Nodes " + "-" * 59)
    for n in d["nodes"]:
        L.append("  %-46s %-16s %-9s cpu %-5s mem %-5s" % (
            n["name"].split(".")[0], n["type"] + ("(karp)" if n["karpenter"] else "(base)"), n["ready"], n["cpu_pct"], n["mem_pct"]))
    L.append("- WAF " + "-" * 61)
    w = d["waf"]
    L.append("  로깅 미설정 (waf.tf 로깅 추가 필요)" if not w.get("enabled") else "  차단(403) %d건  룰: %s" % (
        w["total"], ", ".join("%s×%d" % (r[0], r[1]) for r in w["by_rule"][:3]) or "-"))
    L.append("- 진단 (원인 / 해결) " + "-" * 48)
    for t in d["diag"]:
        L.append("  [%s] %s" % (t[0].upper(), t[1]))
        if t[3]:
            L.append("        해결: " + t[3].replace("\n", "\n              "))
    return "\n".join(L)


def main():
    ap = argparse.ArgumentParser(description="3과제 모니터링 대시보드")
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--namespace", default="app")
    ap.add_argument("--waf-log-group", default="aws-waf-logs-wsi2026")
    ap.add_argument("--waf-region", default="ap-northeast-2")
    ap.add_argument("--since", default="15m", help="조회 기간 (예: 5m, 15m, 1h)")
    ap.add_argument("--once", action="store_true", help="웹서버 대신 터미널에 1회 출력 (CloudShell용)")
    ap.add_argument("--watch", type=int, default=0, metavar="SEC", help="N초마다 터미널 갱신 (CloudShell용)")
    a = ap.parse_args()
    CFG["ns"] = a.namespace
    CFG["waf_group"] = a.waf_log_group
    CFG["waf_region"] = a.waf_region
    if a.once or a.watch:
        wm = _mins(a.since)
        try:
            while True:
                if a.watch:
                    print("\033[2J\033[H", end="")
                print(render_text(build_data(a.since, wm)))
                if not a.watch:
                    break
                time.sleep(a.watch)
        except KeyboardInterrupt:
            pass
        return
    bar = "-" * 54
    print(bar + "\n  3과제 모니터링 대시보드\n  http://%s:%d   (Ctrl+C 종료)\n" % (a.host, a.port) + bar)
    try:
        Server((a.host, a.port), H).serve_forever()
    except KeyboardInterrupt:
        print("\n  종료")


if __name__ == "__main__":
    main()