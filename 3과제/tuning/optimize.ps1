<#
  닫힌 루프 HPA 최적화기 (measure -> score -> 한 수 패치 -> 재측정 -> 유지/되돌림).

  ★ 시간예산이 최우선이다. apply(약 30분) + 튜닝은 트래픽 시작 전 1시간 안에 끝나야 하므로
    이 스크립트는 -BudgetMinutes(기본 15분)를 넘기지 않고 '벽시계'로 스스로 멈춘다. 남은 예산이
    한 회차에 못 미치면 더 돌지 않고 그때까지의 최적값을 출력한다. 30분씩 걸리던 요소(180s 최종
    측정, 8회 고정 반복, 리버트 이중 롤아웃, 긴 sleep)는 전부 제거했다.

  목적함수는 score.py 의 '공식 채점 총점'(성능+가용성+비용, 36점)이다. optimize.py 가 다음 한 수를
  고르고, 이 스크립트가 실제로 적용/검증한다. 예측이 틀리면 되돌린다.

  왜 kubectl patch 인가(terraform 이 아니라): HPA target/min/max 만 바꾸며 빠르게 돌아야 한다.
  patch 는 즉시 반영·되돌림이 되고 terraform state 를 건드리지 않는다. 우승값은 끝에 Terraform
  형식으로 출력하니 k8s_apps.tf 에 박고 apply 해 영구화한다. ⚠ 탐색 중 terraform apply 금지.

  '부하 빠지는 시간' 반영: 비용 회수(target↑)는 파드/노드가 줄어드는 데 Karpenter
  consolidateAfter(약 2분)만큼 걸리므로, 그 수만 측정 전 대기를 길게 준다(-CostSettleSeconds).
  스케일아웃(성능/게이트)은 빨라서 짧게 대기한다.

  사용법:
    .\optimize.ps1                     # DRY-RUN: 1회 측정 후 '다음 한 수'만 출력(클러스터 불변)
    .\optimize.ps1 -Apply              # 닫힌 루프(기본 18분 예산 안에서 자동 탐색, 워밍업 후 120s 측정)
    .\optimize.ps1 -Apply -Duration 180s -BudgetMinutes 18   # 측정 창을 더 길게
#>
[CmdletBinding()]
param(
  [int]$BudgetMinutes = 18,         # 벽시계 총예산(20분 안에 끝내되 여유 2분). 넘으면 새 회차 안 염.
  [string]$Duration = '120s',       # 회차당 부하 길이. 콜드스타트를 희석하려 넉넉히(2분).
  [int]$WarmupSeconds = 60,         # 시작 시 1회 워밍업(측정 제외): DB 커넥션/CloudFront/파드 예열.
  [int]$Iterations = 6,             # 예산이 남아도 이 횟수까지만(안전 상한).
  [int]$SettleSeconds = 25,         # 스케일아웃(성능/게이트) 후 안정 대기.
  [int]$CostSettleSeconds = 105,    # 비용 회수(스케일인/노드 드레인) 후 대기 ~ consolidateAfter.
  [switch]$Apply,                   # 없으면 DRY-RUN(측정+제안만, 클러스터 불변)
  [string]$Url = ''
)
$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Here 'config.ps1')

foreach ($tool in 'kubectl', 'hey') {
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "$tool 없음 — setup.ps1 먼저 실행" }
}
$py = if (Get-Command py -ErrorAction SilentlyContinue) { @((Get-Command py).Source, '-3') }
      elseif (Get-Command python -ErrorAction SilentlyContinue) { @((Get-Command python).Source) }
      else { throw 'Python 없음' }

function Invoke-Py { param([string[]]$PyArgs)
  $env:PYTHONIOENCODING = 'utf-8'
  $old = [Console]::OutputEncoding
  try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    & $py[0] @($py[1..($py.Count-1)]) @PyArgs
  } finally {
    [Console]::OutputEncoding = $old
  }
}

function Get-Score { param([string]$OutDir)
  $raw = Invoke-Py @((Join-Path $Here 'score.py'), 'score', $OutDir, $SLOS, "$AVAIL_GATE", "$COST_PENALTY")
  return ($raw | Select-Object -Last 1 | ConvertFrom-Json)
}

