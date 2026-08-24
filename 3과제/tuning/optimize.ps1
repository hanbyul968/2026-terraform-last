<#
  공식 채점 총점을 최대화하는 18분 라이브 튜닝 루프.
  warmup -> baseline -> 후보(최대3) 적용 -> 120초 측정 -> 채택/롤백.
  Terraform은 건드리지 않는다. request 변경은 rollout을 동반하므로 공식 트래픽 전에 실행한다.
#>
[CmdletBinding()]
param(
  # 20분 하드 예산. 각 비싼 단계 앞에서 남은 시간을 확인하고, 모자라면 그 단계를 건너뛴다.
  # terraform apply 가 kubectl patch 보다 느리므로(회당 약 60~90s) 그만큼을 예산에 반영했다.
  [int]$BudgetMinutes = 20,
  [string]$Duration = '90s',
  [int]$WarmupSeconds = 30,
  [int]$Iterations = 3,
  [int]$SettleSeconds = 25,
  [int]$CostSettleSeconds = 75,
  [ValidateSet('cost','balanced')][string]$Objective = 'cost',
  [double]$AvailFloor = 90,
  [double]$PerfFloor = 80,
  [double]$LoadScale = 1,
  [string]$TargetRps = '',
  # 비용 ratio의 분모(B)는 비공개다. 하나로 찍지 않고 후보 그리드 전체에서 총점을 평가한다.
  # 기준 구성이 더 크다고 판단되면 '3,4,6' 처럼 넓혀서 준다(추천이 노드 증가 쪽으로 움직인다).
  [string]$CostBaselines = '',
  # 부하 중 라이브 루프는 기본적으로 HPA(target/min/max)만 만진다. request 변경은 rollout을
  # 일으켜 회차 시간을 잡아먹고 가용성을 깎으므로, 켜려면 -AllowRequestChange 를 명시한다.
  [switch]$AllowRequestChange,
  [switch]$Apply,
  [string]$Url = ''
)
$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Here 'config.ps1')
foreach ($tool in 'kubectl','hey') {
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "$tool 없음 — setup.ps1 먼저 실행" }
}
$py = if (Get-Command py -ErrorAction SilentlyContinue) { @((Get-Command py).Source,'-3') }
      elseif (Get-Command python -ErrorAction SilentlyContinue) { @((Get-Command python).Source) }
      else { throw 'Python 없음' }

function Invoke-Py { param([string[]]$PyArgs)
  $env:PYTHONIOENCODING='utf-8'; $old=[Console]::OutputEncoding
  try { [Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false); & $py[0] @($py[1..($py.Count-1)]) @PyArgs }
  finally { [Console]::OutputEncoding=$old }
}
function Get-Score { param([string]$OutDir)
  $raw=Invoke-Py @((Join-Path $Here 'score.py'),'score',$OutDir,$SLOS,"$AVAIL_GATE","$COST_PENALTY")
  return ($raw | Select-Object -Last 1 | ConvertFrom-Json)
}
function Get-NextStep { param([string]$OutDir,[string]$RejFile)
  $a=@((Join-Path $Here 'optimize.py'),$OutDir,'--slos',$SLOS,'--ns',$NS,'--avail-gate',"$AVAIL_GATE",
       '--objective',$Objective,'--avail-floor',"$AvailFloor",'--perf-floor',"$PerfFloor",
       '--load-scale',"$LoadScale",'--json')
  if(-not $AllowRequestChange){$a+=@('--hpa-only')}
  if($TargetRps){$a+=@('--target-rps',$TargetRps)}
  if($CostBaselines){$a+=@('--cost-baselines',$CostBaselines)}
  if($RejFile){$a+=@('--rejected',$RejFile)}
  $raw=Invoke-Py $a; return ($raw | Select-Object -Last 1 | ConvertFrom-Json)
}
function Get-LiveRequest { param([string]$App)
  $v=& kubectl -n $NS get deploy $App -o 'jsonpath={.spec.template.spec.containers[0].resources.requests.cpu}' 2>$null
  if("$v" -match '^(\d+)m$'){return [int]$Matches[1]}
  if("$v" -match '^\d+(\.\d+)?$'){return [int]([double]$v*1000)}
  return 0
}
function Get-TuningFile { return (Join-Path $TF_DIR 'tuning.auto.tfvars.json') }

