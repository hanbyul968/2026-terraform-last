#!/usr/bin/env python3
"""3과제 모니터링 대시보드 (Flask · 다크 UI).
데이터 수집은 monitor.py 함수를 재사용. 시간창 1/5/10/15/20/25/30분 선택 + 자동 갱신.

설치:  pip3 install flask   (CloudShell: pip3 install --user flask)
실행:  python3 dashboard.py --namespace app --waf-log-group aws-waf-logs-wsi2026
       → http://<host>:8080
"""
import argparse
import os
import sys
from collections import defaultdict, deque

from flask import Flask, jsonify, request, Response
import monitor  # 같은 폴더의 monitor.py (수집/진단 로직 재사용)

# tools/dashboard.py 와 tuning/ CLI 가 동일한 공식 채점/후보 엔진을 쓴다.
_TUNING_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "tuning"))
if _TUNING_DIR not in sys.path:
    sys.path.insert(0, _TUNING_DIR)
import tuning_engine

app = Flask(__name__)
_TUNE_CPU_HISTORY = defaultdict(lambda: deque(maxlen=600))
# 시스템(DaemonSet 등) CPU 예약은 자주 바뀌지 않으므로 폴링마다 kubectl을 부르지 않는다.
_SYSTEM_RESERVED = {"value": 0, "at": 0.0}


def _system_reserved_cached(ttl=120.0):
    import time as _time
    now = _time.time()
    if now - _SYSTEM_RESERVED["at"] > ttl:
        try:
            _SYSTEM_RESERVED["value"] = tuning_engine._system_reserved_m(monitor.CFG["ns"])
        except Exception:
            pass
        _SYSTEM_RESERVED["at"] = now
    return _SYSTEM_RESERVED["value"]

