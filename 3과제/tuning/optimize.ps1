<#
  닫힌 루프 HPA 최적화기 (measure -> score -> 한 수 패치 -> 재측정 -> 유지/되돌림).

  목적함수는 score.py 의 '공식 채점 총점'(성능+가용성+비용, 36점)이다. optimize.py 가
  다음 한 수를 고르고, 이 스크립트가 실제로 적용/검증한다. 예측이 틀리면 되돌린다.

  왜 kubectl patch 인가(terraform 이 아니라):
    탐색은 회차마다 HPA target/min/max 만 바꾸며 빠르게 돌아야 한다. kubectl patch 는
    즉시 반영·되돌림이 되고 terraform state 를 건드리지 않는다. 최종 우승값은 스크립트가
    Terraform 형식으로 출력하며, 그 값을 k8s_apps.tf 에 반영하고 apply 하면 영구화된다.
    ⚠ 탐색 중에는 terraform apply 를 하지 말 것(패치가 되돌려진다).

  사용법:
    .\optimize.ps1                         # DRY-RUN: 1회 측정 후 '다음 한 수'만 출력(클러스터 불변)
    .\optimize.ps1 -Apply                  # 닫힌 루프 실행(HPA를 실제로 패치하며 최적값 탐색)
    .\optimize.ps1 -Apply -Iterations 10 -Duration 90s -FinalDuration 180s
    .\optimize.ps1 -Url http://<주소> -Apply
#>
[CmdletBinding()]
param(
  [string]$Duration = '90s',        # 탐색 회차당 부하 길이(짧게 여러 번)
  [string]$FinalDuration = '180s',  # 마지막 확정 측정 길이(채점과 동일하게 길게)
  [int]$Iterations = 8,
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
  & $py[0] @($py[1..($py.Count-1)]) @PyArgs
}

# score.py score 모드 -> JSON 요약(총점/비용ratio/게이트/앱별 perf,avail)
function Get-Score { param([string]$OutDir)
  $raw = Invoke-Py @((Join-Path $Here 'score.py'), 'score', $OutDir, $SLOS, "$AVAIL_GATE", "$COST_PENALTY")
  return ($raw | Select-Object -Last 1 | ConvertFrom-Json)
}

# optimize.py -> 다음 한 수(JSON). rejected 는 재제안 금지 목록.
function Get-NextStep { param([string]$OutDir, [string]$RejFile)
  $a = @((Join-Path $Here 'optimize.py'), $OutDir, '--slos', $SLOS, '--ns', $NS,
         '--avail-gate', "$AVAIL_GATE", '--json')
  if ($RejFile) { $a += @('--rejected', $RejFile) }
  $raw = Invoke-Py $a
  return ($raw | Select-Object -Last 1 | ConvertFrom-Json)
}

# HPA 한 개를 target/min/max 로 패치하고 롤아웃을 기다린다(JSON Patch).
function Set-Hpa { param([string]$App, $Knob)
  $patch = @(
    @{ op = 'replace'; path = '/spec/minReplicas'; value = [int]$Knob.min },
    @{ op = 'replace'; path = '/spec/maxReplicas'; value = [int]$Knob.max },
    @{ op = 'replace'; path = '/spec/metrics/0/resource/target/averageUtilization'; value = [int]$Knob.target }
  )
  $f = Join-Path $env:TEMP "hpa-patch-$App.json"
  ($patch | ConvertTo-Json -Depth 5 -Compress) | Set-Content -Path $f -Encoding ascii
  & kubectl -n $NS patch hpa $App --type=json --patch-file $f | Out-Null
  # HPA 변경은 즉시 반영되지만, min/max 변화로 파드가 늘/줄면 안정까지 잠깐 기다린다.
  & kubectl -n $NS rollout status "deploy/$App" --timeout=120s | Out-Null
  Start-Sleep -Seconds 20
}

if (-not $Url) { $Url = $ENDPOINT }
$urlArg = @(); if ($Url) { $urlArg = @('-Url', $Url) }