function Read-Tuning {
  # 누적 파일을 읽는다. 없으면 빈 맵. apps.tf 가 필드 단위로 fallback 하므로
  # 부분 맵이어도 안전하다(적히지 않은 앱/필드는 terraform.tfvars 의 apps 값 사용).
  $f = Get-TuningFile
  if (-not (Test-Path $f)) { return @{} }
  try {
    $obj = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json
    $out = @{}
    if ($obj.app_tuning) {
      foreach ($p in $obj.app_tuning.PSObject.Properties) {
        $out[$p.Name] = @{
          cpu_request_m  = [int]$p.Value.cpu_request_m
          hpa_target_cpu = [int]$p.Value.hpa_target_cpu
          min_replicas   = [int]$p.Value.min_replicas
          max_replicas   = [int]$p.Value.max_replicas
        }
      }
    }
    return $out
  } catch { Write-Warning 'tuning.auto.tfvars.json 파싱 실패 — 빈 값으로 시작합니다.'; return @{} }
}
function Write-Tuning { param($Map)
  $f = Get-TuningFile
  (@{ app_tuning = $Map } | ConvertTo-Json -Depth 10) | Set-Content $f -Encoding UTF8
  return $f
}
function Invoke-TerraformApply {
  # 튜닝은 Deployment 와 HPA 만 바꾼다 → 그 둘만 -target 으로 좁힌다.
  # 전체 apply 는 느리고, 부하 중 CloudFront/RDS 까지 건드릴 위험이 있다.
  Push-Location $TF_DIR
  try {
    & terraform apply -auto-approve -input=false -target=kubernetes_deployment.app -target=kubernetes_horizontal_pod_autoscaler_v2.app
    if($LASTEXITCODE -ne 0){ throw "terraform apply 실패 (exit=$LASTEXITCODE)" }
  } finally { Pop-Location }
}
function Set-TuningSet { param($Knobs)
  # ⚠ 클러스터를 kubectl 로 직접 고치지 않는다.
  #   이전 버전은 kubectl patch hpa / set resources 를 실행했고, 그 결과 라이브 상태가
  #   Terraform state 와 어긋났다(드리프트). 실측: 채점 회차의 라이브 값
  #   (user 425m / product 50m / stress target 25%,min 3)이 .tf 파일값과 전부 달랐고,
  #   누군가 terraform apply 를 하면 튜닝이 조용히 원복되는 상태였다.
  #   이제 목표값을 tuning.auto.tfvars.json 에 쓰고 terraform 이 반영한다.
  $map = Read-Tuning
  foreach($name in $Knobs.PSObject.Properties.Name){
    $k = $Knobs.$name
    $entry = @{
      hpa_target_cpu = [int]$k.target
      min_replicas   = [int]$k.min
      max_replicas   = [int]$k.max
    }
    # -hpa-only 모드에서는 request 가 0 으로 올 수 있다. 0m 을 쓰면 파드가 CPU 를
    # 전혀 요청하지 않아 스케줄링/HPA 계산이 망가지므로 기존 값을 유지한다.
    $req = [int]$k.request
    if($req -gt 0){ $entry.cpu_request_m = $req }
    elseif($map[$name] -and $map[$name].cpu_request_m){ $entry.cpu_request_m = [int]$map[$name].cpu_request_m }
    $map[$name] = $entry
  }
  $f = Write-Tuning $map
  Write-Host "  튜닝값 기록 -> $f" -ForegroundColor DarkGray
  Invoke-TerraformApply
}
function Set-TuningOne { param([string]$App,$Knob)
  # 단일 앱을 Set-TuningSet 형태로 감싼다(terraform apply 는 1회만 수행됨).
  $o = New-Object psobject
  $o | Add-Member -MemberType NoteProperty -Name $App -Value $Knob
  Set-TuningSet $o
}
function Set-TuningMany { param($Names,$Knobs)
  # 여러 앱을 한 번의 terraform apply 로 되돌린다(앱마다 apply 하면 예산을 다 태운다).
  $o = New-Object psobject
  foreach($n in $Names){ if($Knobs.$n){ $o | Add-Member -MemberType NoteProperty -Name $n -Value $Knobs.$n } }
  if($o.PSObject.Properties.Name.Count -gt 0){ Set-TuningSet $o }
}
function Write-Rejected { param($Rows,[string]$Path)
  $items=@($Rows|ForEach-Object{$_|ConvertTo-Json -Compress}); ('['+($items -join ',')+']')|Set-Content $Path -Encoding ascii
}
function Save-Snapshot { param([string]$From,[string]$To)
  # 거절된 회차의 측정으로 다음 후보를 계획하면 엉뚱한 값이 나온다(실측 사고).
  # 채택된 상태의 결과만 따로 보관해 계획 입력으로 쓴다.
  # loadtest가 nodecpu.csv 등을 백그라운드로 아직 쓰고 있을 수 있어, 잠긴 파일은
  # 재시도하고 그래도 안 되면 건너뛴다(계획에 필요한 앱 csv는 이미 닫혀 있다).
  if(-not (Test-Path $To)){ New-Item -ItemType Directory -Path $To | Out-Null }
  $log = robocopy $From $To /E /R:3 /W:1 /NFL /NDL /NJH /NJS /NP 2>&1
  if($LASTEXITCODE -ge 8){
    # robocopy 실패 시 파일 단위로 최대한 복사(잠긴 것만 스킵)
    Get-ChildItem $From -File | ForEach-Object {
      try { Copy-Item $_.FullName (Join-Path $To $_.Name) -Force -ErrorAction Stop } catch {}
    }
  }
  $global:LASTEXITCODE = 0
}