PAGE = r"""<!doctype html><html lang="ko"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>3과제 모니터링</title>
<style>
:root{--bg:#ffffff;--bg2:#f5f6f8;--card:#ffffff;--card2:#f7f8fa;--line:#e3e6ea;--mut:#6b7280;--txt:#1a1d23;--ac:#2563eb;--gd:#15803d;--wn:#b45309;--bd:#dc2626}
*{box-sizing:border-box}html,body{margin:0}
body{background:radial-gradient(1200px 600px at 70% -10%,#eef3fb 0,var(--bg) 60%);color:var(--txt);font-family:'Segoe UI','Malgun Gothic',sans-serif;font-size:14px;min-height:100vh}
header{position:sticky;top:0;z-index:20;display:flex;align-items:center;gap:18px;padding:14px 26px;background:rgba(255,255,255,.85);backdrop-filter:blur(10px);border-bottom:1px solid var(--line)}
header h1{font-size:15px;font-weight:700;margin:0;letter-spacing:.5px;display:flex;align-items:center;gap:9px}
header h1::before{content:"";width:9px;height:9px;border-radius:50%;background:var(--gd)}
.ctl{display:flex;align-items:center;gap:7px;color:var(--mut);font-size:12.5px}
select,button{background:var(--card2);color:var(--txt);border:1px solid var(--line);border-radius:9px;padding:7px 12px;font-size:13px;cursor:pointer;outline:none}
input[type=number]{background:var(--card2);color:var(--txt);border:1px solid var(--line);border-radius:7px;padding:5px 7px;font-size:12.5px;width:72px;outline:none}
.calc th,.calc td{padding:6px 8px;white-space:nowrap}.calc input{width:66px}
select:hover,button:hover{border-color:var(--ac)}
#st{margin-left:auto;font-size:12px;color:var(--mut);display:flex;align-items:center;gap:7px}
.dot{width:8px;height:8px;border-radius:50%;display:inline-block}
nav{display:flex;gap:3px;padding:14px 26px 0;flex-wrap:wrap}
.tab{padding:9px 17px;border-radius:11px 11px 0 0;color:var(--mut);cursor:pointer;border:1px solid transparent;font-size:13px;font-weight:500;transition:.15s}
.tab:hover{color:var(--txt)}
.tab.on{background:var(--card);border-color:var(--line);border-bottom-color:var(--card);color:var(--txt)}
main{padding:18px 26px 60px}
.grid{display:grid;gap:15px}.g2{grid-template-columns:repeat(auto-fit,minmax(420px,1fr))}.g3{grid-template-columns:repeat(auto-fit,minmax(290px,1fr))}.g4{grid-template-columns:repeat(auto-fit,minmax(195px,1fr))}
.card{background:linear-gradient(180deg,var(--card),var(--card2));border:1px solid var(--line);border-radius:16px;padding:17px;box-shadow:0 1px 0 rgba(255,255,255,.02) inset}
.card h2{margin:0 0 13px;font-size:13.5px;font-weight:600;color:#374151;display:flex;justify-content:space-between}
.lbl{font-size:10.5px;color:var(--mut);text-transform:uppercase;letter-spacing:1px;margin-bottom:7px}
.kpi{font-size:32px;font-weight:800;line-height:1;font-variant-numeric:tabular-nums}.kpi.sm{font-size:21px}
.row{display:flex;justify-content:space-between;padding:6px 0;border-bottom:1px solid var(--line);font-size:13px}.row:last-child{border:0}
.gd{color:var(--gd)}.wn{color:var(--wn)}.bd{color:var(--bd)}.mut{color:var(--mut)}
.bar{height:7px;background:#f6f7f9;border-radius:6px;overflow:hidden;margin:9px 0}.bar>div{height:100%;border-radius:6px;transition:width .5s}
table{width:100%;border-collapse:collapse;font-size:12.5px}th,td{text-align:left;padding:6px 9px;border-bottom:1px solid var(--line)}
th{color:var(--mut);font-size:10.5px;text-transform:uppercase;letter-spacing:.5px}td.n{text-align:right;font-variant-numeric:tabular-nums;color:var(--mut)}
.pill{padding:2px 9px;border-radius:20px;font-size:11px;font-weight:700}.p2{background:rgba(61,220,151,.14);color:var(--gd)}.p4{background:rgba(255,207,92,.14);color:var(--wn)}.p5{background:rgba(255,92,122,.14);color:var(--bd)}
.box{background:#f6f7f9;border:1px solid var(--line);border-radius:12px;max-height:360px;overflow:auto}
.tip{border-left:3px solid;border-radius:12px;padding:13px 16px;background:var(--card);margin-bottom:11px}
.tip.bad{border-color:var(--bd)}.tip.warn{border-color:var(--wn)}.tip.good{border-color:var(--gd)}.tip.dim{border-color:#33415c}
.tip h3{margin:0 0 6px;font-size:13.5px}.tip .why{color:#374151;font-size:13px;white-space:pre-wrap}
.tip pre{margin:8px 0 0;background:#f6f7f9;border:1px solid var(--line);border-radius:9px;padding:10px 12px;font-size:12px;white-space:pre-wrap;color:#1d4ed8;overflow-x:auto}
details.det{border-bottom:1px solid var(--line)}
details.det:last-child{border-bottom:0}
details.det>summary{padding:9px 13px;cursor:pointer;list-style:none;font-size:12.5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
details.det>summary::-webkit-details-marker{display:none}
details.det>summary:hover{background:#eef1f5}
details.det[open]>summary{background:#eef1f5}
.kv{display:grid;grid-template-columns:120px 1fr;gap:6px 16px;padding:12px 15px;border-top:1px solid var(--line);background:#f6f7f9;font-size:13px;line-height:1.5}
.kk{color:var(--mut)}
.vv{color:#1a1d23;white-space:pre-wrap;word-break:break-all}
.rsn{color:var(--wn);font-size:11.5px;margin-left:4px}
</style></head><body>
<header><h1>3과제 모니터링</h1>
<span class="ctl">시간창
<select id="since">
<option value="1m">1분</option><option value="5m">5분</option><option value="10m">10분</option>
<option value="15m" selected>15분</option><option value="20m">20분</option><option value="25m">25분</option><option value="30m">30분</option>
</select></span>
<span class="ctl">자동
<select id="auto"><option value="0">수동</option><option value="5">5s</option><option value="10" selected>10s</option><option value="30">30s</option><option value="60">60s</option></select></span>
<button onclick="load()">새로고침</button>
<button onclick="smoke()" title="엔드포인트에 200/403/404 스모크 테스트">스모크</button>
<span id="st"></span></header>
<nav id="tabs"></nav><div id="alerts" style="padding:0 26px"></div><main id="view"></main><script>
var D=null,TAB='overview';
function cr(v,g,w){return v>=g?'gd':v>=w?'wn':'bd'}
function stp(s){s=''+s;var c=s[0]==='2'?'p2':s[0]==='4'?'p4':'p5';return '<span class="pill '+c+'">'+s+'</span>'}
function esc(s){return (''+s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')}
function kv(pairs){return '<div class=kv>'+pairs.filter(function(p){return p[1]!==undefined&&p[1]!==null&&p[1]!==''&&p[1]!=='-'}).map(function(p){return '<div class=kk>'+p[0]+'</div><div class=vv>'+esc(p[1])+'</div>'}).join('')+'</div>'}
function tbl(rows,cols){if(!rows||!rows.length)return '<div class=mut style="padding:9px">없음</div>';
 var h='<table><tr>'+cols.map(function(c){return '<th'+(c[2]?' style="text-align:right"':'')+'>'+c[0]+'</th>'}).join('')+'</tr>';
 return h+rows.map(function(r){return '<tr>'+cols.map(function(c){return '<td'+(c[2]?' class=n':'')+'>'+c[1](r)+'</td>'}).join('')+'</tr>'}).join('')+'</table>'}
function recTbl(rows){if(!rows||!rows.length)return '<div class=mut style="padding:9px">없음</div>';
 return '<div class=box>'+rows.map(function(r){var key=r.ts+'|'+r.m+'|'+r.path+'|'+r.st+'|'+r.ip;
  return '<details class=det data-k="'+esc(key)+'"><summary><span class=mut>'+r.ts+'</span> <b>'+r.m+'</b> '+esc(r.path)+' '+stp(r.st)
   +(r.why?' <span class=rsn>'+esc(r.why)+'</span>':'')+'<span class=mut style="float:right">'+r.dur+'ms</span></summary>'
   +kv([['시각',r.ts],['메서드',r.m],['경로',r.path],['상태',r.st],['사유',r.why],['requestid',r.requestid],['uuid',r.uuid],['지연(ms)',r.dur],['클라이언트 IP',r.ip]])
   +'</details>'}).join('')+'</div>'}
function appCard(a){var s=cr(a.slo_rate,90,70),o=cr(a.ok_rate,90,70);
 return '<div class=card><div class=lbl>'+a.app+'</div><div class="kpi '+s+'">'+a.slo_rate+'%<span class=mut style="font-size:12px;font-weight:400"> SLO≤'+a.slo_ms+'ms</span></div>'
 +'<div class=bar><div class="'+s+'" style="width:'+a.slo_rate+'%;background:currentColor"></div></div>'
 +'<div class=row><span>요청수</span><b>'+a.total+'</b></div>'
 +'<div class=row><span>2xx / 4xx / 5xx</span><span><span class=gd>'+a.c2+'</span> / <span class=wn>'+a.c4+'</span> / <span class=bd>'+a.c5+'</span></span></div>'
 +'<div class=row><span>가용성 (2xx≤5s)</span><span class="'+o+'">'+a.ok_rate+'%</span></div>'
 +'<div class=row><span>p50/p95/p99</span><span>'+a.p50+'/'+a.p95+'/'+a.p99+'ms</span></div></div>'}
function vOverview(){var s=D.summary;
 var k='<div class="grid g4">'
 +'<div class=card><div class=lbl>통과 allow</div><div class="kpi gd">'+s.allow+'</div></div>'
 +'<div class=card><div class=lbl>차단 block·403</div><div class="kpi bd">'+s.block+'</div></div>'
 +'<div class=card><div class=lbl>2xx / 4xx / 5xx</div><div class="kpi sm"><span class=gd>'+s.c2+'</span>/<span class=wn>'+s.c4+'</span>/<span class=bd>'+s.c5+'</span></div></div>'
 +'<div class=card><div class=lbl>Pod ready · 노드</div><div class="kpi sm">'+s.pods_ready+'/'+s.pods_total+' · '+s.nodes_total+'</div></div></div>';
 var cards='<div class="grid g3" style="margin-top:15px">'+D.apps.map(appCard).join('')+'</div>';
 var diag='<div class=lbl style="margin:22px 0 9px">진단 · 원인 & 해결</div>'+D.diag.map(function(t){return '<div class="tip '+t[0]+'"><h3>'+t[1]+'</h3><div class=why>'+t[2]+'</div>'+(t[3]?'<pre>'+t[3]+'</pre>':'')+'</div>'}).join('');
 return k+cards+diag}
function vApp(a){var s=cr(a.slo_rate,90,70),o=cr(a.ok_rate,90,70);
 var k='<div class="grid g4">'
 +'<div class=card><div class=lbl>SLO ≤'+a.slo_ms+'ms</div><div class="kpi '+s+'">'+a.slo_rate+'%</div></div>'
 +'<div class=card><div class=lbl>가용성 2xx≤5s</div><div class="kpi '+o+'">'+a.ok_rate+'%</div></div>'
 +'<div class=card><div class=lbl>요청수 (+hc)</div><div class="kpi sm">'+a.total+' <span class=mut style="font-size:13px">+'+a.hc+'</span></div></div>'
 +'<div class=card><div class=lbl>p99 / max</div><div class="kpi sm">'+a.p99+' / '+a.max+'ms</div></div></div>';
 var cnt='<div class="grid g3" style="margin-top:15px"><div class=card><div class=lbl>2xx</div><div class="kpi gd">'+a.c2+'</div></div>'
 +'<div class=card><div class=lbl>4xx</div><div class="kpi wn">'+a.c4+'</div></div>'
 +'<div class=card><div class=lbl>5xx</div><div class="kpi bd">'+a.c5+'</div></div></div>';
 var pth='<div class="grid g2" style="margin-top:15px"><div class=card><h2>경로별 요청</h2>'+tbl(a.paths,[['경로',function(r){return r[0]}],['건수',function(r){return r[1]},1]])+'</div>'
 +'<div class=card><h2>에러 경로 (4xx/5xx)</h2>'+tbl(a.err_paths,[['상태',function(r){return stp(r[0][1])}],['경로',function(r){return r[0][0]}],['건수',function(r){return r[1]},1]])+'</div></div>';
 var rec='<div class="grid g3" style="margin-top:15px">'
 +'<div class=card><h2 class=gd>최근 2xx</h2>'+recTbl(a.recent2)+'</div>'
 +'<div class=card><h2 class=wn>최근 4xx</h2>'+recTbl(a.recent4)+'</div>'
 +'<div class=card><h2 class=bd>최근 5xx</h2>'+recTbl(a.recent5)+'</div></div>';
 return k+cnt+pth+rec}
function vPods(){return '<div class=card><h2>Pod ('+D.pods.length+'개)</h2><div class=box>'+tbl(D.pods,[
 ['app',function(r){return r.app}],['Pod',function(r){return r.name}],
 ['상태',function(r){return (r.phase==='Running'&&r.ready)?'<span class="pill p2">Running</span>':'<span class="pill p5">'+r.phase+(r.ready?'':'/NotReady')+'</span>'}],
 ['재시작',function(r){return r.restarts},1],['CPU',function(r){return r.cpu},1],['MEM',function(r){return r.mem},1],
 ['노드',function(r){return (r.node||'-').split('.')[0]}],['사유',function(r){return r.reason?'<span class=bd>'+r.reason+'</span>':'-'}]])+'</div></div>'}
function vNodes(){return '<div class=card><h2>노드 ('+D.nodes.length+'대)</h2>'+tbl(D.nodes,[
 ['노드',function(r){return r.name.split('.')[0]}],
 ['타입',function(r){return r.type+(r.karpenter?' <span class="pill p2">karpenter</span>':' <span class="pill p4">base</span>')}],
 ['상태',function(r){return r.ready==='Ready'?'<span class=gd>Ready</span>':'<span class=bd>'+r.ready+'</span>'}],
 ['CPU',function(r){return r.cpu+' ('+r.cpu_pct+')'}],['MEM',function(r){return r.mem+' ('+r.mem_pct+')'}]])+'</div>'
 +'<div class=card style="margin-top:15px"><h2>HPA</h2>'+tbl(D.hpa,[['이름',function(r){return r.name}],['CPU 현재/목표',function(r){return r.cur+' / '+r.tgt}],['min/max',function(r){return r.min+' / '+r.max}],['replicas',function(r){return r.replicas},1]])+'</div>'}
function vWaf(){var w=D.waf;if(!w.enabled)return '<div class="tip dim"><h3>WAF 로깅이 켜져 있지 않음</h3><div class=why>CloudWatch 로그그룹이 없어 블락(403) 데이터를 못 가져옵니다.</div><pre>terraform waf.tf 에 로깅 추가 후 apply\n또는: --waf-log-group <실제그룹명> --waf-region ap-northeast-2</pre></div>';
 var k='<div class="grid g3"><div class=card><div class=lbl>차단 403</div><div class="kpi bd">'+w.total+'</div></div>'
 +'<div class=card><div class=lbl>통과 앱도달</div><div class="kpi gd">'+D.summary.allow+'</div></div>'
 +'<div class=card><h2>차단 메서드</h2>'+tbl(w.by_method,[['M',function(r){return r[0]}],['건수',function(r){return r[1]},1]])+'</div></div>';
 var t='<div class="grid g3" style="margin-top:15px"><div class=card><h2>차단 사유 (룰)</h2>'+tbl(w.by_reason||w.by_rule,[['사유',function(r){return r[0]}],['건수',function(r){return r[1]},1]])+'</div>'
 +'<div class=card><h2>차단 IP</h2>'+tbl(w.by_ip,[['IP',function(r){return r[0]}],['건수',function(r){return r[1]},1]])+'</div>'
 +'<div class=card><h2>차단 URI</h2>'+tbl(w.by_uri,[['URI',function(r){return r[0]}],['건수',function(r){return r[1]},1]])+'</div></div>';
 var rec=w.recent.map(function(r){var key=r.ts+'|'+(r.url||r.uri)+'|'+r.ip+'|'+r.reason;
  return '<details class=det data-k="'+esc(key)+'"><summary>'
  +'<span class=mut>'+r.ts+'</span> <b>'+r.m+'</b> '+esc(r.url||r.uri)
  +' <span class="pill p5">'+esc(r.reason)+'</span><span class=mut style="float:right">'+r.ip+(r.country&&r.country!=='?'?' · '+r.country:'')+'</span>'
  +'</summary>'+kv([['차단 사유',r.reason],['메서드',r.m],['요청 URL',r.url||r.uri],['국가',r.country],['IP',r.ip],['User-Agent',r.ua],['X-Forwarded-For',r.xff]])+'</details>'}).join('')
  || '<div class=mut style="padding:9px">차단 없음</div>';
 return k+t+'<div class=card style="margin-top:15px"><h2>최근 차단 — 누르면 요청 전문 · 왜 차단됐는지</h2><div class=box>'+rec+'</div></div>'}
function vDiag(){return D.diag.map(function(t){return '<div class="tip '+t[0]+'"><h3>'+t[1]+'</h3><div class=why>'+t[2]+'</div>'+(t[3]?'<pre>'+t[3]+'</pre>':'')+'</div>'}).join('')}

// ---- 계산 탭: 원인을 먼저 가려낸 뒤 처방 (줄여/늘려/유지) ----
// 설계 원칙 (중요):
//  requests.cpu 는 '노드 예약량'이지 '파드 속도 상한'이 아니다. user/product 에는 cpu limit
//  이 없어서 request 를 올려도 파드가 빨라지지 않는다. 올리면 오히려
//    (1) 노드당 파드 수가 줄어 노드가 늘고(비용 상승),
//    (2) HPA 사용률 = 실사용/request 가 작아져 스케일업이 '늦어진다'(성능 악화).
//  그래서 '느리다 -> request 올려' 는 틀린 처방이다. 아래는 실사용/노드CPU/HPA 상한을
//  보고 원인을 먼저 구분한다. 앱 목록·SLO·파드는 전부 라이브에서 읽으므로
//  대회날 앱이 바뀌어도(이름/개수/SLO 변경) 그대로 동작한다.
function cpuM(s){if(s===undefined||s===null||s==='')return 0;s=''+s;return s.slice(-1)==='m'?parseInt(s):Math.round(parseFloat(s)*1000)}
function pctn(s){var n=parseInt((''+(s||'')).replace('%',''));return isNaN(n)?null:n}
function hpaOf(n){return (D.hpa||[]).find(function(h){return h.name===n})||{}}
// 앱의 '실제' CPU 사용량. 순간값 하나로 request 를 권고하면 안 된다 — 스파이크가 찍히면
// 과대, 부하가 빠진 순간이 찍히면 과소가 된다(실측: 실사용 132m 를 400m 로 읽어 request
// 300m 를 권고). 그래서 폴링마다 관측을 누적하고 '순위 기반 p95'(보간 없음)를 기준으로 쓴다.
// 보간형 백분위는 표본이 적을 때 최댓값으로 끌려가므로 쓰지 않는다.
var USEHIST={};            // {앱: [관측된 파드 CPU(m), ...]}  누적
var USEHIST_CAP=600;       // 앱당 표본 상한 (폴링 5초면 약 50분)
function useRecord(){
 (D.pods||[]).forEach(function(p){
  if(p.phase!=='Running')return;
  var v=cpuM(p.cpu); if(!(v>0))return;
  var a=USEHIST[p.app]||(USEHIST[p.app]=[]);
  a.push(v); if(a.length>USEHIST_CAP)a.shift();
 });
}
function pctNearest(sorted,q){
 if(!sorted.length)return 0;
 if(sorted.length===1)return sorted[0];
 return sorted[Math.floor(q/100*(sorted.length-1))];
}
function useOf(n){
 var now=0,sum=0,cnt=0,tot=0;
 (D.pods||[]).forEach(function(p){if(p.app!==n||p.phase!=='Running')return;tot++;
  var v=cpuM(p.cpu);if(v>0){now=Math.max(now,v);sum+=v;cnt++;}});
 var h=(USEHIST[n]||[]).slice().sort(function(a,b){return a-b});
 var p95=pctNearest(h,95);
 // 기준값: 누적 표본이 충분하면 p95, 아니면 현재 순간 최대값
 var basis=h.length>=10?p95:now;
 return {max:basis,now:now,p95:p95,hmax:h.length?h[h.length-1]:0,
         samples:h.length,avg:cnt?Math.round(sum/cnt):0,pods:tot,measured:cnt>0}}
// 노드 CPU 최대 사용률(%) — '노드 경쟁' 판단용. 실사용 기준(예약률 아님).
function nodeCpuMax(){var mx=0;(D.nodes||[]).forEach(function(nd){var v=pctn(nd.cpu_pct);if(v!==null&&v>mx)mx=v});return mx}
// 적정 request = 실사용 피크 x 1.3 (헤드룸), 25m 단위, 하한 50m
function rightSize(peak){if(!peak)return null;return Math.max(50,Math.ceil(peak*1.3/25)*25)}
// 노드 1대의 할당가능 CPU(밀리코어). 대회날 노드 타입이 바뀔 수 있으므로 상수를 박지 않고
// 라이브 노드의 status.allocatable 을 쓴다. 섞여 있으면 '가장 작은 노드'를 기준으로 잡아야
// 노드 수를 과소추정하지 않는다. 값이 없으면 사용량/사용률로 역산하고, 그것도 없으면 0.
function nodeAllocM(){
 var vals=[];
 (D.nodes||[]).forEach(function(nd){
  if(nd.cpu_alloc>0){vals.push(nd.cpu_alloc);return}
  var use=cpuM(nd.cpu),pc=pctn(nd.cpu_pct);
  if(use>0&&pc>0)vals.push(Math.round(use*100/pc));
 });
 if(!vals.length)return 0;
 return Math.min.apply(null,vals);
}
// 노드 타입 구성 (표시용) — 섞여 있으면 그대로 보여줘서 추정 근거를 알 수 있게 한다.
function nodeTypes(){
 var m={};(D.nodes||[]).forEach(function(nd){var k=nd.type||'?';m[k]=(m[k]||0)+1});
 return Object.keys(m).map(function(k){return k+' x'+m[k]}).join(', ')||'-';
}
function tuneCmdBlock(title,lines){if(!lines||!lines.length)return '';return '<div class=mut style="font-size:11px;margin:7px 0 3px">'+title+'</div><pre style="margin:0 0 7px;background:#f6f7f9;border:1px solid var(--line);border-radius:8px;padding:9px 11px;font-size:11px;white-space:pre-wrap;overflow-x:auto">'+esc(lines.join('\n'))+'</pre>'}
function vEnginePlan(t){
 var s=t.score||{},cl=t.cluster||{};
 var head='<div class="grid g4" style="margin-bottom:15px">'
  +'<div class=card><div class=lbl>공식 소계</div><div class="kpi sm">'+(s.total==null?'-':s.total+'/36')+'</div></div>'
  +'<div class=card><div class=lbl>비용 ratio / 점수</div><div class="kpi sm">'+(s.cost_ratio==null?'-':(+s.cost_ratio).toFixed(2))+'</div><div class=mut>'+(s.cost_points==null?'-':s.cost_points+'/12')+'</div></div>'
  +'<div class=card><div class=lbl>실측 CPU 수요 / 노드공급</div><div class="kpi sm">'+(cl.cluster_cpu_p95_m||0)+'m</div><div class=mut>노드 allocatable '+(cl.node_alloc_m||0)+'m · 시스템 예약 '+(cl.system_reserved_m||0)+'m</div></div>'
  +'<div class=card><div class=lbl>안전 게이트</div><div class="kpi sm '+(s.avail_gate_pass&&s.perf_gate_pass?'gd':'bd')+'">'+(s.avail_gate_pass&&s.perf_gate_pass?'PASS':'FAIL')+'</div><div class=mut>avail≥99 · perf≥30</div></div></div>';
 var rows=(t.apps||[]).map(function(a){return '<div class=row><span><b>'+esc(a.app)+'</b> <span class=mut>'+esc(a.bottleneck)+'</span></span><span>perf '+a.performance.toFixed(1)+'% · avail '+a.availability.toFixed(1)+'% · request '+a.request+'m · target '+a.target+'% · trigger '+a.trigger+'m · CPU p90 '+a.cpu_p90+'m</span></div>'}).join('');
 var cs=(t.candidates||[]).map(function(c,i){var p=c.proposed,x=c.current;return '<div class=card><div class=lbl>#'+(i+1)+' '+esc(c.kind)+' · '+esc(c.app)+' <span class="'+(c.disruptive?'wn':'gd')+'">'+(c.disruptive?'rollout':'HPA-only')+'</span></div>'
  +'<div class=row><span>현재 → 후보</span><span>request '+x.request+'→<b>'+p.request+'m</b> · target '+x.target+'→<b>'+p.target+'%</b> · min '+x.min+'→'+p.min+' · max '+x.max+'→'+p.max+'</span></div>'
  +'<div class=row><span>HPA trigger</span><span>'+c.trigger_before+'m → <b>'+c.trigger_after+'m</b></span></div>'
  +'<div class=row><span>예약 기준 노드 · CPU 경합</span><span>예상 '+c.predicted_nodes+'대 · 공급부족 '+(c.cpu_supply_ratio||0).toFixed(2)+'배'+(c.risk?' <span class=wn>'+esc(c.risk)+'</span>':'')+' · confidence '+esc(c.confidence)+'</span></div>'
  +'<div class=mut style="font-size:12px;margin-top:7px">근거: '+esc(c.reason)+'</div>'
  +tuneCmdBlock('라이브 적용',c.apply_commands)+tuneCmdBlock('정확한 롤백',c.rollback_commands)+'</div>'}).join('');
 if(!cs)cs='<div class="tip good"><h3>안전하게 공식 점수를 올릴 후보 없음</h3><div class=why>'+esc(t.reason||'현재값 유지')+'</div></div>';
 return '<div class=lbl style="margin-bottom:9px">공통 Python 엔진 — dashboard / advise / optimize 동일 판단</div>'+head+'<div class=card style="margin-bottom:15px"><h2>앱 상태</h2>'+rows+'</div><div class="grid g3">'+cs+'</div>';
}
function vCalc(){if(D.tuning&&D.tuning.schema_version)return vEnginePlan(D.tuning);
 var apps=D.apps||[];var nodeMax=nodeCpuMax();var sMin=0,sMinCpu=0;
 useRecord();  // 폴링마다 실사용 관측을 누적 (순간값 한 점으로 판단하지 않기 위해)
 var ALLOC=nodeAllocM();  // 라이브 노드에서 유도 (노드 타입 변경에 자동 대응)
 var cards=apps.map(function(a){
  var n=a.app,h=hpaOf(n);
  var req=cpuM(a.cpu_req);
  var util=pctn(h.tgt)||70,mn=+h.min||0,mx=+h.max||0,rep=+h.replicas||mn,cur=pctn(h.cur);
  var perf=a.slo_rate,avail=a.ok_rate,p95=a.p95,slo=a.slo_ms;
  var u=useOf(n),fit=rightSize(u.max);
  var atMax=(mx>0&&rep>=mx);
  var badAvail=(avail!==undefined&&avail!==null&&avail<99);
  var badPerf=((perf!==undefined&&perf!==null&&perf<95)||(slo&&p95>slo));
  var dir,cls,cause,note,rcpu=req,rutil=util,rmn=2,rmx=mx,keepReq=false,extra='';

  if(!a.total){dir='관측 필요';cls='mut';cause='요청 없음';
   note='이 앱에 들어온 요청이 0건이라 판단할 수 없다. loadtest 로 부하를 준 상태에서 다시 본다.';}
  else if(!u.measured){dir='관측 필요';cls='mut';cause='실사용 측정 불가';
   note='파드 CPU 실측값이 없다(metrics-server 미동작). request 판단은 실사용 없이는 추측이 된다. kubectl top pods 가 되는지 확인한다.';}
  else if(badAvail){
   // 가용성은 최우선 게이트. 가용성 실패는 보통 '파드 수 부족/롤아웃/에러'이지 request 부족이 아니다.
   keepReq=true;
   if(atMax){dir='늘려 ↑';cls='bd';cause='파드 상한 도달';rmx=mx+2;rmn=2;
    note='가용성 '+avail+'% (<99) + 파드가 상한 '+mx+'개에 붙어 있다. 더 못 늘려서 실패한 것이므로 max_replicas 를 올린다. request 는 원인이 아니다.';}
   else{dir='늘려 ↑';cls='bd';cause='파드 부족/스케일 지연';rmn=2;rutil=Math.max(40,util-10);
    note='가용성 '+avail+'% (<99). 상한에는 안 붙었으므로 스케일 속도(util) 문제다. min은 비용 회수를 위해 2로 고정하고 util을 낮춘다. request는 건드리지 않는다.';}
   extra='가용성 실패가 롤아웃 때문일 수도 있다. 부하 중 deployment 를 건드렸는지 먼저 확인한다(롤아웃 자체가 504 를 만든다).';
  }
  else if(badPerf){
   if(atMax){dir='늘려 ↑';cls='wn';cause='파드 상한 도달';keepReq=true;rmx=mx+2;
    note='p95 '+p95+'ms > SLO '+slo+'ms 인데 파드가 상한 '+mx+'개다. 더 늘릴 수 없어서 느린 것이므로 max_replicas 를 올린다. request 를 올리면 오히려 사용률이 낮아져 스케일이 더 늦어진다.';}
   else if(nodeMax>=80){dir='늘려 ↑';cls='wn';cause='노드 CPU 포화';
    rcpu=Math.max(req,fit||req);
    note='노드 실사용 CPU 가 '+nodeMax+'% 다. 파드를 늘려도 같은 노드에서 경쟁한다. 이 경우에만 request 를 올리는 것이 유효하다 — 노드당 파드 수가 줄고 cpu.shares 가 커져 이웃에게 덜 밀린다(노드는 늘어난다).';
    extra='노드를 늘리는 쪽이 더 직접적이다. Karpenter limits.cpu 와 노드그룹 크기를 함께 본다.';}
   else if(u.max < req*0.5){dir='유지 (request 아님)';cls='bd';cause='CPU 병목 아님';keepReq=true;
    note='p95 '+p95+'ms > SLO '+slo+'ms 인데 파드 실사용은 '+u.max+'m 으로 request '+req+'m 의 절반도 안 쓴다. 노드 CPU 도 '+nodeMax+'% 다. CPU 가 병목이 아니므로 request 를 올려도 전혀 나아지지 않는다(오히려 노드만 늘어 비용을 깎는다).';
    extra='앱 밖을 봐야 한다: (1) RDS CPU·커넥션·쿼리 지연 (2) CloudFront 캐시 히트율 — 미스면 매 요청이 오리진까지 간다 (3) DB 커넥션 풀/프록시 borrow 대기 (4) 외부 호출·S3 지연. 실측 예: RDS CPU 5~10%, 읽기지연 0.4~4ms 였다면 DB 는 범인이 아니다.';}
   else if(cur!==null&&cur<util){dir='늘려 ↑';cls='wn';cause='스케일 지연';keepReq=true;
    rutil=Math.max(40,util-15);rmn=2;
    note='p95 초과인데 현재 사용률 '+cur+'% 가 목표 '+util+'% 아래다. 즉 HPA가 아직 안 늘린 상태에서 지연이 났다 = 스케일이 느리다. min은 비용 회수를 위해 2로 고정하고 util을 낮춰 더 빨리 늘린다. request는 유지.';}
   else{dir='늘려 ↑';cls='wn';cause='파드 CPU 포화';rcpu=fit||req;
    note='파드 실사용 '+u.max+'m 이 request '+req+'m 에 근접·초과했고 노드는 여유가 있다. 실사용 피크x1.3 = '+(fit||req)+'m 으로 맞춘다(임의 배수 아님).';}
  }
  else{
   // 성능·가용성 모두 통과 -> 비용 관점에서 request 를 실사용에 맞춰 내린다.
   if(fit&&fit<req*0.9){dir='줄여 ↓';cls='gd';cause='과투자';rcpu=fit;
    note='성능·가용성 통과. 실사용 피크 '+u.max+'m 인데 request 가 '+req+'m 로 과예약이다. 예약이 곧 노드 수이므로 '+fit+'m(피크x1.3)으로 내리면 비용이 줄고 성능은 그대로다.';}
   else{dir='유지';cls='mut';cause='균형';
    note='성능·가용성 통과, request '+req+'m 가 실사용 피크 '+u.max+'m 대비 적정(x1.3 기준 '+(fit||'-')+'m). 바꿀 이유가 없다.';}
  }

  rmn=Math.max(1,rmn);rmx=Math.max(rmx,rmn);sMin+=rmn;sMinCpu+=rmn*rcpu;
  var ch=[];
  if(rcpu!==req)ch.push('requests.cpu <b>'+req+'m → '+rcpu+'m</b> '+(rcpu>req?'↑':'↓')+' <span class=mut>('+(rcpu>req?'노드당 파드 수↓ · cpu.shares↑ → 경쟁 완화 (노드↑ 비용↑)':'예약 축소 → 노드↓ (비용↓)')+')</span>');
  if(rutil!==util)ch.push('HPA averageUtilization <b>'+util+'% → '+rutil+'%</b> '+(rutil>util?'↑':'↓')+' <span class=mut>('+(rutil>util?'느긋하게 스케일 → 비용↓':'더 빨리 파드 늘림 → 지연↓')+')</span>');
  if(rmn!==mn)ch.push('min_replicas <b>'+mn+' → '+rmn+'</b> '+(rmn>mn?'↑':'↓')+' <span class=mut>('+(rmn>mn?'초반 여유 → 가용성↑':'유휴 파드↓ → 비용↓')+')</span>');
  if(rmx!==mx)ch.push('max_replicas <b>'+mx+' → '+rmx+'</b> ↑ <span class=mut>(상한에 막혀 있었음)</span>');
  var how=ch.length?ch.map(function(x){return '<div style="padding:3px 0">• '+x+'</div>'}).join(''):'<div class=mut>변경 없음 — 현상 유지</div>';
  var warn=keepReq?'<div class="tip bd" style="margin-top:8px"><h3>request 는 올리지 않는다</h3><div class=why>이 증상의 원인이 CPU 예약이 아니다. request 를 올리면 HPA 사용률(=실사용/request)이 낮아져 스케일업이 늦어지고 노드만 늘어난다.</div></div>':'';
  var cmds='';
  if(ch.length){
   var patch=JSON.stringify({spec:{minReplicas:rmn,maxReplicas:rmx,metrics:[{type:"Resource",resource:{name:"cpu",target:{type:"Utilization",averageUtilization:rutil}}}]}});
   // PowerShell 에서 -p '{\"..\"}' 는 백슬래시가 그대로 전달돼 kubectl JSON 파싱이 깨진다.
   // 임시 파일 + --patch-file 로 우회한다(경로는 역슬래시 이스케이프를 피해 슬래시 사용).
   var pf='"$env:TEMP/hpa-'+n+'.json"';
   var L=[];
   L.push('kubectl -n app set resources deploy/'+n+' --requests=cpu='+rcpu+'m');
   L.push("'"+patch+"' | Set-Content -Path "+pf+" -Encoding ascii");
   L.push('kubectl -n app patch hpa '+n+' --type=merge --patch-file '+pf);
   L.push('kubectl -n app rollout status deploy/'+n+' --timeout=120s');
   var c=L.join('\n');
   cmds='<div class=lbl style="margin-top:9px;margin-bottom:4px">임시 적용 — PowerShell (apply 하면 사라짐 · 부하 중 requests 변경은 롤아웃=504 주의)</div>'
    +'<pre style="margin:0;background:#f6f7f9;border:1px solid var(--line);border-radius:8px;padding:9px 11px;font-size:11.5px;white-space:pre-wrap;color:#1a1d23;overflow-x:auto">'+esc(c)+'</pre>';
  }
  return '<div class=card><div class=lbl>'+n+' &nbsp;<span class='+cls+' style="font-weight:700">'+dir+'</span> &nbsp;<span class=mut>'+cause+'</span></div>'
   +'<div class=row><span class=mut>설정</span><span>request <b>'+req+'m</b> · util '+util+'% · min '+mn+' · max '+mx+' · 파드 '+rep+'</span></div>'
   +'<div class=row><span class=mut>실사용</span><span>기준 <b>'+u.max+'m</b> '
     +(u.samples>=10?'(누적 p95, 표본 '+u.samples+')':'(현재 순간값 — 표본 '+u.samples+'개, 10개 이상 모이면 p95 사용)')
     +' · 지금 '+u.now+'m · 관측최대 '+u.hmax+'m · 적정 request '+(fit||'-')+'m · 노드CPU최대 '+nodeMax+'%</span></div>'
   +'<div class=row><span class=mut>측정</span><span>perf '+perf+'% · avail '+avail+'% · p95 '+p95+'ms / SLO '+slo+'ms · HPA현재 '+(cur===null?'-':cur+'%')+'</span></div>'
   +'<div style="margin-top:9px"><div class=lbl style="margin-bottom:4px">이렇게 바꿔 (k8s_apps.tf 에 반영)</div><div style="font-size:12.5px">'+how+'</div></div>'
   +warn+cmds
   +'<div class=mut style="font-size:12px;margin-top:8px">근거: '+note+'</div>'
   +(extra?'<div class=mut style="font-size:12px;margin-top:6px">다음 확인: '+extra+'</div>':'')+'</div>';
 }).join('');
 var nMin=ALLOC>0?Math.ceil(sMinCpu/ALLOC):null;
 var summary='<div class="grid g4" style="margin-bottom:15px">'
  +'<div class=card><div class=lbl>권장 정상시 pod 합</div><div class="kpi sm">'+sMin+'</div></div>'
  +'<div class=card><div class=lbl>현재 파드 수</div><div class="kpi sm">'+D.summary.pods_total+'</div></div>'
  +'<div class=card><div class=lbl>권장 정상시 노드(추정)</div><div class="kpi sm">'+(nMin===null?'-':nMin)+'</div><div class=mut style="font-size:11px">'+(ALLOC>0?'노드 '+ALLOC+'m 기준':'노드 할당량 미확인')+'</div></div>'
  +'<div class=card><div class=lbl>현재 노드</div><div class="kpi sm">'+D.summary.nodes_total+'</div></div></div>';
 return '<div class=lbl style="margin-bottom:9px">라이브 자동 판정 — 부하(loadtest/실트래픽) 도는 중에 봐야 정확합니다</div>'
  +summary+'<div class="grid g3">'+cards+'</div>'
  +'<div class="tip mut" style="margin-top:12px"><h3>이 탭이 request 를 다루는 방식</h3><div class=why>'
  +'requests.cpu 는 노드 예약량이지 속도 상한이 아니다(user/product 는 cpu limit 없음). 그래서 "느리다"는 이유만으로 request 를 올리지 않는다. '
  +'권장 request 는 항상 <b>실사용 x 1.3</b> 이고, 그 실사용은 폴링을 누적한 <b>순위기반 p95</b> 다 — 순간값 한 점을 쓰면 스파이크에 끌려가 과대 권고가 난다(실측: 132m 를 400m 로 읽어 300m 권고). '+'정확한 값이 필요하면 loadtest 의 podcpu.csv 를 쓰는 <code>tuning/advise.py</code> 를 본다. '+'올리는 처방은 <b>노드 CPU 포화</b> 또는 <b>파드 실사용이 request 에 근접</b>한 경우로 제한한다. '
  +'실사용이 request 의 절반도 안 되는데 느리면 CPU 가 병목이 아니므로 DB·캐시·커넥션풀을 본다. '
  +'노드 추정 = ⌈Σ(min x request) / 노드 할당가능 CPU⌉ 이고, 할당가능 CPU 는 라이브 노드의 status.allocatable 에서 읽는다(섞여 있으면 가장 작은 노드 기준). '
  +'앱 목록·SLO·파드·노드 타입 모두 라이브에서 읽으므로 대회날 앱이나 인스턴스 타입이 바뀌어도 그대로 쓴다. 현재 노드: '+nodeTypes()+'.'
  +'</div></div>';}

// ---- WAF분석 탭: waf_header_stats.py 출력 붙여넣기 → 막을 것 + 룰 + 테스트 ----
var WAFX_VALID=['/v1/user','/v1/product','/v1/stress','/healthcheck','/images'];
var WAFX_NORMHDR={'host':1,'accept-encoding':1,'content-type':1,'content-length':1,'accept':1,'user-agent':1,'connection':1,'via':1,'x-amz-cf-id':1,'upgrade-insecure-requests':1,
 'accept-language':1,'accept-charset':1,'cache-control':1,'pragma':1,'dnt':1,'te':1,'priority':1,'cookie':1,'referer':1,'origin':1,'x-forwarded-for':1,'x-forwarded-proto':1,'x-forwarded-port':1,'true-client-ip':1,'cloudfront-forwarded-proto':1,
 'sec-ch-ua':1,'sec-ch-ua-mobile':1,'sec-ch-ua-platform':1,'sec-ch-ua-arch':1,'sec-ch-ua-bitness':1,'sec-ch-ua-model':1,'sec-ch-ua-full-version':1,'sec-ch-ua-full-version-list':1,'sec-ch-ua-platform-version':1,'sec-ch-ua-wow64':1,'sec-fetch-dest':1,'sec-fetch-mode':1,'sec-fetch-site':1,'sec-fetch-user':1};
var WAFX_GOODUA=['hey/','go-http-client','curl/','mozilla','chrome','safari','firefox','edg'];
var WAFX_SCAN=['sqlmap','nikto','nmap','masscan','acunetix','havij','wpscan','dirbuster','nuclei','attack','gobuster','fuzz','scanner','zgrab','python-requests'];
function wafxValid(ep){ep=(ep||'').split('?')[0].toLowerCase();for(var i=0;i<WAFX_VALID.length;i++){if(ep===WAFX_VALID[i]||ep.indexOf(WAFX_VALID[i]+'/')===0||(WAFX_VALID[i]==='/images'&&ep.indexOf('/images')===0))return true;}return false;}
function wafxParse(text){var rows=[];text.split('\n').forEach(function(ln){
  if(/,/.test(ln)&&/(ALLOW|BLOCK)/.test(ln)&&ln.indexOf('/')>=0&&!/^\s*판정|verdict/i.test(ln)){var c=ln.split(',');if(c.length>=6){rows.push({verdict:c[0].trim(),waf:c[1].trim().toUpperCase(),cnt:c[3]||'',endpoint:c[4]||'',header:(c[5]||'').trim(),value:c.slice(6).join(',').trim()});return;}}
  var f=ln.trim().split(/\s{2,}/);
  if(f.length>=6&&/^(ALLOW|BLOCK)$/i.test(f[1])){rows.push({verdict:f[0],waf:f[1].toUpperCase(),cnt:f[3],endpoint:f[4],header:f[5],value:f.slice(6).join(' ')});}
});return rows;}
function wafxDecodeQuery(v){var q=(v||'').replace(/\+/g,' ');for(var i=0;i<2;i++){try{var n=decodeURIComponent(q);if(n===q)break;q=n;}catch(e){break;}}return q;}
function wafxQueryInfo(v){var q=wafxDecodeQuery(v),l=q.toLowerCase();
  if(l.indexOf('/etc/passwd')>=0)return {token:'/etc/passwd',why:'OS 명령 주입 (/etc/passwd)'};
  if(l.indexOf('/bin/bash')>=0)return {token:'/bin/bash',why:'OS 명령 주입 (/bin/bash)'};
  if(l.indexOf('/bin/sh')>=0)return {token:'/bin/sh',why:'OS 명령 주입 (/bin/sh)'};
  if(l.indexOf('; cat ')>=0||l.indexOf('| cat ')>=0||l.indexOf('&& cat ')>=0)return {token:'cat ',why:'OS 명령 주입 (cat)'};
  if(l.indexOf('{{')>=0&&l.indexOf('}}')>=0)return {token:'{{',why:'서버 템플릿 인젝션 (SSTI)'};
  if(l.indexOf('../')>=0||l.indexOf('..\\')>=0)return {token:'../',why:'경로 탐색 (Path Traversal)'};
  var sql=[' union select ','sleep(','benchmark(',"' or 1=1",'" or 1=1'];for(var i=0;i<sql.length;i++)if(l.indexOf(sql[i])>=0)return {token:sql[i].trim(),why:'SQL 인젝션'};
  if(l.indexOf('<script')>=0)return {token:'<script',why:'XSS'};
  if(l.indexOf('javascript:')>=0)return {token:'javascript:',why:'XSS'};
  var ns=['$where','$regex','$ne'];for(var j=0;j<ns.length;j++)if(l.indexOf(ns[j])>=0)return {token:ns[j],why:'NoSQL 인젝션'};
  return null;}
function wafxClassify(r){ // 반환: null(정상/404) 또는 차단 안내 객체
  if(!wafxValid(r.endpoint))return null;            // 경로 없음 → 404, 막지 않음
  if(r.waf==='BLOCK')return null;                   // 이미 막힘
  var hl=(r.header||'').toLowerCase(), val=r.value||'';
  if(hl==='query-string'||hl==='querystring'){var qi=wafxQueryInfo(val);if(!qi)return null;return {type:'QUERY',header:'query-string',value:wafxDecodeQuery(val),token:qi.token,why:qi.why,endpoint:r.endpoint};}
  if((r.verdict||'').indexOf('403')===0){           // 스크립트가 이미 403대상으로 판정
    if(/uagent|ua/i.test(r.verdict)||hl==='user-agent')return {type:'UA',header:'user-agent',value:val,why:'악성 User-Agent'};
    if(/xff/i.test(r.verdict)||hl==='x-forwarded-for')return {type:'XFF',header:'x-forwarded-for',value:val,why:'X-Forwarded-For 위조'};
    return {type:'HDR',header:hl,value:val,why:'비정상 헤더'};
  }
  // 판정이 OK여도(=새 공격) 의심 행 잡기
  if(hl==='user-agent'){var lv=val.toLowerCase();
    if(WAFX_SCAN.some(function(s){return lv.indexOf(s)>=0}))return {type:'UA',header:'user-agent',value:val,why:'스캐너/도구 UA'};
    if(WAFX_GOODUA.some(function(g){return lv.indexOf(g)>=0}))return null; // 정상 브라우저/도구
    if(lv.trim()==='')return {type:'UA',header:'user-agent',value:val,why:'빈 User-Agent'};
    return null; // 모르는 UA는 섣불리 안 막음(오차단 방지)
  }
  if(hl==='x-forwarded-for'&&/(^|[ ,])(127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)/.test(val))return {type:'XFF',header:'x-forwarded-for',value:val,why:'내부/루프백 IP 삽입'};
  // 화이트리스트 외 헤더는, 값이 "쓰레기처럼 길거나(X-Junk류) 같은 문자 반복"일 때만 차단
  // (sec-ch-ua 같은 짧은 정상 브라우저 헤더 오탐 방지)
  if(!WAFX_NORMHDR[hl]&&(val.length>=24||/(.)\1{7,}/.test(val)))return {type:'HDR',header:hl,value:val,why:'비정상 헤더(과도/쓰레기 값)'};
  return null;
}
// waf.tf 는 변수 기반 — 룰 HCL 이 아니라 terraform.tfvars 에 넣을 "값"을 제안한다.
// ⚠ 리스트 변수는 기본값을 덮어쓰므로, 항상 기본값+새것 전체를 나열해서 출력.
var WAFX_DEF_UA=['sqlmap','nikto','nmap','masscan','acunetix','havij','nuclei','wpscan','dirbuster','gobuster','attack'];
var WAFX_DEF_HDR=['x-junk'];
function wafxTfvars(list){return '['+list.map(function(x){return '"'+x+'"'}).join(', ')+']';}
function wafxRule(f){
  if(f.type==='QUERY')return {title:'비정상 쿼리스트링: '+esc(f.value),
    note:'자동 적용하지 않음. 확인 후 terraform/terraform.tfvars 의 기존 목록과 병합:',
    hcl:'waf_blocked_query_patterns = '+wafxTfvars([f.token])};
  if(f.type==='UA'){var tok=(f.value||'').toLowerCase().replace(/[^a-z0-9].*$/,'')||'badtool';
    var ua=WAFX_DEF_UA.slice();if(ua.indexOf(tok)<0)ua.push(tok);
    return {title:'악성 UA: '+esc(f.value),
      note:(WAFX_DEF_UA.indexOf(tok)>=0?'이미 기본값에 포함 — tfvars 로 덮어쓴 적 없다면 이미 차단 중. 아니면 아래로 복원:':'terraform/terraform.tfvars 에 (기본값+새 단어 전체):'),
      hcl:'waf_blocked_user_agents = '+wafxTfvars(ua)};}
  if(f.type==='XFF'){return {title:'XFF 위조: '+esc(f.value),
      note:'기본값이 이미 true — tfvars 에서 false 로 껐다면 다시 켜기:',
      hcl:'waf_block_private_xff = true'};}
  // HDR: 헤더 존재 시 차단
  var hd=WAFX_DEF_HDR.slice();if(hd.indexOf(f.header)<0)hd.push(f.header);
  return {title:'비정상 헤더: '+esc(f.header),
    note:(WAFX_DEF_HDR.indexOf(f.header)>=0?'이미 기본값에 포함 — 덮어쓴 적 없다면 이미 차단 중.':'terraform/terraform.tfvars 에 (기본값+새 헤더 전체, 소문자):'),
    hcl:'waf_blocked_headers = '+wafxTfvars(hd)};}
function wafxTest(f,ep){ep=ep||'http://<endpoint>';var q='/v1/user?email=x@x.org&requestid=1&uuid=7c5a3c6a-758f-4bc5-9bdf-3e573a0ad729';
  if(f.type==='QUERY')return 'curl.exe -s -o NUL -w "%{http_code}\\n" "'+ep+(f.endpoint||'/v1/product')+'?'+encodeURI(f.value)+'"   # 룰 적용 전 200, 적용 후 403';
  if(f.type==='UA')return 'curl.exe -s -o NUL -w "%{http_code}\\n" -H "User-Agent: '+f.value+'" "'+ep+q+'"   # 403';
  if(f.type==='XFF')return 'curl.exe -s -o NUL -w "%{http_code}\\n" -H "X-Forwarded-For: 10.0.0.1" "'+ep+q+'"   # 403';
  return 'curl.exe -s -o NUL -w "%{http_code}\\n" -H "'+f.header+': 1" "'+ep+q+'"   # 403';}
function wafxRun(){var text=document.getElementById('wafx_in').value;var ep=document.getElementById('wafx_ep').value.trim();
  var rows=wafxParse(text);
  if(!rows.length){document.getElementById('wafx_out').innerHTML='<div class=mut style="padding:10px">표 행을 못 읽었어요. waf_header_stats.py의 "전체" 표(또는 .csv)를 그대로 붙여넣어 주세요.</div>';return;}
  // 같은 헤더/값이 이미 BLOCK 으로도 나오면 = 이미 막는 중 → ALLOW 잔재는 제외(룰 적용 전 옛 기록)
  var blocked={};
  rows.forEach(function(r){if(r.waf==='BLOCK'&&wafxValid(r.endpoint)){var hl=(r.header||'').toLowerCase();blocked[hl+'|'+(hl==='user-agent'?(r.value||'').toLowerCase():'')]=1;}});
  var seen={},finds=[];
  rows.forEach(function(r){var f=wafxClassify(r);if(!f)return;
    if(blocked[f.header+'|'+(f.type==='UA'?(f.value||'').toLowerCase():'')])return;  // 이미 막히는 중
    var kval=f.type==='HDR'?'':(f.type==='QUERY'?f.token:f.value);var key=f.type+'|'+f.header+'|'+kval;if(seen[key])return;seen[key]=1;finds.push(f);});
  if(!finds.length){document.getElementById('wafx_out').innerHTML='<div class="tip good"><h3>막을 게 없습니다 👍</h3><div class=why>유효 경로로 들어온 비정상 요청 중 안 막힌 게 없어요. (없는 경로는 404가 정답이라 무시)</div></div>';return;}
  var out='<div class="tip warn"><h3>검토할 차단 후보 '+finds.length+'개</h3><div class=why>헤더와 ALLOW 쿼리스트링을 분석해 설정 방법만 표시합니다. 자동 적용하지 않습니다. 적용하려면 사용자가 terraform/terraform.tfvars 에 병합 후 apply 하세요.</div></div>';
  finds.forEach(function(f){var ru=wafxRule(f);
    out+='<div class=card style="margin-bottom:12px"><div class=lbl>'+esc(f.why)+'</div>'
      +'<div style="font-size:12.5px;margin-bottom:7px">'+ru.title+'</div>'
      +'<div class=mut style="font-size:12px;margin-bottom:4px">① 변수 — '+ru.note+'</div>'
      +'<pre style="margin:0 0 9px;background:#f6f7f9;border:1px solid var(--line);border-radius:8px;padding:9px 11px;font-size:11.5px;white-space:pre-wrap;color:#1a1d23;overflow-x:auto">'+esc(ru.hcl)+'</pre>'
      +'<div class=mut style="font-size:12px;margin-bottom:4px">② 적용 후 테스트 (403 떠야 함)</div>'
      +'<pre style="margin:0;background:#f6f7f9;border:1px solid var(--line);border-radius:8px;padding:9px 11px;font-size:11.5px;white-space:pre-wrap;color:#1a1d23;overflow-x:auto">'+esc(wafxTest(f,ep))+'</pre></div>';});
  out+='<div class="tip dim"><h3>적용 순서</h3><div class=why>1) 위 변수 줄들을 terraform/terraform.tfvars 에 추가·병합 (같은 변수는 한 줄로 합치기)\n2) cd terraform; terraform apply -auto-approve\n3) 위 curl 로 403 확인, 없는 경로(/.env)는 404 확인\n4) waf_header_stats.py 다시 돌려 붙여넣고 「막을 게 없습니다」 나올 때까지 반복\n5) 대시보드 avail% 100% 유지(정상 오차단 없는지) — 오차단이면 그 변수만 되돌려 apply\n※ 확신 없으면 waf_custom_rule_action = "count" 로 먼저 관찰 (확인 후 반드시 "block" 복귀)</div></div>';
  document.getElementById('wafx_out').innerHTML=out;}
// ---- 튜닝적용 탭: legacy 앱별 출력 붙여넣기 → 라이브 적용 + 정확한 롤백 명령 ----
// autotune.ps1 마지막 출력 예:
//   ### terraform/k8s_apps.tf 반영값 (stress 만):
//     requests.cpu = "300m",  HPA averageUtilization = 45,  min=3 max=12
function tuneParse(text){
  // 필드 순서와 출력 형식에 의존하지 않고 반드시 앱별로 파싱한다.
  // 대상 앱을 알 수 없는 값 하나를 모든 앱에 복제하는 fallback은 절대 사용하지 않는다.
  var known=(D&&D.apps?D.apps.map(function(a){return a.app}):['user','product','stress']);
  var items=[], m;
  function field(body,re){var x=body.match(re);return x?+x[1]:null;}
  function parseFields(app,body){
    app=(app||'').toLowerCase();
    if(known.indexOf(app)<0)return null;
    var cpu=field(body,/(?:requests\.cpu|request|cpu)\s*=\s*"?(\d+)m"?/i);
    var util=field(body,/(?:average_?utilization|averageUtilization|target|util)\s*=\s*(\d+)%?/i);
    var mn=field(body,/(?:min_?replicas|min)\s*=\s*(\d+)/i);
    var mx=field(body,/(?:max_?replicas|max)\s*=\s*(\d+)/i);
    // 부분값도 허용한다. tfvars 는 필드 단위 병합이라(apps.tf), 안 적은 값은 apps/
    // app_defaults 로 자연히 채워진다. 단 아무 값도 없으면(넷 다 null) 무시한다.
    // request 는 요약 출력(request=..m target=..%)에서 오는 핵심 두 값 중 하나다.
    if(cpu===null&&util===null&&mn===null&&mx===null)return null;
    return {app:app,cpu:(cpu!==null?cpu+'m':null),util:util,min:mn,max:mx};
  }
  function add(x){
    if(!x)return;
    for(var i=0;i<items.length;i++){if(items[i].app===x.app){items[i]=x;return;}}
    items.push(x);
  }

  // 1) 하단 Terraform 반영 줄 / 화살표 요약 — 필드 순서는 자유롭다.
  // stress: requests.cpu="375m", min_replicas=2, max_replicas=17, average_utilization=52
  // user → cpu=200m util=50% min=3 max=17
  var row=/^[\s#]*([a-z0-9][a-z0-9-]*)\s*(?::|→|->)\s*([^\r\n]+)$/gim;
  while((m=row.exec(text))!==null)add(parseFields(m[1],m[2]));
  if(items.length)return {items:items};

  // 2) advise.py 앱별 블록. "권장:" 한 줄만 읽어 현재/CPU 설명의 숫자와 섞이지 않게 한다.
  var block=/\[([a-z0-9][a-z0-9-]*)\]([\s\S]*?)(?=\n\s*\[[a-z0-9][a-z0-9-]*\]|$)/gi;
  while((m=block.exec(text))!==null){
    if(/변경\s*없음/.test(m[2]))continue;
    var rec=m[2].match(/권장\s*:\s*([^\r\n]+)/i);
    if(rec)add(parseFields(m[1],rec[1]));
  }
  if(items.length)return {items:items};

  // 3) 구형 autotune 단일값 형식은 명시적인 대상 범위가 있을 때만 허용한다.
  var one=parseFields(known[0],text);
  if(!one)return {items:[],error:'request/target/min/max 중 하나도 읽지 못했습니다. "product: request=100m target=90%" 같은 앱별 줄을 붙여넣어 주세요.'};
  var apps=[];
  var scope=text.match(/반영값\s*\(([^)]*)\)/i);
  if(scope){
    if(/모든\s*앱|all/i.test(scope[1]))apps=known.slice();
    else{
      known.forEach(function(a){if(new RegExp('(?:^|[^a-z0-9-])'+a+'(?:[^a-z0-9-]|$)','i').test(scope[1]))apps.push(a);});
    }
  }
  if(!apps.length){
    var seen={}, dep=/deploy\/([a-z0-9][a-z0-9-]*)/gi;
    while((m=dep.exec(text))!==null){if(known.indexOf(m[1].toLowerCase())>=0)seen[m[1].toLowerCase()]=1;}
    apps=Object.keys(seen);
  }
  if(!apps.length)return {items:[],error:'대상 앱을 찾지 못했습니다. 앱별 권장 줄을 함께 붙여넣어 주세요. 전체 앱으로 추정 적용하지 않습니다.'};
  apps.forEach(function(app){items.push({app:app,cpu:one.cpu,util:one.util,min:one.min,max:one.max});});
  return {items:items};
}
function tuneCmds(f){
  var items=(f&&f.items)?f.items:[];
  if(!items.length){
    return '<div class="tip warn"><h3>값을 못 읽었어요</h3><div class=why>'
      +esc((f&&f.error)||'앱별 값이 있는 줄을 붙여넣어 주세요. 예) product: request=100m target=90%')
      +'<br>대상 앱이 없는 단일값은 안전을 위해 전체 앱에 복제하지 않습니다.</div></div>';
  }
  var out='<div class="tip good"><h3>적용 대상: '+items.map(function(x){return x.app}).join(', ')+'</h3>'
    +'<div class=why>'+items.map(function(x){
        var p=[]; if(x.cpu!=null)p.push('cpu='+x.cpu); if(x.util!=null)p.push('util='+x.util+'%');
        if(x.min!=null)p.push('min='+x.min); if(x.max!=null)p.push('max='+x.max);
        return x.app+' → '+p.join(' ');
      }).join('\n')+'</div></div>';
  var ns=(D&&D.namespace)||'app';
  // ⚠ 클러스터를 kubectl 로 직접 고치지 않는다. tuning/apply.ps1 로 tuning.auto.tfvars.json
  //   에 기록하고 terraform 이 반영한다(드리프트 방지). 붙여넣은 값에 없는 필드(min/max 등)는
  //   명령에 넣지 않으므로 apps/app_defaults 값이 유지된다.
  function applyCmd(app,x){
    var a=[".\\apply.ps1 -App "+app];
    if(x.cpu!=null)a.push("-Request "+String(x.cpu).replace('m',''));
    if(x.util!=null)a.push("-Target "+x.util);
    if(x.min!=null)a.push("-Min "+x.min);
    if(x.max!=null)a.push("-Max "+x.max);
    return a.join(' ');
  }
  // 한 덩어리로: tuning 에서 값 기록 → terraform 으로 반영까지 그대로 붙여넣어 실행.
  var lines=['cd ..\\tuning'];
  items.forEach(function(x){ lines.push(applyCmd(x.app,x)); });
  lines.push('cd ..\\terraform ; terraform apply -target kubernetes_deployment.app -target kubernetes_horizontal_pod_autoscaler_v2.app');
  out+=tuneCmdBlock('복사해서 그대로 실행 (기록 → 반영)', lines);
  out+='<div class="tip dim"><h3>참고</h3><div class=why>'
    +'apply.ps1 은 tuning.auto.tfvars.json 에 값을 기록만 하고, 실제 반영은 마지막 terraform apply 가 한다. '
    +'되돌리기는 <code>.\\rollback.ps1</code> (기록 제거 → apps 기본값 복귀). '
    +'Terraform 이 단일 진실 공급원이라 드리프트가 없다.</div></div>';
  return out;
}
function tuneRun(){
  var f=tuneParse(document.getElementById('tune_in').value);
  document.getElementById('tune_out').innerHTML=tuneCmds(f);
}
function vTuneApply(){
  var live='';
  if(D.tuning&&D.tuning.candidates&&D.tuning.candidates.length){
   live='<div class=card style="margin-bottom:15px"><h2>공통 엔진 라이브 후보 — 공식 총점 기준</h2><div class=mut style="font-size:12px;margin-bottom:9px">아래 명령은 현재 라이브 snapshot 기준입니다. request 변경은 rollout을 일으키므로 공식 트래픽 전에만 실행하세요.</div>'
    +D.tuning.candidates.map(function(c,i){return '<div class=card style="margin-bottom:10px"><div class=lbl>#'+(i+1)+' '+esc(c.kind)+' · '+esc(c.app)+'</div><div class=mut>'+esc(c.reason)+'</div>'+tuneCmdBlock('① 적용',c.apply_commands)+tuneCmdBlock('② 점수 미개선/오류 시 롤백',c.rollback_commands)+'</div>'}).join('')+'</div>';
  }
  return live+'<div class=card><h2>튜닝적용 — 앱별 권장값으로 적용 명령 만들기</h2>'
   +'<div class=mut style="font-size:12px;margin-bottom:9px"><code>.\\autotune.ps1 -Result baseline</code> 출력의 <b>「수동 반영할 값」 앱별 줄</b>을 붙여넣고 [명령 생성]. 출력에 없는 앱은 적용 대상에서 제외합니다. 대시보드는 값을 자동 적용하지 않습니다.</div>'
   +'<textarea id=tune_in placeholder=\'예) stress: requests.cpu="375m", min_replicas=2, max_replicas=17, average_utilization=52\nuser: requests.cpu="200m", min_replicas=2, max_replicas=17, average_utilization=50\' style="width:100%;height:130px;background:#f6f7f9;color:#1a1d23;border:1px solid var(--line);border-radius:8px;padding:10px;font-size:12px;font-family:monospace"></textarea>'
   +'<button onclick="tuneRun()" style="margin-top:10px">명령 생성</button>'
   +'<div id=tune_out style="margin-top:15px"></div></div>';}

function vWafAnalyze(){
  return '<div class=card><h2>WAF분석 — 헤더·쿼리스트링 분석과 차단 방법 안내</h2>'
   +'<div class=mut style="font-size:12px;margin-bottom:9px"><code>python waf_header_stats.py --log-group aws-waf-logs-&lt;project&gt; --region us-east-1 --hours 1</code> 출력을 통째로 붙여넣고 [분석]. 헤더와 <b>ALLOW 요청 쿼리스트링</b>을 함께 표시하고, 고위험 패턴의 Terraform 설정 방법만 안내합니다. 대시보드는 WAF를 자동 변경하지 않습니다.</div>'
   +'<div style="margin-bottom:8px">엔드포인트(테스트 명령용): <input id=wafx_ep type=text placeholder="http://xxxx.cloudfront.net" style="width:320px;background:var(--card2);color:var(--txt);border:1px solid var(--line);border-radius:7px;padding:6px 9px"></div>'
   +'<textarea id=wafx_in placeholder="여기에 waf_header_stats.py 출력 붙여넣기..." style="width:100%;height:200px;background:#f6f7f9;color:#1a1d23;border:1px solid var(--line);border-radius:8px;padding:10px;font-size:12px;font-family:monospace"></textarea>'
   +'<button onclick="wafxRun()" style="margin-top:10px">분석</button>'
   +'<div id=wafx_out style="margin-top:15px"></div></div>';}

function tabs(){var t=[['overview','개요']].concat(D.apps.map(function(a){return [a.app,a.app]})).concat([['pods','Pod'],['nodes','노드'],['waf','WAF'],['wafx','WAF분석'],['calc','계산'],['tune','튜닝적용'],['diag','진단']]);
 document.getElementById('tabs').innerHTML=t.map(function(x){return '<div class="tab'+(x[0]===TAB?' on':'')+'" onclick="setTab(\''+x[0]+'\')">'+x[1]+'</div>'}).join('')}
function render(){if(!D)return;var v=document.getElementById('view');
 // 붙여넣기 탭(WAF분석/튜닝적용)은 한 번 만들면 유지 (자동 갱신이 입력을 안 지우게)
 if(TAB==='wafx'){if(!document.getElementById('wafx_in'))v.innerHTML=vWafAnalyze();return;}
 if(TAB==='tune'){if(!document.getElementById('tune_in'))v.innerHTML=vTuneApply();return;}
 // 자동 갱신 시 열어둔 상세 패널을 유지 (새 항목은 위에 쌓이고, 보던 건 그대로 열림)
 var ok={};document.querySelectorAll('details.det[open]').forEach(function(d){ok[d.dataset.k]=1});
 if(TAB==='overview')v.innerHTML=vOverview();else if(TAB==='pods')v.innerHTML=vPods();else if(TAB==='nodes')v.innerHTML=vNodes();
 else if(TAB==='waf')v.innerHTML=vWaf();else if(TAB==='calc')v.innerHTML=vCalc();else if(TAB==='diag')v.innerHTML=vDiag();
 else{var a=D.apps.find(function(x){return x.app===TAB});v.innerHTML=a?vApp(a):''}
 document.querySelectorAll('details.det').forEach(function(d){if(ok[d.dataset.k])d.open=true});}
function setTab(t){TAB=t;tabs();render()}
// ---- 최상단 경고 배너: 가용성 게이트/오차단/5xx 를 눈에 띄게 (기존 데이터 재활용) ----
function renderAlerts(){
 var el=document.getElementById('alerts');if(!el){return;}
 if(!D){el.innerHTML='';return;}
 var al=[];
 // WAF 가 차단 중인 정상 경로 집합 (공격이 유효경로를 때리는 건 정상 → 그 자체론 경고 X)
 var wafPaths={};
 if(D.waf&&D.waf.enabled&&D.waf.by_uri){D.waf.by_uri.forEach(function(u){var p=(u[0]||'').split('?')[0];if(/^\/(v1\/(user|product|stress)|healthcheck)$/.test(p))wafPaths[p]=u[1];});}
 // (1) 가용성 게이트: 요청 있는 앱 중 성공률 99% 미만. 그 앱 경로가 WAF 차단 중이면 오차단 의심 병기.
 (D.apps||[]).forEach(function(a){
   if(a.total>0 && a.ok_rate<99){
     var why='요청 실패/5초초과. 비용보다 먼저 cpu↑/min↑ (해당 앱 탭·계산 참고).';
     if(wafPaths['/v1/'+a.app]) why+='\n🚫 WAF 오차단 가능성 — 이 경로가 WAF 차단 로그에 '+wafPaths['/v1/'+a.app]+'건 있음. 정상요청이 403이면 avail 폭락 → waf 커스텀 룰 count/해제 검토.';
     al.push(['bad','⛔ 가용성 게이트 — '+a.app+' '+a.ok_rate+'% < 99%',why]);
   }
 });
 // (2) 5xx
 var c5=(D.summary&&D.summary.c5)||0;
 if(c5>0) al.push(['warn','⚠ 5xx '+c5+'건 — 앱/DB 오류 가능 (진단 탭 확인)','']);
 if(!al.length){el.innerHTML='';return;}
 el.innerHTML=al.map(function(t){return '<div class="tip '+t[0]+'" style="margin:10px 0 0"><h3>'+t[1]+'</h3>'+(t[2]?'<div class=why>'+t[2]+'</div>':'')+'</div>'}).join('');
}
// ---- 원클릭 스모크: 서버가 엔드포인트에 200/403/404 검증 ----
async function smoke(){
 var el=document.getElementById('alerts');
 if(el)el.innerHTML='<div class="tip dim" style="margin:10px 0 0"><h3>스모크 실행 중…</h3></div>';
 try{
  var r=await fetch('/api/smoke');var d=await r.json();
  if(d.error){el.innerHTML='<div class="tip bad" style="margin:10px 0 0"><h3>스모크 실패</h3><div class=why>'+esc(d.error)+'</div></div>';return;}
  var rows=d.checks.map(function(c){var cl=c.pass?'gd':'bd';var mk=c.pass?'✓':'✗';
    return '<div class=row><span>'+mk+' '+esc(c.name)+' <span class=mut>'+esc(c.url)+'</span></span><span class="'+cl+'">'+c.got+' (기대 '+c.expect+')</span></div>'}).join('');
  var allok=d.checks.every(function(c){return c.pass});
  el.innerHTML='<div class="tip '+(allok?'good':'bad')+'" style="margin:10px 0 0"><h3>스모크 '+(allok?'전부 통과 👍':'실패 항목 있음')+' <span class=mut style="font-weight:400">'+esc(d.endpoint)+'</span></h3>'+rows+'</div>';
 }catch(e){el.innerHTML='<div class="tip bad" style="margin:10px 0 0"><h3>스모크 오류</h3><div class=why>'+esc(''+e)+'</div></div>';}
}
function setSt(x,c){document.getElementById('st').innerHTML='<span class=dot style="background:'+c+'"></span>'+x}
async function load(){setSt('불러오는 중','#ffcf5c');var s=document.getElementById('since').value;
 try{var r=await fetch('/api/data?since='+s);D=await r.json();tabs();render();renderAlerts();setSt('갱신 '+D.ts,'#3ddc97')}catch(e){setSt('연결 오류','#ff5c7a')}}
var tm=null;function setAuto(){if(tm)clearInterval(tm);var s=+document.getElementById('auto').value;if(s)tm=setInterval(load,s*1000)}
document.getElementById('auto').onchange=setAuto;document.getElementById('since').onchange=load;
load();setAuto();
</script></body></html>"""