Write-Host '=== 닫힌 루프 최적화 (목적함수 = score.py 공식 총점) ===' -ForegroundColor Cyan
if (-not $Apply) {
  Write-Host 'DRY-RUN: 1회 측정 후 다음 한 수만 제안합니다. 실제 탐색은 -Apply 를 붙이세요.' -ForegroundColor Yellow
}

$loadtest = Join-Path $Here 'loadtest.ps1'
$rejected = @()
$rejFile = Join-Path $env:TEMP 'optimize-rejected.json'
'[]' | Set-Content -Path $rejFile -Encoding ascii

# --- 0회차: 베이스라인 측정 ---
& $loadtest -Duration $Duration -Label 'opt' @urlArg | Out-Null
$bestOut = Join-Path $env:TEMP 'tune-opt'
$bestScore = Get-Score $bestOut
$bestKnobs = (Get-NextStep $bestOut $null).knobs
Write-Host ("[baseline] 총점 {0:N1}/36  비용ratio {1:N2}" -f $bestScore.total, $bestScore.cost_ratio)

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

# --- 탐색 루프 ---
$lastMove = $null
for ($i = 1; $i -le $Iterations; $i++) {
  $step = Get-NextStep $bestOut $rejFile
  if ($step.done) { Write-Host "수렴(${i}회차): $($step.reason)" -ForegroundColor Green; break }

  $app = $step.app; $knob = $step.knob
  Write-Host ("--- iter ${i}: [{0}] {1} target->{2}% min->{3} max->{4}" -f $step.kind, $app, $knob.target, $knob.min, $knob.max)
  Set-Hpa $app $knob

  & $loadtest -Duration $Duration -Label 'opt' @urlArg | Out-Null
  $score = Get-Score $bestOut

  # 게이트를 깨는 수는 총점과 무관하게 거절(비용 12점 잠금/가용성 실격 방지).
  $gateOk = $score.perf_gate_pass -and $score.avail_gate_pass
  if ($gateOk -and $score.total -gt $bestScore.total) {
    Write-Host ("  채택: 총점 {0:N1} -> {1:N1}  비용ratio {2:N2}" -f $bestScore.total, $score.total, $score.cost_ratio) -ForegroundColor Green
    $bestScore = $score
    $bestKnobs.$app = $knob
  } else {
    Write-Host ("  거절: 총점 {0:N1} (기준 {1:N1}, gate={2}) -> 되돌림" -f $score.total, $bestScore.total, $gateOk) -ForegroundColor Yellow
    Set-Hpa $app $bestKnobs.$app                     # 이전 최적으로 복구
    $rejected += @{ app = $app; kind = $step.kind }  # 같은 수 재제안 금지
    # PS 5.1 의 ConvertTo-Json 은 단일 원소를 배열로 안 내므로 원소별로 만들어 이어붙인다.
    $items = @($rejected | ForEach-Object { $_ | ConvertTo-Json -Compress })
    ('[' + ($items -join ',') + ']') | Set-Content -Path $rejFile -Encoding ascii
  }
}

# --- 확정 측정(길게) + 최종 값 출력 ---
Write-Host "`n=== 최종 확정 측정 ($FinalDuration) ===" -ForegroundColor Cyan
& $loadtest -Duration $FinalDuration -Label 'opt-final' @urlArg | Out-Null
$final = Get-Score (Join-Path $env:TEMP 'tune-opt-final')
Write-Host ("최종 총점 {0:N1}/36  비용ratio {1:N2}  (+ 비정상요청 4점은 verify.ps1)" -f $final.total, $final.cost_ratio) -ForegroundColor Green

Write-Host "`n--- k8s_apps.tf 에 반영할 우승 HPA 값 (탐색은 kubectl 패치라 terraform apply 시 사라짐) ---"
foreach ($app in $bestKnobs.PSObject.Properties.Name | Sort-Object) {
  $k = $bestKnobs.$app
  Write-Host ("{0}: average_utilization={1}, min_replicas={2}, max_replicas={3}" -f $app, $k.target, $k.min, $k.max)
}
Write-Host '반영 후: terraform apply 로 영구화하고, 마지막으로 한 번 더 loadtest 로 확인하세요.'