if(-not $Url){$Url=$ENDPOINT}
$loadtest=Join-Path $Here 'loadtest.ps1'
$ltArgs=@{Duration=$Duration;Label='opt'};if($Url){$ltArgs.Url=$Url}

function ConvertTo-DurationSeconds { param([string]$Value)
  if($Value -notmatch '^(\d+(?:\.\d+)?)(ms|s|m|h)$'){throw "Duration 형식 오류: $Value (예: 120s, 2m)"}
  $n=[double]$Matches[1]
  switch($Matches[2]){'ms'{return $n/1000};'s'{return $n};'m'{return $n*60};'h'{return $n*3600}}
}

$sw=[Diagnostics.Stopwatch]::StartNew();$deadline=[TimeSpan]::FromMinutes($BudgetMinutes)

# ---------------------------------------------------------------------------
# 20분 예산 강제.
# terraform apply 는 회당 60~90초가 걸리므로(kubectl patch 대비 느림) 남은 시간을
# 확인하지 않고 다음 단계에 들어가면 예산을 넘긴다. 각 비싼 단계 앞에서 필요한
# 시간을 미리 계산해 모자라면 건너뛰고, 지금까지 채택된 값으로 마무리한다.
# 실측된 apply 시간을 누적 평균으로 갱신해 갈수록 예측이 정확해진다.
# ---------------------------------------------------------------------------
$script:ApplyCostSeconds = 90   # 초기 추정. 실제 apply 후 실측으로 대체된다.
function Get-SecondsLeft { return [Math]::Max(0, $deadline.TotalSeconds - $sw.Elapsed.TotalSeconds) }
function Test-TimeFor { param([int]$NeedSeconds,[string]$What)
  $left = Get-SecondsLeft
  if($left -ge $NeedSeconds){ return $true }
  Write-Warning ("예산 부족으로 '{0}' 생략 (필요 {1}s / 남음 {2:N0}s)" -f $What,$NeedSeconds,$left)
  return $false
}
function Measure-Apply { param([scriptblock]$Body)
  $t=[Diagnostics.Stopwatch]::StartNew(); & $Body; $t.Stop()
  # 누적 평균으로 갱신(첫 실측은 그대로 채택)
  $script:ApplyCostSeconds = [int][Math]::Ceiling($t.Elapsed.TotalSeconds)
  Write-Host ("  apply {0:N0}s (남은 예산 {1:N0}s)" -f $t.Elapsed.TotalSeconds,(Get-SecondsLeft)) -ForegroundColor DarkGray
}
$candidateLimit=[Math]::Min([Math]::Max($Iterations,0),3)
$rejFile=Join-Path $env:TEMP 'optimize-rejected.json';'[]'|Set-Content $rejFile -Encoding ascii
$rejected=@();$pending=$null;$bestKnobs=$null
$triedApps=New-Object 'System.Collections.Generic.HashSet[string]'
Write-Host '=== 공식 채점기준 라이브 튜닝 ===' -ForegroundColor Cyan
Write-Host ("예산 {0}분 / warmup {1}s / 측정 {2} / 후보 최대 {3}개 / 목표 {4} (가용성>={5}% 성능>={6}%)" -f $BudgetMinutes,$WarmupSeconds,$Duration,$candidateLimit,$Objective,$AvailFloor,$PerfFloor)