function Get-NextStep { param([string]$OutDir, [string]$RejFile)
  $a = @((Join-Path $Here 'optimize.py'), $OutDir, '--slos', $SLOS, '--ns', $NS,
         '--avail-gate', "$AVAIL_GATE", '--json')
  if ($RejFile) { $a += @('--rejected', $RejFile) }
  $raw = Invoke-Py $a
  return ($raw | Select-Object -Last 1 | ConvertFrom-Json)
}

# HPA 한 개를 target/min/max 로 패치(JSON Patch). 롤아웃 대기는 짧게(HPA 변경은 템플릿 변경이
# 아니라 파드 재생성이 없다). 실제 스케일 반영은 호출부에서 settle 로 기다린다.
function Set-Hpa { param([string]$App, $Knob)
  $patch = @(
    @{ op = 'replace'; path = '/spec/minReplicas'; value = [int]$Knob.min },
    @{ op = 'replace'; path = '/spec/maxReplicas'; value = [int]$Knob.max },
    @{ op = 'replace'; path = '/spec/metrics/0/resource/target/averageUtilization'; value = [int]$Knob.target }
  )
  $f = Join-Path $env:TEMP "hpa-patch-$App.json"
  ($patch | ConvertTo-Json -Depth 5 -Compress) | Set-Content -Path $f -Encoding ascii
  & kubectl -n $NS patch hpa $App --type=json --patch-file $f | Out-Null
}

if (-not $Url) { $Url = $ENDPOINT }
# loadtest.ps1 에 이름으로 넘긴다. 배열 splat(@('-Url',$Url))은 PS가 '-Url'을 위치값으로
# 처리해 URL이 남는 위치 인수가 되며 "위치 매개 변수를 찾을 수 없습니다" 로 깨진다.
$ltArgs = @{ Duration = $Duration; Label = 'opt' }
if ($Url) { $ltArgs['Url'] = $Url }
$loadtest = Join-Path $Here 'loadtest.ps1'

Write-Host '=== 닫힌 루프 최적화 (목적함수 = score.py 공식 총점) ===' -ForegroundColor Cyan
Write-Host ("예산 {0}분 / 회차 {1} / 최대 {2}회 — 예산 초과 시 자동 중단" -f $BudgetMinutes, $Duration, $Iterations) -ForegroundColor Cyan
if (-not $Apply) { Write-Host 'DRY-RUN: 1회 측정 후 다음 한 수만 제안(-Apply 로 실제 탐색).' -ForegroundColor Yellow }

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$rejFile = Join-Path $env:TEMP 'optimize-rejected.json'
'[]' | Set-Content -Path $rejFile -Encoding ascii

# --- 워밍업(측정 제외): 콜드스타트(DB 커넥션·CloudFront 캐시·파드 스케일업)를 걷어낸다.
# 짧은 첫 측정은 콜드스타트가 창을 지배해 user perf 가 실제(80%+)보다 훨씬 낮게 찍힌다.
# 예열 후 정상상태에서 측정해야 튜닝 판단이 맞다. (DRY-RUN 은 빠른 미리보기라 건너뜀)
if ($Apply -and $WarmupSeconds -gt 0) {
  Write-Host ("워밍업 {0}s (측정 안 함, 콜드스타트 제거)..." -f $WarmupSeconds) -ForegroundColor DarkGray
  $warm = @{ Duration = ("{0}s" -f $WarmupSeconds); Label = 'opt-warm' }
  if ($Url) { $warm['Url'] = $Url }
  & $loadtest @warm | Out-Null
}

# --- 베이스라인 측정 ---
& $loadtest @ltArgs | Out-Null
$bestOut = Join-Path $env:TEMP 'tune-opt'
$bestScore = Get-Score $bestOut
$bestKnobs = (Get-NextStep $bestOut $null).knobs
Write-Host ("[baseline] 총점 {0:N1}/36  비용ratio {1:N2}  ({2:N1}분 경과)" -f $bestScore.total, $bestScore.cost_ratio, $sw.Elapsed.TotalMinutes)

