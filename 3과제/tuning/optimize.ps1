<#
  공식 채점 총점을 최대화하는 18분 라이브 튜닝 루프.
  warmup -> baseline -> 후보(최대3) 적용 -> 120초 측정 -> 채택/롤백.
  Terraform은 건드리지 않는다. request 변경은 rollout을 동반하므로 공식 트래픽 전에 실행한다.
#>
[CmdletBinding()]
param(
  [int]$BudgetMinutes = 18,
  [string]$Duration = '120s',
  [int]$WarmupSeconds = 60,
  [int]$Iterations = 3,
  [int]$SettleSeconds = 25,
  [int]$CostSettleSeconds = 105,
  [ValidateSet('cost','balanced')][string]$Objective = 'cost',
  [double]$AvailFloor = 90,
  [double]$PerfFloor = 80,
  [double]$LoadScale = 1,
  [string]$TargetRps = '',
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
  if($TargetRps){$a+=@('--target-rps',$TargetRps)}
  if($RejFile){$a+=@('--rejected',$RejFile)}
  $raw=Invoke-Py $a; return ($raw | Select-Object -Last 1 | ConvertFrom-Json)
}
function Get-LiveRequest { param([string]$App)
  $v=& kubectl -n $NS get deploy $App -o 'jsonpath={.spec.template.spec.containers[0].resources.requests.cpu}' 2>$null
  if("$v" -match '^(\d+)m$'){return [int]$Matches[1]}
  if("$v" -match '^\d+(\.\d+)?$'){return [int]([double]$v*1000)}
  return 0
}
function Set-Tuning { param([string]$App,$Knob)
  $hpa=if($Knob.hpa_name){[string]$Knob.hpa_name}else{$App}
  $deployment=if($Knob.deployment_name){[string]$Knob.deployment_name}else{$App}
  $body=@{spec=@{minReplicas=[int]$Knob.min;maxReplicas=[int]$Knob.max;metrics=@(@{type='Resource';resource=@{name='cpu';target=@{type='Utilization';averageUtilization=[int]$Knob.target}}})}}
  $f=Join-Path $env:TEMP "hpa-$App.json"; ($body|ConvertTo-Json -Depth 10 -Compress)|Set-Content $f -Encoding ascii
  & kubectl -n $NS patch hpa $hpa --type=merge --patch-file $f | Out-Null
  $wanted=[int]$Knob.request; $live=Get-LiveRequest $deployment
  if($wanted -gt 0 -and $wanted -ne $live){
    & kubectl -n $NS set resources "deploy/$deployment" "--requests=cpu=$($wanted)m" | Out-Null
    & kubectl -n $NS rollout status "deploy/$deployment" --timeout=120s | Out-Null
  }
}
function Set-TuningSet { param($Knobs)
  # 후보 하나가 여러 앱을 담을 수 있다(회차 절약). 담긴 앱을 모두 적용한다.
  foreach($name in $Knobs.PSObject.Properties.Name){ Set-Tuning $name $Knobs.$name }
}
function Write-Rejected { param($Rows,[string]$Path)
  $items=@($Rows|ForEach-Object{$_|ConvertTo-Json -Compress}); ('['+($items -join ',')+']')|Set-Content $Path -Encoding ascii
}
function Save-Snapshot { param([string]$From,[string]$To)
  # 거절된 회차의 측정으로 다음 후보를 계획하면 엉뚱한 값이 나온다(실측 사고).
  # 채택된 상태의 결과만 따로 보관해 계획 입력으로 쓴다.
  if(Test-Path $To){ Remove-Item -Recurse -Force $To }
  Copy-Item -Recurse -Force $From $To
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
$candidateLimit=[Math]::Min([Math]::Max($Iterations,0),3)
$rejFile=Join-Path $env:TEMP 'optimize-rejected.json';'[]'|Set-Content $rejFile -Encoding ascii
$rejected=@();$pending=$null;$bestKnobs=$null
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
  $bestOut=Join-Path $env:TEMP 'tune-opt-best'; Save-Snapshot $out $bestOut
  $bestKnobs=$first.knobs
  Write-Host ("[baseline] {0:N1}/36 ratio={1:N2} elapsed={2:N1}m" -f $bestScore.total,$bestScore.cost_ratio,$sw.Elapsed.TotalMinutes)
  if(-not $Apply){
    if($first.done){Write-Host "수렴: $($first.reason)" -ForegroundColor Green}
    else{Write-Host ("후보 [{0}] {1}: request={2}m target={3}% min={4} max={5}" -f $first.kind,$first.app,$first.knob.request,$first.knob.target,$first.knob.min,$first.knob.max) -ForegroundColor Green;Write-Host $first.reason}
    return
  }
  for($i=1;$i -le $candidateLimit;$i++){
    $step=Get-NextStep $bestOut $rejFile
    if($step.done){Write-Host "수렴: $($step.reason)" -ForegroundColor Green;break}
    $candidate=$step.candidate;$settle=[int]$candidate.settle_seconds
    if($step.kind -eq 'cost-reclaim'){$settle=[Math]::Max($settle,$CostSettleSeconds)}elseif(-not $candidate.disruptive){$settle=[Math]::Max($settle,$SettleSeconds)}
    $durationSec=ConvertTo-DurationSeconds $Duration
    # request rollback은 rollout + 재settle 까지 필요하므로 넉넉히 예약한다.
    $required=[TimeSpan]::FromSeconds($settle*2+$durationSec+150)
    if($sw.Elapsed+$required -ge $deadline){Write-Host '남은 예산이 측정+롤백 시간보다 짧아 종료' -ForegroundColor Yellow;break}
    $app=$step.app;$pending=$app
    $knobSet=if($step.knob_set){$step.knob_set}else{$null}
    $touched=if($knobSet){@($knobSet.PSObject.Properties.Name)}else{@($app)}
    Write-Host ("--- {0}/{1} [{2}] {3}: request {4}->{5}m target {6}->{7}% 예약노드 {8}대 CPU공급부족 {9}배" -f $i,$candidateLimit,$step.kind,($touched -join '+'),$candidate.current.request,$candidate.proposed.request,$candidate.current.target,$candidate.proposed.target,$candidate.predicted_nodes,$candidate.cpu_supply_ratio)
    if($knobSet){Set-TuningSet $knobSet}else{Set-Tuning $app $step.knob}
    Start-Sleep -Seconds $settle
    & $loadtest @ltArgs | Out-Null
    $score=Get-Score $out
    # 공식 채점 기준선: 가용성 90%+면 앱당 만점, 성능 30% 미만이면 비용 12점 전부 0.
    # 비용 우선 모드는 그 실제 선(기본 92% / 35%)만 지키고 비용을 챙긴다.
    $availFloor=if($step.avail_floor){[double]$step.avail_floor}else{$AvailFloor}
    $perfFloor=if($step.perf_floor){[double]$step.perf_floor}else{$PerfFloor}
    $gate=($score.min_avail -ge $availFloor) -and ($score.min_perf -ge $perfFloor) -and ($score.cost_points -gt 0)
    # 99% availability/30% performance는 점수보다 우선하는 hard gate다.
    # 공식 band 점수가 동률이어도 gate 방향으로 개선되면 채택해 다음 복구 수를 허용한다.
    $availImproved=(-not $bestScore.avail_gate_pass) -and ($score.min_avail -gt $bestScore.min_avail) -and ($score.min_perf -ge $bestScore.min_perf)
    $perfImproved=(-not $bestScore.perf_gate_pass) -and ($score.min_perf -gt $bestScore.min_perf) -and ($score.min_avail -ge $bestScore.min_avail)
    $safetyImproved=$availImproved -or $perfImproved
    if($safetyImproved -or ($gate -and $score.total -gt $bestScore.total)){
      Write-Host ("채택 {0:N1}->{1:N1}, ratio={2:N2}, safetyImproved={3}" -f $bestScore.total,$score.total,$score.cost_ratio,$safetyImproved) -ForegroundColor Green
      $bestScore=$score
      foreach($name in $touched){ if($knobSet){$bestKnobs.$name=$knobSet.$name}else{$bestKnobs.$name=$step.knob} }
      $pending=$null
      Save-Snapshot $out $bestOut
    }else{
      Write-Host ("거절 score={0:N1} gate={1}; snapshot 롤백 후 {2}초 안정화" -f $score.total,$gate,$settle) -ForegroundColor Yellow
      foreach($name in $touched){ if($bestKnobs.$name){ Set-Tuning $name $bestKnobs.$name } }
      $pending=$null
      # 롤백 직후 바로 재측정하면 Karpenter/HPA가 정리되기 전 값이 잡혀 다음 회차가 오염된다.
      Start-Sleep -Seconds $settle
      $rejected+=@{key=$candidate.key;app=$app;kind=$step.kind;nodes=[int]$candidate.predicted_nodes}
      Write-Rejected $rejected $rejFile
    }
  }
  Write-Host ("`n=== 종료 {0:N1}분 / best {1:N1}/36 ratio={2:N2} ===" -f $sw.Elapsed.TotalMinutes,$bestScore.total,$bestScore.cost_ratio) -ForegroundColor Green
  if(($bestScore.min_avail -lt $AvailFloor) -or ($bestScore.min_perf -lt $PerfFloor)){
    Write-Warning ("안전선 미달: min availability={0:N1}% (>={1}%) / min performance={2:N1}% (>={3}%)" -f $bestScore.min_avail,$AvailFloor,$bestScore.min_perf,$PerfFloor)
  }
  foreach($name in $bestKnobs.PSObject.Properties.Name|Sort-Object){$k=$bestKnobs.$name;Write-Host ('{0}: requests.cpu="{1}m", min_replicas={2}, max_replicas={3}, average_utilization={4}' -f $name,$k.request,$k.min,$k.max,$k.target)}
  Write-Host '현재 값은 라이브 적용 상태입니다. Terraform apply는 튜닝 흐름에 필요하지 않습니다.'
}
finally {
  if($pending -and $bestKnobs -and $bestKnobs.$pending){
    Write-Warning "중단 감지: $pending 을 마지막 채택 snapshot으로 롤백"
    try{Set-Tuning $pending $bestKnobs.$pending}catch{Write-Warning "자동 롤백 실패: $_"}
  }
}