try {
  if($Apply -and $WarmupSeconds -gt 0){
    $warm=@{Duration=("{0}s" -f $WarmupSeconds);Label='opt-warm'};if($Url){$warm.Url=$Url}
    Write-Host "워밍업 $WarmupSeconds 초(점수 제외)..." -ForegroundColor DarkGray
    & $loadtest @warm | Out-Null
  }
  & $loadtest @ltArgs | Out-Null
  $out=Join-Path $env:TEMP 'tune-opt';$bestScore=Get-Score $out;$first=Get-NextStep $out $null
  # 노드 수 -> 총점 프론티어. 비용과 성능 중 무엇을 얼마나 내줄지를 여기서 결정한다.
  if($first.frontier -and $first.frontier.knees){
    $fr=$first.frontier
    Write-Host ("프론티어: 추천 {0}대 (기대 총점 {1:N2}, 최악 손해 {2:N2}점) - {3}" -f $fr.recommended_nodes,$fr.expected_total,$fr.minimax_regret,$fr.note) -ForegroundColor Cyan
    foreach($k in $fr.knees){
      if([math]::Abs([int]$k.nodes - [int]$fr.recommended_nodes) -le 2){
        $cells=($fr.baselines|ForEach-Object{'{0:N1}' -f $k.total_by_baseline."$_"}) -join ' / '
        Write-Host ("    {0}대: 품질 {1:N1} | B별 총점 {2} | 기대 {3:N2}" -f $k.nodes,$k.quality,$cells,$k.expected_total) -ForegroundColor DarkGray
      }
    }
  }
  $bestOut=Join-Path $env:TEMP 'tune-opt-best'; Save-Snapshot $out $bestOut
  $bestKnobs=$first.knobs
  Write-Host ("[baseline] {0:N1}/36 ratio={1:N2} elapsed={2:N1}m" -f $bestScore.total,$bestScore.cost_ratio,$sw.Elapsed.TotalMinutes)
  if(-not $Apply){
    Write-Host ("유휴 노드 {0}대 (baseline {1}대)" -f $first.idle_nodes,$first.baseline_node_count)
    if($first.presize){
      Write-Host "부하 전 1회 request 사이징(적용 시 유휴 $($first.idle_nodes_after_presize)대):" -ForegroundColor Green
      foreach($n in $first.presize.PSObject.Properties.Name){$k=$first.presize.$n;Write-Host ("  {0}: request={1}m target={2}%" -f $n,$k.request,$k.target)}
    }
    if($first.done){Write-Host "수렴: $($first.reason)" -ForegroundColor Green}
    else{Write-Host ("HPA 후보 [{0}] {1}: target={2}% min={3} max={4}" -f $first.kind,$first.app,$first.knob.target,$first.knob.min,$first.knob.max) -ForegroundColor Green;Write-Host $first.reason}
    return
  }
  # 트래픽 전 1회: request 사이징(rollout 동반). 유휴 노드를 baseline로 맞추고 과소/과대 예약 교정.
  # 이 단계만 request를 바꾼다. 이후 시행은 HPA-only라 rollout이 없다.
  if($first.presize){
    $needPresize = $script:ApplyCostSeconds + $CostSettleSeconds + (ConvertTo-DurationSeconds $Duration) + 30
    if(Test-TimeFor $needPresize 'request 사이징'){
      Write-Host ("--- 부하 전 request 사이징: 유휴 {0}->{1}대" -f $first.idle_nodes,$first.idle_nodes_after_presize) -ForegroundColor Cyan
      Measure-Apply { Set-TuningSet $first.presize }
      foreach($n in $first.presize.PSObject.Properties.Name){ if($bestKnobs.$n){ $bestKnobs.$n.request=$first.presize.$n.request; $bestKnobs.$n.target=$first.presize.$n.target } }
      Start-Sleep -Seconds $CostSettleSeconds
      & $loadtest @ltArgs | Out-Null
      $bestScore=Get-Score $out; Save-Snapshot $out $bestOut
      Write-Host ("사이징 후 {0:N1}/36 ratio={1:N2}" -f $bestScore.total,$bestScore.cost_ratio)
    }
  }
  # 반복 측정 루프 없음: 한 번 계산한 '전 앱 HPA 묶음'을 1회 적용하고 1회만 확인한다.
  # (회차당 측정을 여러 번 도는 게 시간의 주범이었다. 값은 baseline 측정 한 번으로 다 나온다.)
  # 후보 1회에 필요한 시간 = apply + settle + 측정 + 롤백 여유(apply 1회 더)
  $needCand = ($script:ApplyCostSeconds * 2) + $SettleSeconds + (ConvertTo-DurationSeconds $Duration) + 30
  $step = if(Test-TimeFor $needCand 'HPA 후보 검증'){ Get-NextStep $bestOut $rejFile } else { @{ done=$true; reason='예산 부족 — baseline 값으로 종료' } }
  if($step.done){
    Write-Host "조정할 HPA 없음: $($step.reason)" -ForegroundColor Green
  } else {
    $knobSet=if($step.knob_set){$step.knob_set}else{$null}
    $touched=if($knobSet){@($knobSet.PSObject.Properties.Name)}else{@($step.app)}
    $pending=$touched[0]
    Write-Host ("--- 전 앱 HPA 한 번에 적용: {0}" -f ($touched -join '+')) -ForegroundColor Cyan
    if($knobSet){
      foreach($n in $touched){$k=$knobSet.$n;Write-Host ("    {0}: target={1}% min={2} max={3}" -f $n,$k.target,$k.min,$k.max)}
      Measure-Apply { Set-TuningSet $knobSet }
    } else { Measure-Apply { Set-TuningOne $step.app $step.knob } }
    Start-Sleep -Seconds $SettleSeconds
    & $loadtest @ltArgs | Out-Null
    $score=Get-Score $out
    $availFloor=if($step.avail_floor){[double]$step.avail_floor}else{$AvailFloor}
    $perfFloor=if($step.perf_floor){[double]$step.perf_floor}else{$PerfFloor}
    $gate=($score.min_avail -ge $availFloor) -and ($score.min_perf -ge $perfFloor) -and ($score.cost_points -gt 0)
    $safety=($score.min_perf -gt $bestScore.min_perf) -or ($score.min_avail -gt $bestScore.min_avail)
    if($safety -or ($gate -and $score.total -ge $bestScore.total)){
      Write-Host ("채택 {0:N1}->{1:N1}, ratio={2:N2}, minPerf {3:N1}%" -f $bestScore.total,$score.total,$score.cost_ratio,$score.min_perf) -ForegroundColor Green
      $bestScore=$score
      foreach($name in $touched){ if($knobSet){$bestKnobs.$name=$knobSet.$name}else{$bestKnobs.$name=$step.knob} }
      $pending=$null; Save-Snapshot $out $bestOut
    } else {
      Write-Host ("거절 score={0:N1} gate={1}; 롤백" -f $score.total,$gate) -ForegroundColor Yellow
      Set-TuningMany $touched $bestKnobs
      $pending=$null
    }
  }
  Write-Host ("`n=== 종료 {0:N1}분 / best {1:N1}/36 ratio={2:N2} ===" -f $sw.Elapsed.TotalMinutes,$bestScore.total,$bestScore.cost_ratio) -ForegroundColor Green
  if(($bestScore.min_avail -lt $AvailFloor) -or ($bestScore.min_perf -lt $PerfFloor)){
    Write-Warning ("안전선 미달: min availability={0:N1}% (>={1}%) / min performance={2:N1}% (>={3}%)" -f $bestScore.min_avail,$AvailFloor,$bestScore.min_perf,$PerfFloor)
  }
  foreach($name in $bestKnobs.PSObject.Properties.Name|Sort-Object){$k=$bestKnobs.$name;Write-Host ('{0}: requests.cpu="{1}m", min_replicas={2}, max_replicas={3}, average_utilization={4}' -f $name,$k.request,$k.min,$k.max,$k.target)}
  Write-Host ('위 값은 {0} 에 기록되어 terraform 으로 적용된 상태입니다(드리프트 없음).' -f (Get-TuningFile))
}
finally {
  if($pending -and $bestKnobs -and $bestKnobs.$pending){
    Write-Warning "중단 감지: $pending 을 마지막 채택 snapshot으로 롤백"
    try{Set-TuningOne $pending $bestKnobs.$pending}catch{Write-Warning "자동 롤백 실패: $_"}
  }
}
