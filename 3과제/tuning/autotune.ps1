<#
  config 기반 자동 튜너 (autotune.sh 의 PowerShell 판).
  라이브 클러스터를 patch 하며 조합을 스윕하고(빠름, terraform 재적용 없음),
  각 조합마다 채점 스타일 부하 테스트를 돌려 rubric(성능효율+고가용성+비용)으로 점수화,
  최고 조합을 선언하고 그대로 적용해 둔다.

  두 가지 모드:
    (기본)      각 조합을 config.ps1 의 모든 앱에 동일하게 적용 — 대략적인 방향 탐색.
    -App <앱>   그 앱만 patch, 나머지 앱은 현재 설정 유지 — 앱별 정밀 튜닝.
                점수도 그 앱의 perf 기준(가용성 게이트는 여전히 전체 최소값).
                → 병목 앱을 loadtest 로 찾은 뒤, 그 앱만 -App 으로 돌리는 것을 권장.

  사용법:
    .\autotune.ps1 [-Duration 90s] [-App stress] [-Url http://...]
    (Url 생략 시 config.ps1 의 $ENDPOINT 사용)
#>
[CmdletBinding()]
param(
  [string]$Duration = '90s',
  [string]$App = '',
  [string]$Url = '',  # 비우면 config.ps1 의 $ENDPOINT 사용 (-Url 로 이 실행만 override)
  # 조합 사이에 이전 노드가 회수될 때까지 기다리는 상한(초).
  #   -1  : NodePool 의 consolidateAfter 에서 자동 유도 (기본, 정확하지만 조합당 최대 12분)
  #    0  : 대기 없음 (빠르지만 nodes_avg 가 이전 조합에 오염된다 -> 비용 비교 불가)
  #   N   : N 초까지만 대기
  # 경기 중에는 시간이 없으므로 autotune 대신 loadtest -> advise 반복을 쓴다(README 참고).
  [int]$DrainTimeout = -1
)
$ErrorActionPreference = 'Continue'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Here 'config.ps1')

$bin = Join-Path $env:USERPROFILE 'bin'
if ($env:Path -notlike "*$bin*") { $env:Path = "$bin;$env:Path" }
if (-not $Url) { $Url = $ENDPOINT }
if (-not $Url -or $Url -like '*REPLACE-ME*') {
  Write-Error 'endpoint 미설정 — config.ps1 의 $ENDPOINT 를 채우거나 -Url http://... 로 전달'; exit 1
}
$EP = $Url.TrimEnd('/')

if (-not (Get-Command hey -ErrorAction SilentlyContinue) -or -not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
  Write-Error 'hey/kubectl 없음 — .\setup.ps1 먼저'; exit 1
}
$Results = Join-Path $env:TEMP 'autotune-results.csv'
'combo,avg_perf,min_avail,nodes_avg,score,nodes_start' | Set-Content -Path $Results

$APPS = $APIS | ForEach-Object { $_.name }

# -App 지정 시 그 앱만 patch (나머지는 현재 설정 유지). 미지정이면 전체.
if ($App) {
  if ($APPS -notcontains $App) { Write-Error "unknown app '$App' — config.ps1 의 앱: $($APPS -join ', ')"; exit 1 }
  $TUNE_APPS = @($App)
} else {
  $TUNE_APPS = $APPS
}

# --- 후보 그리드: name | cpu | util | min | max (모든 앱에 적용) ---
$COMBOS = @(
  @{ name = 'baseline';       cpu = '300m'; util = 55; min = 2; max = 10 }
  @{ name = 'lean-cpu';       cpu = '200m'; util = 55; min = 2; max = 10 }
  @{ name = 'rich-cpu';       cpu = '500m'; util = 55; min = 2; max = 10 }
  @{ name = 'aggressive-hpa'; cpu = '300m'; util = 45; min = 3; max = 12 }
  @{ name = 'calm-hpa';       cpu = '300m'; util = 65; min = 2; max = 8 }
  @{ name = 'cost-min';       cpu = '200m'; util = 65; min = 2; max = 6 }
)