DEMO = False


def demo_data():
    """클러스터 없이 레이아웃/탭을 보기 위한 샘플 스냅샷 (build_data 와 같은 형태)."""
    import time as _t
    from datetime import datetime as _dt, timezone as _tz

    def app_row(name, slo, total, ok, slo_rate, p50, p95, p99, cpu):
        c2 = ok
        c4 = total - ok
        return {"app": name, "total": total, "hc": 120, "c2": c2, "c4": c4, "c5": 0,
                "ok_rate": round(100.0 * ok / total, 1), "err_rate": round(100.0 * c4 / total, 1),
                "status": {200: ok, 404: c4}, "slo_ms": slo, "slo_rate": slo_rate,
                "p50": p50, "p95": p95, "p99": p99, "max": p99 + 40,
                "paths": [("/v1/" + name, total)], "err_paths": ([[["/v1/" + name, 404], c4]] if c4 else []),
                "top_ips": [("10.20.1.5", total)],
                "recent2": [{"ts": "12:00:0" + str(i), "m": "GET", "path": "/v1/" + name, "st": 200,
                             "dur": p50, "ip": "10.20.1.5", "why": "", "requestid": "1", "uuid": "u", "raw": ""} for i in range(3)],
                "recent4": [], "recent5": [], "cpu_req": cpu}

    apps = [
        app_row("user", 200, 5400, 5400, 99.6, 41, 58, 71, "200m"),
        app_row("product", 200, 5400, 5390, 97.4, 39, 120, 190, "200m"),
        app_row("stress", 1000, 720, 720, 96.9, 630, 940, 980, "300m"),
    ]
    pods = [{"name": f"{a}-abc{i}", "app": a, "phase": "Running", "ready": True, "restarts": 0,
             "reason": "", "node": f"ip-10-20-{i}", "cpu": "180m", "mem": "90Mi"}
            for a in ("user", "product", "stress") for i in (1, 2)]
    nodes = [{"name": f"ip-10-20-{i}.node", "type": "t3.medium", "karpenter": i > 2, "ready": "Ready",
              "cpu": "780m", "cpu_pct": "40%", "mem": "1.1Gi", "mem_pct": "35%"} for i in (1, 2, 3)]
    hpa = [{"name": a, "cur": "38%", "tgt": "60%", "min": 2, "max": 10, "replicas": 2}
           for a in ("user", "product", "stress")]
    waf = {"enabled": True, "total": 54,
           "by_reason": [("악성 User-Agent (스캐너/공격도구)", 31), ("SQL 인젝션 의심", 15), ("비정상 헤더 존재(차단 목록): x-junk", 8)],
           "by_rule": [("BlockedUserAgents", 31), ("AWSManagedRulesSQLiRuleSet", 15)],
           "by_ip": [("203.0.113.9", 40), ("198.51.100.2", 14)],
           "by_uri": [("/v1/user", 30), ("/v1/product", 24)],
           "by_method": [("GET", 39), ("POST", 15)],
           "recent": [{"ts": "12:00:01", "ip": "203.0.113.9", "m": "GET", "uri": "/v1/user", "args": "",
                       "url": "https://demo.cloudfront.net/v1/user?email=x", "country": "US",
                       "reason": "악성 User-Agent (스캐너/공격도구)", "ua": "sqlmap/1.7", "xff": ""}]}
    summary = {"allow": 11520, "block": 54, "c2": 11510, "c4": 10, "c5": 0,
               "pods_total": 6, "pods_ready": 6, "nodes_total": 3, "nodes_karp": 1}
    diag = [["good", "이상 없음 (데모)", "샘플 데이터입니다. 실제 값은 클러스터 연결 시 표시됩니다.", ""]]
    return {"apps": apps, "pods": pods, "nodes": nodes, "hpa": hpa, "waf": waf,
            "summary": summary, "diag": diag,
            "ts": _dt.fromtimestamp(_t.time(), _tz.utc).astimezone().strftime("%H:%M:%S") + " (demo)"}


