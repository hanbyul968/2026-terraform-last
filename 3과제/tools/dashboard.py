#!/usr/bin/env python3
"""3과제 모니터링 대시보드 (Flask · 다크 UI).
데이터 수집은 monitor.py 함수를 재사용. 시간창 1/5/10/15/20/25/30분 선택 + 자동 갱신.

설치:  pip3 install flask   (CloudShell: pip3 install --user flask)
실행:  python3 dashboard.py --namespace app --waf-log-group aws-waf-logs-wsi2026b
       → http://<host>:8080
"""
import argparse
from flask import Flask, jsonify, request, Response
import monitor  # 같은 폴더의 monitor.py (수집/진단 로직 재사용)

app = Flask(__name__)

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
 +'<div class=row><span>성공률</span><span class="'+o+'">'+a.ok_rate+'%</span></div>'
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
 +'<div class=card><div class=lbl>성공률 2xx</div><div class="kpi '+o+'">'+a.ok_rate+'%</div></div>'
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

// ---- 계산 탭: 라이브 데이터로 자동 판정 (줄여/늘려/유지) ----
function cpuM(s){if(s===undefined||s===null||s==='')return 0;s=''+s;return s.slice(-1)==='m'?parseInt(s):Math.round(parseFloat(s)*1000)}
function pctn(s){var n=parseInt((''+(s||'')).replace('%',''));return isNaN(n)?null:n}
function hpaOf(n){return (D.hpa||[]).find(function(h){return h.name===n})||{}}
function vCalc(){
 var apps=D.apps||[];var ALLOC=1900;var sMin=0,sMax=0,sMinCpu=0;
 var cards=apps.map(function(a){
  var n=a.app,h=hpaOf(n);
  var cpu=cpuM(a.cpu_req),util=pctn(h.tgt)||55,mn=+h.min||0,mx=+h.max||0,rep=+h.replicas||mn,cur=pctn(h.cur);
  var perf=a.slo_rate,avail=a.ok_rate,p95=a.p95,slo=a.slo_ms;
  var dir,cls,rcpu=cpu,rutil=util,rmn=mn,note;
  if(a.total===0){dir='관측 필요';cls='mut';note='요청이 없어 판단 불가 — loadtest로 부하를 준 뒤 보세요.';}
  else if(avail<99){dir='늘려 ↑';cls='bd';rcpu=Math.round(cpu*1.5/50)*50;rmn=mn+1;rutil=Math.max(40,util-5);note='가용성 '+avail+'% (<99) → cpu·min 늘려 (게이트 최우선)';}
  else if(perf<95||(slo&&p95>slo)){dir='늘려 ↑';cls='wn';rcpu=Math.round(cpu*1.4/50)*50;rutil=Math.max(40,util-10);note='성능 '+perf+'% / p95 '+p95+'ms > SLO '+slo+'ms (꼬리지연) → cpu 늘리고 util 낮춰(빨리 스케일)';}
  else if(perf>=99.5&&((cur!==null&&cur<Math.max(15,util*0.4))||(cur===null&&slo&&p95<=slo*0.4))){dir='줄여 ↓';cls='gd';rcpu=Math.max(100,Math.round(cpu*0.75/50)*50);rutil=Math.min(75,util+10);if(mn>2)rmn=mn-1;note='성능 '+perf+'% 여유 + 현재CPU '+(cur===null?'낮음':cur+'%')+' ≪ 목표 '+util+'% → cpu·util'+(mn>2?'·min':'')+' 줄여 비용↓ (과투자)';}
  else{dir='유지';cls='mut';note='균형 (perf '+perf+'%, 현재CPU '+(cur===null?'-':cur+'%')+'/목표'+util+'%)';}
  rmn=Math.max(1,rmn);sMin+=rmn;sMax+=mx;sMinCpu+=rmn*rcpu;
  var ch=[];
  if(rcpu!==cpu)ch.push('requests.cpu <b>'+cpu+'m → '+rcpu+'m</b> '+(rcpu>cpu?'↑':'↓')+' <span class=mut>('+(rcpu>cpu?'파드 1개를 더 세게 → 꼬리지연↓ (노드↑)':'파드당 cpu 낮춰 → 노드↓ (비용↓)')+')</span>');
  if(rutil!==util)ch.push('HPA averageUtilization <b>'+util+'% → '+rutil+'%</b> '+(rutil>util?'↑':'↓')+' <span class=mut>('+(rutil>util?'느긋하게 스케일 → 비용↓':'더 빨리·자주 파드 늘림 → 성능↑')+')</span>');
  if(rmn!==mn)ch.push('min_replicas <b>'+mn+' → '+rmn+'</b> '+(rmn>mn?'↑':'↓')+' <span class=mut>('+(rmn>mn?'부하 초반부터 여유 → 가용성↑':'유휴 파드 줄여 → 비용↓')+')</span>');
  var how=ch.length?ch.map(function(x){return '<div style="padding:3px 0">• '+x+'</div>'}).join(''):'<div class=mut>변경 없음 — 현상 유지</div>';
  var cmds='';
  if(ch.length){
   var patch=JSON.stringify({spec:{minReplicas:rmn,maxReplicas:mx,metrics:[{type:"Resource",resource:{name:"cpu",target:{type:"Utilization",averageUtilization:rutil}}}]}});
   var c='kubectl -n app set resources deploy/'+n+' --requests=cpu='+rcpu+'m\n'
    +'kubectl -n app patch hpa '+n+' --type=merge -p \''+patch.replace(/"/g,'\\"')+'\'\n'
    +'kubectl -n app rollout status deploy/'+n;
   cmds='<div class=lbl style="margin-top:9px;margin-bottom:4px">즉시 적용 명령 (임시 · 재배포 시 사라짐)</div>'
    +'<pre style="margin:0;background:#f6f7f9;border:1px solid var(--line);border-radius:8px;padding:9px 11px;font-size:11.5px;white-space:pre-wrap;color:#1a1d23;overflow-x:auto">'+esc(c)+'</pre>';
  }
  return '<div class=card><div class=lbl>'+n+' &nbsp;<span class='+cls+' style="font-weight:700">'+dir+'</span></div>'
   +'<div class=row><span class=mut>현재</span><span>cpu <b>'+cpu+'m</b> · util '+util+'% · min '+mn+' · max '+mx+' · 파드 '+rep+'</span></div>'
   +'<div class=row><span class=mut>측정</span><span>perf '+perf+'% · avail '+avail+'% · p95 '+p95+'ms · 현재CPU '+(cur===null?'-':cur+'%')+'</span></div>'
   +'<div style="margin-top:9px"><div class=lbl style="margin-bottom:4px">이렇게 바꿔 (k8s_apps.tf)</div><div style="font-size:12.5px">'+how+'</div></div>'
   +cmds
   +'<div class=mut style="font-size:12px;margin-top:8px">근거: '+note+'</div></div>';
 }).join('');
 var nMin=Math.ceil(sMinCpu/ALLOC);
 var summary='<div class="grid g4" style="margin-bottom:15px">'
  +'<div class=card><div class=lbl>권장 정상시 pod 합</div><div class="kpi sm">'+sMin+'</div></div>'
  +'<div class=card><div class=lbl>현재 파드 수</div><div class="kpi sm">'+D.summary.pods_total+'</div></div>'
  +'<div class=card><div class=lbl>권장 정상시 노드(추정)</div><div class="kpi sm">'+nMin+'</div></div>'
  +'<div class=card><div class=lbl>현재 노드</div><div class="kpi sm">'+D.summary.nodes_total+'</div></div></div>';
 return '<div class=lbl style="margin-bottom:9px">라이브 자동 판정 — 부하(loadtest/실트래픽) 도는 중에 봐야 정확합니다</div>'
  +summary+'<div class="grid g3">'+cards+'</div>'
  +'<div class=mut style="margin-top:12px;font-size:12px">권장값을 k8s_apps.tf의 각 앱 requests.cpu / HPA averageUtilization / min_replicas 에 반영 후 apply. 노드 추정 = ⌈Σ(min×cpu)/1900m⌉ (t3.medium). 「줄여 ↓」=과투자(비용↓ 가능), 「늘려 ↑」=성능/가용성 부족.</div>';}

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
// ---- 튜닝적용 탭: autotune 출력 붙여넣기 → 적용 명령(kubectl + k8s_apps.tf) ----
// autotune.ps1 마지막 출력 예:
//   ### terraform/k8s_apps.tf 반영값 (stress 만):
//     requests.cpu = "300m",  HPA averageUtilization = 45,  min=3 max=12
function tuneParse(text){
  var f={};
  var cpu=text.match(/requests\.cpu\s*=\s*"?(\d+)m"?/i);       if(cpu)f.cpu=cpu[1]+'m';
  var util=text.match(/averageUtilization\s*=\s*(\d+)/i);      if(util)f.util=+util[1];
  var mn=text.match(/min\s*=\s*(\d+)/i);                        if(mn)f.min=+mn[1];
  var mx=text.match(/max\s*=\s*(\d+)/i);                        if(mx)f.max=+mx[1];
  // 대상 앱: "반영값 (stress 만)" / "(모든 앱..." 파싱
  var scope=text.match(/반영값\s*\(([^)]*)\)/);
  var apps=(D&&D.apps?D.apps.map(function(a){return a.app}):['user','product','stress']);
  if(scope){
    if(/모든\s*앱|all/i.test(scope[1])) f.apps=apps;
    else { var w=scope[1].trim().split(/[\s,]+/)[0]; f.apps=apps.indexOf(w)>=0?[w]:[w]; }
  }
  return f;
}
function tuneCmds(f){
  if(!f.cpu&&!f.util&&!f.min){return '<div class="tip warn"><h3>값을 못 읽었어요</h3><div class=why>autotune.ps1 의 마지막 "반영값" 줄(예: <code>requests.cpu = "300m", HPA averageUtilization = 45, min=3 max=12</code>)을 통째로 붙여넣어 주세요.</div></div>';}
  var apps=f.apps&&f.apps.length?f.apps:['<앱>'];
  var mn=f.min||2, mx=f.max||10, util=f.util||60, cpu=f.cpu||'?m';
  var out='<div class="tip good"><h3>적용 대상: '+apps.join(', ')+'</h3><div class=why>cpu='+cpu+' · util='+util+'% · min='+mn+' · max='+mx+'</div></div>';
  apps.forEach(function(n){
    var patch=JSON.stringify({spec:{minReplicas:mn,maxReplicas:mx,metrics:[{type:"Resource",resource:{name:"cpu",target:{type:"Utilization",averageUtilization:util}}}]}});
    var imm='kubectl -n app set resources deploy/'+n+' --requests=cpu='+cpu+'\n'
      +'kubectl -n app patch hpa '+n+' --type=merge -p \''+patch.replace(/"/g,'\\"')+'\'\n'
      +'kubectl -n app rollout status deploy/'+n;
    var tf='# terraform/k8s_apps.tf — '+n+'\n'
      +'resources { requests = { cpu = "'+cpu+'", memory = "128Mi" } }   # kubernetes_deployment.'+n+'\n'
      +'min_replicas = '+mn+'\nmax_replicas = '+mx+'\naverage_utilization = '+util+'   # HPA.'+n;
    out+='<div class=card style="margin-bottom:12px"><div class=lbl>'+n+'</div>'
      +'<div class=mut style="font-size:12px;margin:6px 0 4px">① 즉시 적용 (임시 — 재배포 시 사라짐)</div>'
      +'<pre style="margin:0 0 9px;background:#f6f7f9;border:1px solid var(--line);border-radius:8px;padding:9px 11px;font-size:11.5px;white-space:pre-wrap;color:#1a1d23;overflow-x:auto">'+esc(imm)+'</pre>'
      +'<div class=mut style="font-size:12px;margin-bottom:4px">② 영구 반영 (k8s_apps.tf 수정 후 apply)</div>'
      +'<pre style="margin:0;background:#f6f7f9;border:1px solid var(--line);border-radius:8px;padding:9px 11px;font-size:11.5px;white-space:pre-wrap;color:#1a1d23;overflow-x:auto">'+esc(tf)+'</pre></div>';
  });
  out+='<div class="tip dim"><h3>순서</h3><div class=why>① kubectl 로 즉시 적용해 효과 확인 (loadtest 재측정) → 좋으면 ② k8s_apps.tf 에 박고 <code>terraform apply -auto-approve -var "k8s_provider_ready=true"</code>.\n한 번에 한 앱만. avail% 99% 는 사수.</div></div>';
  return out;
}
function tuneRun(){
  var f=tuneParse(document.getElementById('tune_in').value);
  document.getElementById('tune_out').innerHTML=tuneCmds(f);
}
function vTuneApply(){
  return '<div class=card><h2>튜닝적용 — autotune 결과 붙여넣고 적용 명령 받기</h2>'
   +'<div class=mut style="font-size:12px;margin-bottom:9px"><code>.\\autotune.ps1 -App stress</code> 등의 <b>마지막 "반영값" 출력</b>을 붙여넣고 [명령 생성]. kubectl(즉시)·k8s_apps.tf(영구) 명령을 뽑아준다. (라이브 자동판정은 「계산」 탭)</div>'
   +'<textarea id=tune_in placeholder=\'예)  requests.cpu = "300m",  HPA averageUtilization = 45,  min=3 max=12   (반영값 (stress 만) 줄까지 같이 붙여넣으면 앱도 자동 인식)\' style="width:100%;height:130px;background:#f6f7f9;color:#1a1d23;border:1px solid var(--line);border-radius:8px;padding:10px;font-size:12px;font-family:monospace"></textarea>'
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


@app.route("/api/data")
def api_data():
    if DEMO:
        return jsonify(demo_data())
    since = request.args.get("since", "15m")
    return jsonify(monitor.build_data(since, monitor._mins(since)))


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
    global DEMO
    ap = argparse.ArgumentParser(description="3과제 모니터링 대시보드 (Flask)")
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--namespace", default="app")
    ap.add_argument("--waf-log-group", default="aws-waf-logs-wsi2026")
    ap.add_argument("--waf-region", default="us-east-1")
    ap.add_argument("--demo", action="store_true", help="클러스터 없이 샘플 데이터로 레이아웃 확인")
    a = ap.parse_args()
    DEMO = a.demo
    monitor.CFG["ns"] = a.namespace
    monitor.CFG["waf_group"] = a.waf_log_group
    monitor.CFG["waf_region"] = a.waf_region
    mode = " [DEMO]" if DEMO else ""
    print("3과제 모니터링(Flask)%s  http://%s:%d  (Ctrl+C 종료)" % (mode, a.host, a.port))
    app.run(host=a.host, port=a.port, threaded=True)


if __name__ == "__main__":
    main()