function Invoke-PatchAll {
  param($cpu, $util, $min, $max)
  foreach ($app in $TUNE_APPS) {
    kubectl -n $NS set resources "deploy/$app" --requests=cpu=$cpu 2>$null | Out-Null
    # ⚠ PowerShell 은 네이티브 exe 에 큰따옴표를 그대로 넘기지 못한다. -p $patch 로 주면
    #    kubectl 에 {spec:...} 로 도착해 "invalid character 's'" 로 실패하는데,
    #    2>$null 때문에 조용히 넘어가 HPA 가 전혀 안 바뀌던 버그가 있었다.
    #    --patch-file 로 넘겨 따옴표 문제를 원천 제거하고, 실패는 표면화한다.
    $patch = @{ spec = @{ minReplicas = $min; maxReplicas = $max; metrics = @(@{ type = 'Resource'; resource = @{ name = 'cpu'; target = @{ type = 'Utilization'; averageUtilization = $util } } }) } } | ConvertTo-Json -Depth 10 -Compress
    $pf = Join-Path $env:TEMP "hpa-$app.json"
    $patch | Set-Content -Path $pf -Encoding ascii -NoNewline
    kubectl -n $NS patch hpa $app --type=merge --patch-file $pf | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Warning "    HPA patch 실패 ($app) — util/min/max 가 반영되지 않았습니다" }
  }
  foreach ($app in $TUNE_APPS) { kubectl -n $NS rollout status "deploy/$app" --timeout=180s 2>$null | Out-Null }
}

# 이전 조합이 띄운 노드가 남아 있으면 다음 조합의 nodes_avg 가 부풀어 비용 점수가
# 뒤섞인다. Karpenter consolidation 이 기준선까지 회수할 때까지 기다려 조합 간
# 이전 조합이 띄운 노드가 회수될 때까지 기다린다. 남아 있으면 다음 조합의 nodes_avg 가
# 부풀어 비용 비교가 무의미해진다.
#
# 대기 시간은 Karpenter NodePool 의 consolidateAfter 에서 유도한다. 고정 3분으로 두면
# 안 된다 — consolidateAfter 가 5분이면 회수가 '시작'되기도 전에 포기해서 항상
# timeout 이 뜬다(실측: 항상 timeout, 실제 전량 회수까지는 12분 걸렸다).
# disruption budget 이 Underutilized=1 이라 노드는 한 대씩 회수되므로 여유를 넉넉히 준다.
function Get-DrainTimeoutSec {
  if ($DrainTimeout -ge 0) { return $DrainTimeout }   # 사용자가 지정하면 그 값
  $sec = 300
  try {
    $ca = (kubectl get nodepool default -o jsonpath='{.spec.disruption.consolidateAfter}' 2>$null)
    if ($ca -match '^(\d+)m$') { $sec = [int]$Matches[1] * 60 }
    elseif ($ca -match '^(\d+)s$') { $sec = [int]$Matches[1] }
  } catch {}
  # consolidateAfter + 노드 종료/한 대씩 회수 여유
  return [int]($sec + 420)
}

function Invoke-Drain {
  $target = [int]$COST_BASELINE_NODES + 1   # 기준선 + 여유 1대
  $limit = Get-DrainTimeoutSec
  if ($limit -le 0) {
    try { $n = (kubectl get nodes --no-headers 2>$null | Select-String '\bReady').Count } catch { $n = -1 }
    Write-Host "    drain 생략 (-DrainTimeout 0) — nodes=$n 로 시작, nodes_avg 비교는 신뢰 불가" -ForegroundColor Yellow
    return $n
  }
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $last = -1
  $nextTick = 0
  while ($sw.Elapsed.TotalSeconds -lt $limit) {
    try { $n = (kubectl get nodes --no-headers 2>$null | Select-String '\bReady').Count } catch { $n = -1 }
    if ($n -ge 1 -and $n -le $target) {
      Write-Host ("    nodes=$n (baseline 복귀, {0:N0}초 대기)" -f $sw.Elapsed.TotalSeconds)
      return $n
    }
    # 노드 수가 그대로여도 30초마다 찍는다. 안 찍으면 12분 동안 아무 출력이 없어
    # 멈춘 것처럼 보인다(실측: 사용자가 hang 으로 오인).
    $el = [int]$sw.Elapsed.TotalSeconds
    if ($n -ne $last -or $el -ge $nextTick) {
      Write-Host ("    nodes=$n (목표 <=$target) ... 회수 대기 {0}/{1}초, 남은 {2}초" -f $el, $limit, ($limit - $el))
      $last = $n
      $nextTick = $el + 30
    }
    Start-Sleep -Seconds 10
  }
  Write-Host ("    drain timeout ({0}초) — nodes={1} 로 시작하므로 이 조합의 nodes_avg 는 부풀어 있습니다" -f $limit, $last) -ForegroundColor Yellow
  return $last
}