@app.route("/")
def index():
    return Response(PAGE, mimetype="text/html")


def _add_tuning_plan(data, since="15m"):
    """대시보드 폴링값을 공통 엔진 snapshot으로 바꿔 공식 점수/후보를 붙인다."""
    data["namespace"] = monitor.CFG["ns"]
    for pod in data.get("pods", []):
        if pod.get("phase") == "Running" and pod.get("app") and pod.get("cpu") not in (None, "-", ""):
            _TUNE_CPU_HISTORY[pod["app"]].append(pod["cpu"])
    try:
        snapshot = tuning_engine.snapshot_from_dashboard(
            data, baseline_nodes=float(os.environ.get("TUNE_BASELINE_NODES", "2")),
            cpu_history={name: list(values) for name, values in _TUNE_CPU_HISTORY.items()},
            availability_gate=99.0,
            window_seconds=float(monitor._mins(since)) * 60.0,
            system_reserved_m=(0 if DEMO else _system_reserved_cached()),
        )
        data["tuning"] = tuning_engine.plan(snapshot, namespace=monitor.CFG["ns"])
    except Exception as exc:
        data["tuning"] = {"schema_version": 1, "done": True, "reason": "튜닝 엔진 오류: " + str(exc),
                          "score": {}, "apps": [], "cluster": {}, "candidates": [], "best": None}
    return data