if (-not $Apply) {
  $step = Get-NextStep $bestOut $null
  if ($step.done) { Write-Host "수렴: $($step.reason)" -ForegroundColor Green }
  else {
    Write-Host ("제안 [{0}] {1}: target={2}% min={3} max={4} (기대 +{5})" -f `
      $step.kind, $step.app, $step.knob.target, $step.knob.min, $step.knob.max, $step.predicted_delta) -ForegroundColor Green
    Write-Host "근거: $($step.reason)"
  }
  return
}

# 회차 소요 추정(분): settle + 부하 + 오버헤드. 남은 예산이 이보다 적으면 새 회차를 안 연다.
$loadMin = ([regex]::Match($Duration, '^\d+')).Value / 60.0
$rejected = @()
for ($i = 1; $i -le $Iterations; $i++) {
  $step = Get-NextStep $bestOut $rejFile
  if ($step.done) { Write-Host "수렴(${i}회차): $($step.reason)" -ForegroundColor Green; break }

  $settle = if ($step.kind -eq 'cost-reclaim') { $CostSettleSeconds } else { $SettleSeconds }
  $needMin = ($settle / 60.0) + $loadMin + 0.3
  $remain = $BudgetMinutes - $sw.Elapsed.TotalMinutes
  if ($remain -lt $needMin) {
    Write-Host ("예산 종료: 남은 {0:N1}분 < 회차 소요 {1:N1}분 -> 중단" -f $remain, $needMin) -ForegroundColor Yellow
    break
  }

  $app = $step.app; $knob = $step.knob
  Write-Host ("--- iter ${i} ({0:N1}분 경과, 남은 {1:N1}분): [{2}] {3} target->{4}% min->{5} max->{6}" -f `
    $sw.Elapsed.TotalMinutes, $remain, $step.kind, $app, $knob.target, $knob.min, $knob.max)
  Set-Hpa $app $knob
  Start-Sleep -Seconds $settle           # 스케일 반영/노드 드레인 대기(비용 수는 길게)

  & $loadtest @ltArgs | Out-Null
  $score = Get-Score $bestOut

  $gateOk = $score.perf_gate_pass -and $score.avail_gate_pass
  if ($gateOk -and $score.total -gt $bestScore.total) {
    Write-Host ("  채택: 총점 {0:N1} -> {1:N1}  비용ratio {2:N2}" -f $bestScore.total, $score.total, $score.cost_ratio) -ForegroundColor Green
    $bestScore = $score
    $bestKnobs.$app = $knob
  } else {
    Write-Host ("  거절: 총점 {0:N1} (기준 {1:N1}, gate={2}) -> 되돌림" -f $score.total, $bestScore.total, $gateOk) -ForegroundColor Yellow
    Set-Hpa $app $bestKnobs.$app          # HPA 복구(파드 재생성 없음, 롤아웃 대기 불필요)
    $rejected += @{ app = $app; kind = $step.kind }
    $items = @($rejected | ForEach-Object { $_ | ConvertTo-Json -Compress })
    ('[' + ($items -join ',') + ']') | Set-Content -Path $rejFile -Encoding ascii
  }
}

Write-Host ("`n=== 탐색 종료: {0:N1}분 소요, 최종 총점 {1:N1}/36 비용ratio {2:N2} ===" -f `
  $sw.Elapsed.TotalMinutes, $bestScore.total, $bestScore.cost_ratio) -ForegroundColor Green
Write-Host '--- k8s_apps.tf 에 반영할 우승 HPA 값 (탐색은 kubectl 패치라 terraform apply 시 사라짐) ---'
foreach ($app in $bestKnobs.PSObject.Properties.Name | Sort-Object) {
  $k = $bestKnobs.$app
  Write-Host ("{0}: average_utilization={1}, min_replicas={2}, max_replicas={3}" -f $app, $k.target, $k.min, $k.max)
}
Write-Host '반영 후 terraform apply 로 영구화. (비정상요청 4점은 verify.ps1 로 별도 확인)'