function Get-TrialScore {
  param($Label)
  $out = Join-Path $env:TEMP "tune-$Label"
  # score.py score -> "avg mav navg score" (-App 모드면 perf 는 그 앱 기준)
  if ($App) {
    (python (Join-Path $Here 'score.py') score $out $SLOS $AVAIL_GATE $COST_PENALTY $App) -split '\s+'
  } else {
    (python (Join-Path $Here 'score.py') score $out $SLOS $AVAIL_GATE $COST_PENALTY) -split '\s+'
  }
}

$modeDesc = if ($App) { "tuning ONLY [$App] (others untouched)" } else { "tuning ALL [$($APPS -join ' ')] uniformly" }
$dsec = Get-DrainTimeoutSec
$estMin = [math]::Round(($COMBOS.Count * ($dsec + 120)) / 60.0)
Write-Host "### autotune: $($COMBOS.Count) combos x $Duration  $modeDesc  endpoint=$EP"
Write-Host "### 조합당 드레인 대기 최대 ${dsec}초 -> 전체 최대 약 ${estMin}분" -ForegroundColor Yellow
if ($estMin -gt 30) {
  Write-Host '### 경기 중이면 너무 느립니다. loadtest -> advise 반복을 쓰거나 -DrainTimeout 으로 줄이세요' -ForegroundColor Yellow
}
foreach ($c in $COMBOS) {
  Write-Host ''
  Write-Host ">>> combo=$($c.name)  cpu=$($c.cpu) util=$($c.util) replicas=$($c.min)-$($c.max)"
  Invoke-PatchAll $c.cpu $c.util $c.min $c.max
  $startNodes = Invoke-Drain
  # 라벨에 'at-' 접두사를 붙인다. 조합 이름(baseline, lean-cpu, ...)을 그대로 쓰면
  # 사용자가 수동으로 돌린 '-Label baseline' 결과 폴더와 같은 경로가 되어 결과가 섞인다.
  # (loadtest 가 폴더를 비우도록 고쳤지만, 애초에 겹치지 않게 하는 것이 안전하다)
  $lbl = "at-$($c.name)"
  & (Join-Path $Here 'loadtest.ps1') -Url $EP -Duration $Duration -Label $lbl *> $null
  $r = Get-TrialScore -Label $lbl
  $ap, $ma, $na, $sc = $r[0], $r[1], $r[2], $r[3]
  Write-Host ("    perf_avg={0} avail_min={1} nodes_avg={2} SCORE={3}" -f $ap, $ma, $na, $sc)
  "$($c.name),$ap,$ma,$na,$sc" | Add-Content -Path $Results
}

Write-Host ''
Write-Host '### ranked (higher = better)'
$rows = Import-Csv $Results | Sort-Object { [double]$_.score } -Descending
$rows | Format-Table -AutoSize | Out-String | Write-Host
$WName = $rows[0].combo

Write-Host "### WINNER: $WName — re-applying to live cluster"
$win = $COMBOS | Where-Object { $_.name -eq $WName } | Select-Object -First 1
if ($win) {
  Invoke-PatchAll $win.cpu $win.util $win.min $win.max
  Write-Host ''
  if ($App) {
    Write-Host "### terraform/k8s_apps.tf 반영값 ($App 만):"
  } else {
    Write-Host '### terraform/k8s_apps.tf 반영값 (모든 앱 균일 — 방향 참고용, 실제 반영은 앱별로):'
  }
  Write-Host ("  requests.cpu = `"{0}`",  HPA averageUtilization = {1},  min={2} max={3}" -f $win.cpu, $win.util, $win.min, $win.max)
  if (-not $App) {
    Write-Host '  TIP: 병목 앱만 정밀 튜닝하려면  .\autotune.ps1 <endpoint> -App <앱이름>'
  }
}
Write-Host ''
Write-Host "Full results: $Results"