@app.route("/api/data")
def api_data():
    if DEMO:
        return jsonify(_add_tuning_plan(demo_data()))
    since = request.args.get("since", "15m")
    return jsonify(_add_tuning_plan(monitor.build_data(since, monitor._mins(since)), since))


def _tf_endpoint():
    """../terraform 의 terraform output -raw endpoint (자동 감지)."""
    import os
    import subprocess
    tfdir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "terraform")
    try:
        out = subprocess.run(["terraform", f"-chdir={tfdir}", "output", "-raw", "endpoint"],
                             capture_output=True, text=True, timeout=15).stdout.strip()
        return out.splitlines()[0].strip() if out else ""
    except Exception:
        return ""


@app.route("/api/smoke")
def api_smoke():
    """엔드포인트 스모크: 정상 200 / 비정상 403 / 미정의 404 검증."""
    import urllib.request
    import urllib.error
    ep = (request.args.get("ep") or _tf_endpoint()).rstrip("/")
    if not ep:
        return jsonify({"error": "엔드포인트를 못 찾음 — ?ep=http://... 로 전달하거나 terraform output endpoint 확인"})

    def hit(path, expect, ua=None):
        url = ep + path
        req = urllib.request.Request(url, headers={"User-Agent": ua} if ua else {})
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                got = r.status
        except urllib.error.HTTPError as e:
            got = e.code
        except Exception as e:
            return {"name": path, "url": url, "expect": expect, "got": "ERR", "pass": False, "err": str(e)[:80]}
        return {"name": path, "url": url, "expect": expect, "got": got, "pass": got == expect}

    checks = [
        hit("/healthcheck", 200),
        hit("/v1/none", 404),                                    # 미정의 경로 → 404
        hit("/.env", 404),                                       # 없는 경로 → 404 (403 아님)
        hit("/v1/user?email=x@x.org&requestid=1&uuid=1", 403, ua="sqlmap/1.7"),  # 스캐너 UA → 403
    ]
    return jsonify({"endpoint": ep, "checks": checks})


def main():
    # 한국어 Windows 콘솔은 기본 cp949 라서 도움말/로그의 em dash(—) 같은 문자에서
    # UnicodeEncodeError 로 죽는다(실측: python dashboard.py --help 가 실패).
    # 출력 스트림을 UTF-8 로 바꿔 --help 와 로그가 항상 나오게 한다.
    for _s in (sys.stdout, sys.stderr):
        try:
            _s.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass
    global DEMO
    ap = argparse.ArgumentParser(description="3과제 모니터링 대시보드 (Flask)")
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--host", default="127.0.0.1",
                    help="바인딩 주소. 기본 127.0.0.1(로컬만). 이 대시보드는 인증이 없으므로 "
                         "0.0.0.0 은 같은 네트워크의 누구나 클러스터 정보를 보게 된다 — 필요할 때만 지정")
    ap.add_argument("--namespace", default="app")
    ap.add_argument("--waf-log-group", default="aws-waf-logs-wsi2026")
    ap.add_argument("--waf-region", default="us-east-1")
    ap.add_argument("--slos-ms", default="", help="앱별 SLO(ms): user=200,product=200,stress=1000")
    ap.add_argument("--demo", action="store_true", help="클러스터 없이 샘플 데이터로 레이아웃 확인")
    a = ap.parse_args()
    DEMO = a.demo
    monitor.CFG["ns"] = a.namespace
    monitor.CFG["waf_group"] = a.waf_log_group
    monitor.CFG["waf_region"] = a.waf_region
    monitor.SLO_MS.update(monitor.parse_slos_ms(a.slos_ms))
    mode = " [DEMO]" if DEMO else ""
    print("3과제 모니터링(Flask)%s  http://%s:%d  (Ctrl+C 종료)" % (mode, a.host, a.port))
    app.run(host=a.host, port=a.port, threaded=True)


if __name__ == "__main__":
    main()